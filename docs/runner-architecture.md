# Runner Architecture

Fieldwork uses two socket-activated runners between the agent and the broker:

- `fieldwork-verify`: runs deterministic checks.
- `fieldwork-pr-prepare`: creates the delivery branch and commit.

They exist because Claude runs inside `claude remote-control --sandbox`, where child processes inherit `PR_SET_NO_NEW_PRIVS` and a user namespace. That is good for host-secret protection, but it makes `bwrap` and some git subprocess behavior unsuitable for Fieldwork's delivery path. Codex uses its own task sandbox and needs explicit Unix-socket allowlisting to reach these same runner sockets. The runners are started by `systemd --user`, outside the agent sandbox, and stream results back over Unix sockets.

The runners do not hold forge credentials. The broker remains the only forge write boundary.

## Position In The Flow

```text
agent process
  Claude: NNP=1, userns sandbox
  Codex: Codex task sandbox with Fieldwork socket allowlist
  |
  | exec fieldwork-verify or fieldwork-pr-prepare
  v
thin client
  still inside agent execution context
  |
  | connect to $XDG_RUNTIME_DIR/fieldwork-*.sock
  v
systemd --user socket activation
  spawns one runner service per connection
  |
  v
runner
  validates request
  runs verify pipeline or prepare impl
  streams tagged stdout/stderr/exit code
  |
  v
agent receives result
  |
  v
fieldwork-pr-submit -> broker -> optional approval -> GitHub PR or GitLab MR
```

## Wire Protocol

Both runners use the same line protocol:

```text
client -> server: one JSON object plus "\n"
server -> client: O\t<line>\n   stdout
server -> client: E\t<line>\n   stderr
server -> client: X\t<exit>\n   final exit code
```

The client calls `shutdown(SHUT_WR)` after sending the request. The socket units use `Accept=yes`, so one connection maps to one service instance.

## Verify Runner

Files:

- [../lib/scripts/fieldwork-verify](../lib/scripts/fieldwork-verify): Python socket client.
- [../lib/scripts/fieldwork-verify-runner](../lib/scripts/fieldwork-verify-runner): bash runner.
- [../lib/scripts/fieldwork-verify-pipeline](../lib/scripts/fieldwork-verify-pipeline): verify implementation.
- [../lib/systemd/fieldwork-verify-runner.socket](../lib/systemd/fieldwork-verify-runner.socket): user socket.
- [../lib/systemd/fieldwork-verify-runner@.service](../lib/systemd/fieldwork-verify-runner@.service): per-connection service.

Socket:

```text
$XDG_RUNTIME_DIR/fieldwork-verify.sock
mode 0600
```

Request:

```json
{"repo_path": "/home/fieldwork/projects/<slug>"}
```

Validation and execution:

- Resolves the repo path and refuses paths outside `/home/fieldwork/projects/*` and `/home/fieldwork/worktrees/*`.
- Walks path segments and refuses symlinked components.
- Requires a git checkout.
- Probes `bwrap` by actually creating namespaces.
- Fails closed with exit `20` if the bwrap inner sandbox is not usable.
- Detects stack from repo files.
- Refuses dependency installation inside the agent flow; missing deps exit `30`.
- Runs lint, typecheck, tests, gitleaks, and semgrep where applicable.
- Runs each inner step inside bwrap with network off.
- Masks `.claude/` inside bwrap so tools do not scan Fieldwork worktree copies or local state.

Exit codes:

| Code | Meaning |
|---:|---|
| 0 | ok |
| 10 | lint failed |
| 11 | typecheck failed |
| 12 | tests failed |
| 13 | gitleaks failed |
| 14 | semgrep failed |
| 20 | abuse, sandbox unavailable, or path escape |
| 30 | dependencies missing |

## PR-Prepare Runner

Files:

- [../lib/scripts/fieldwork-pr-prepare](../lib/scripts/fieldwork-pr-prepare): Python socket client.
- [../lib/scripts/fieldwork-pr-prepare-runner](../lib/scripts/fieldwork-pr-prepare-runner): bash runner.
- [../lib/scripts/fieldwork-pr-prepare-impl](../lib/scripts/fieldwork-pr-prepare-impl): git implementation.
- [../lib/systemd/fieldwork-pr-prepare-runner.socket](../lib/systemd/fieldwork-pr-prepare-runner.socket): user socket.
- [../lib/systemd/fieldwork-pr-prepare-runner@.service](../lib/systemd/fieldwork-pr-prepare-runner@.service): per-connection service.
- [../schema/pr-prepare-request.schema.json](../schema/pr-prepare-request.schema.json): request schema.

Socket:

```text
$XDG_RUNTIME_DIR/fieldwork-pr-prepare.sock
mode 0600
```

Request file location:

```text
<repo>/.fieldwork/local/pr-prepare-request.json
```

Request shape:

```json
{
  "request_id": "2d7b8cf0-6c9d-42e2-a0e1-f8d3c4d5f678",
  "created_at": "2026-05-17T10:34:00Z",
  "repo_path": "/home/fieldwork/projects/example",
  "branch": "fieldwork/fix-login-redirect",
  "paths": ["src/foo.ts", "tests/foo.test.ts"],
  "message": "fix: preserve login redirect\n\nWhy: ...\nChanges: ..."
}
```

Client validation:

- request file must be a regular file, not a symlink
- request must live under `<repo>/.fieldwork/local/`
- request must be no larger than 32 KiB
- request must be valid UTF-8 JSON
- request must contain no NUL bytes
- required fields must be present

Runner and implementation validation:

- `request_id` is UUID-shaped.
- `repo_path` must be under `/home/fieldwork/projects/<slug>`.
- repo path must be real, not a symlink alias.
- `branch` must match `^fieldwork/[a-z0-9][a-z0-9/_-]{1,80}$`.
- `paths` must be non-empty, at most 100 entries, and contain no newlines.
- paths must be relative, contain no `..` segments, and resolve under the repo root.
- target branch must not already exist.
- every dirty or untracked file in the worktree must be listed in `paths`.
- every listed path must actually be dirty.

Git behavior:

- creates the requested `fieldwork/...` branch
- stages exactly `paths`
- commits with `git -c core.hooksPath=/dev/null`
- reads commit message via `git commit -F <tmpfile>`
- verifies the post-commit tree is clean and HEAD advanced
- writes an audit record to `~/.local/state/fieldwork-pr-prepare/ledger`

Exit codes:

| Code | Meaning |
|---:|---|
| 0 | ok |
| 10 | branch already exists |
| 11 | worktree state mismatch |
| 12 | git operation failed; rolled back where possible |
| 13 | path safety rejected |
| 20 | bad input, unsupported state, setup error |
| 21 | duplicate request_id |

## Replay And Rollback

The prepare runner reserves `request_id` with atomic exclusive create before git mutation. If the operation fails before success, it removes the reservation so the same request can be retried. On success, it writes the final audit record and future reuse is rejected.

Rollback is best-effort. The implementation attempts to check out the original branch or detached HEAD, delete the new branch, and hard-reset to the original commit. Filesystem or git corruption can still require manual recovery.

## Why Hooks Are Disabled

The prepare runner runs outside the agent's sandbox cage. Repo-controlled hooks must not run in that context. Every git command goes through:

```text
git -c core.hooksPath=/dev/null
```

Verification happens before prepare. Hooks are not the delivery gate.

## Security Properties

What gates runner access:

- `$XDG_RUNTIME_DIR` is owned by the agent uid.
- runner sockets are mode `0600`.
- root can still access them, which is accepted by the threat model.

What the runners do not trust:

- caller-supplied paths
- branch names
- dirty worktree state
- request IDs
- commit message transport

What the runners do not do:

- no GitHub push
- no `gh pr create`
- no broker token read
- no Telegram token read
- no approval decision
- no dependency installation

## Systemd Units

Both runners use this shape:

```text
fieldwork-<role>-runner.socket
  ListenStream=%t/fieldwork-<role>.sock
  SocketMode=0600
  Accept=yes
  MaxConnections=4

fieldwork-<role>-runner@.service
  ExecStart=%h/.local/bin/fieldwork-<role>-runner
  StandardInput=socket
  StandardOutput=socket
  StandardError=journal
```

The per-connection service files intentionally do not set `NoNewPrivileges=true`. The whole point is to run outside the agent's NNP/userns context. The boundary is socket ownership plus request validation.

`MaxConnections=4` is intentionally small: it keeps bounded agent capacity from
silently queueing at two connections while still limiting verify/prepare fan-out
on a single VPS. Heavy verify pipelines may need a VPS with at least 4 GB RAM
when capacity is raised.

## AppArmor And bwrap

On Ubuntu 24.04, `kernel.apparmor_restrict_unprivileged_userns=1` can block bwrap namespace creation. Fieldwork ships a narrow AppArmor profile:

```text
lib/apparmor/fieldwork-bwrap
```

Install when doctor or verify reports the AppArmor/userns case:

```sh
sudo install -m 644 ~/fieldwork/lib/apparmor/fieldwork-bwrap /etc/apparmor.d/fieldwork-bwrap
sudo apparmor_parser -r /etc/apparmor.d/fieldwork-bwrap
```

Do not disable `kernel.apparmor_restrict_unprivileged_userns` globally unless you accept the host-wide change.
