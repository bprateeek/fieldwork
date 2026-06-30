# Architecture

Fieldwork turns a phone instruction into a reviewable GitHub pull request or
GitLab merge request while keeping the forge write token out of the coding
agent's environment.

## System Flow

```text
mobile agent entry, one of:
  Claude mobile
    -> fieldwork-agent@<slug>.service
       runs Claude Code remote-control
       boundary: claude remote-control --sandbox (NNP + user namespace)
  Codex Desktop
    -> SSH login as fieldwork
       runs real codex CLI/app server
       boundary: Codex task sandbox + Fieldwork Unix-socket allowlist

both have: repo checkout, read-only deploy key
both do not have: forge write token
  |
  | Claude: /verify-before-pr and /pr-delivery
  | Codex: AGENTS.md delivery instructions
  v
fieldwork-verify
  -> $XDG_RUNTIME_DIR/fieldwork-verify.sock
  -> fieldwork-verify-runner@<conn>.service
  -> fieldwork-verify-pipeline
       lint, typecheck, tests, gitleaks, semgrep
       each inner step network-off and sandboxed
  |
  | /pr-delivery
  v
fieldwork-pr-prepare
  -> $XDG_RUNTIME_DIR/fieldwork-pr-prepare.sock
  -> fieldwork-pr-prepare-runner@<conn>.service
  -> fieldwork-pr-prepare-impl
       create fieldwork/... branch
       stage exact requested paths
       commit with core.hooksPath=/dev/null
  |
  v
fieldwork-pr-submit
  tokenless client
  -> /run/fieldwork-pr-broker/fieldwork-pr.sock
  |
  v
fieldwork-pr-broker
  user: fieldwork-pr-broker
  has: forge write token
  validates request and repo state
  |
  | if .fieldwork/approval-gate exists
  v
pending approval queue
  -> fieldwork-bot sends Telegram Approve/Deny
  -> /run/fieldwork-pr-broker/fieldwork-pr-approve.sock
  -> broker revalidates
  |
  v
GitHub branch + pull request, or GitLab branch + merge request
```

## Components

| Component                     |                  Runtime identity | Job                                                                           |
| ----------------------------- | --------------------------------: | ----------------------------------------------------------------------------- |
| `bin/fieldwork`               |                        local user | Setup, doctor, sync, onboarding, status, reports, smoke tests.                |
| `fieldwork-agent@.service`    |                       `fieldwork` | One Claude Code remote session per repo.                                      |
| Codex Desktop SSH session     |                       `fieldwork` | Codex preview path; process lifecycle and remote-project list owned by Codex Desktop. |
| `fieldwork-dashboard`         |                       `fieldwork` | Read-only localhost status surface served on the VPS and reached through SSH tunnel.  |
| `fieldwork-verify`            |                       `fieldwork` | Thin client from the agent to the verify runner socket.                       |
| `fieldwork-verify-runner`     | `fieldwork`, systemd user manager | Runs the verify pipeline outside the agent's NNP/userns cage.                 |
| `fieldwork-pr-prepare`        |                       `fieldwork` | Thin client from the agent to the prepare runner socket.                      |
| `fieldwork-pr-prepare-runner` | `fieldwork`, systemd user manager | Runs branch/stage/commit outside the agent's cage.                            |
| `fieldwork-pr-submit`         |                       `fieldwork` | Tokenless broker client.                                                      |
| `fieldwork-pr-broker`         |             `fieldwork-pr-broker` | Owns forge credential, validates requests, pushes, creates PRs/MRs.          |
| `fieldwork-bot`               |                   `fieldwork-bot` | Owns Telegram token, prompts for approval, posts decisions to approve socket. |
| `lib/templates/repo`          |        committed into target repo | AGENTS.md, Claude guidance/hooks/skills, review templates, optional workflows.|

## Agent Session

The agent session is a user systemd service:

```text
fieldwork-agent@<slug>.service
WorkingDirectory=%h/projects/<slug>
ExecStart=%h/.fieldwork/scripts/fieldwork-agent-session <slug>
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
```

`fieldwork-agent-session` selects the Fieldwork-launched agent adapter. The default adapter is Claude Code remote control. The service intentionally does not inject notification tokens, forge tokens, or broker secrets into the agent environment.

Codex does not use this service in the current milestone. Codex Desktop connects over SSH as `fieldwork` and starts the real `codex` CLI/app server through the remote login shell. Fieldwork provisions PATH, linger, runner sockets, `XDG_RUNTIME_DIR`, and the Codex sandbox socket allowlist, then leaves live connection and remote-project folder state to Codex Desktop.

## Runner Layer

Claude's sandbox gives the agent useful host-secret protection, but it also means children inherit `PR_SET_NO_NEW_PRIVS` and a user namespace. Codex has its own task sandbox. Both paths need to reach Fieldwork delivery sockets, and Claude additionally blocks or complicates two things Fieldwork needs:

- `bwrap` for sandboxed verification.
- predictable `git checkout/add/commit` behavior for PR preparation.

Fieldwork solves this with two socket-activated runners under `systemd --user`. The clients are listed in Claude's `sandbox.excludedCommands`, and Codex setup writes a Codex sandbox Unix-socket allowlist for the broker, verify, and pr-prepare sockets. The clients only connect to private sockets. The runner processes are spawned by the user manager outside the agent sandbox and do the real work.

Runner sockets are `0600` under `$XDG_RUNTIME_DIR`. The runners do not hold broker, bot, deploy-key, or notification credentials. See [runner-architecture.md](runner-architecture.md).

## Dashboard Surface

`fieldwork dashboard` starts a user service on the VPS and opens an SSH tunnel to it:

```text
browser on workstation
  -> http://127.0.0.1:<local-port>
  -> ssh -L <local-port>:127.0.0.1:<remote-port>
  -> fieldwork-dashboard.service on VPS
  -> fieldwork-status-snapshot
```

The dashboard server binds only to `127.0.0.1`, accepts GET requests only, and serves a read-only JSON snapshot plus a static browser view. `fieldwork-status-snapshot` reads Fieldwork-owned event state, resume-context files, project journals, and the broker audit log when the agent user's audit-read ACL permits it. It does not call `fieldwork status`, SSH back to the workstation, invoke shell renderers, or write broker state.

## Broker Boundary

The broker is the forge write boundary.

The agent submits JSON to:

```text
/run/fieldwork-pr-broker/fieldwork-pr.sock
```

At install time, the broker installer rewrites the checked-in socket template so the submit socket group defaults to the agent user's primary group. This is intentional: Claude's sandbox user namespace strips supplementary groups, but preserves the primary group. A hard-coded supplementary group can make the socket look correct on disk and still fail from inside the sandbox.

The broker:

- validates request schema and field patterns
- checks repo path under the configured projects root
- reads `.fieldwork/expected-origin`
- checks the current `origin` matches that expected project
- refuses dirty worktrees
- refuses non-`fieldwork/...` branches
- scans PR body text with gitleaks
- enforces replay protection by `request_id`
- rate-limits by repo
- pushes with `GIT_ASKPASS`
- opens the GitHub PR with `gh pr create`, or the GitLab MR with GitLab's API

`FIELDWORK_FORGE=github` selects the GitHub backend. GitHub credential source is
a separate axis: `FIELDWORK_GITHUB_CREDENTIAL_MODE=pat` is the current default,
and `app` uses a broker-owned GitHub App private key to mint short-lived
installation tokens.

`FIELDWORK_FORGE=gitlab` selects the GitLab backend. The broker gets its API
host only from `FIELDWORK_GITLAB_API` (default `https://gitlab.com/api/v4`) and
requires `.fieldwork/expected-origin` to match that pinned host exactly.
GitLab uses a broker-owned token with `PRIVATE-TOKEN`, refuses redirects for
token-bearing API calls, and optionally trusts `FIELDWORK_GITLAB_CA_BUNDLE` for
self-managed instances. The agent never calls the GitLab API during onboarding.

The broker pushes to a URL derived from `.fieldwork/expected-origin`; it does not trust `origin` for push authentication.

The broker also appends redacted lifecycle events to its audit JSONL log:
request receipt, rejection, queue, approve/deny, expiry, push attempt, and PR
open. Query it with `fieldwork log`.

## Approval Gate

Approval is repo-scoped. A committed `.fieldwork/approval-gate` marker tells the broker to queue each validated PR request instead of pushing immediately.

```text
/pr request
  -> validate
  -> reserve request_id
  -> write /var/lib/fieldwork-pr-broker/pending/<request_id>.json
  -> bot sends Telegram prompt
  -> bot posts approve or deny to approve socket
  -> broker revalidates drift-sensitive repo state
  -> approve pushes and opens PR, deny deletes pending request
```

The bot cannot submit PR requests because it is not in the submit socket group. The agent cannot approve requests because it is not in the approve socket group. The bot and agent do not hold the forge credential.

See [approval-gate.md](approval-gate.md).

## Repo Templates And Skills

Onboarding applies `lib/templates/repo` to the target repository. Important pieces:

- `.claude/skills/verify-before-pr/SKILL.md`: tells Claude to run `fieldwork-verify`.
- `.claude/skills/pr-delivery/SKILL.md`: tells Claude to verify, prepare, write the broker request, and submit.
- `.claude/hooks/`: resume-context artifact injection, bash guard, and notification hooks.
- `AGENTS.md`: tells Codex the same verify, prepare, submit, approval-gate, no-direct-push, and `fieldwork/...` branch rules.
- `.fieldwork/expected-origin`: broker origin pin.
- `.fieldwork/default-branch`: default branch captured during onboarding.
- `.fieldwork/approval-gate`: optional marker for gated PRs.
- `.github/`: optional GitHub workflows, CODEOWNERS, PR template, dependabot.

Onboarded repos receive copies. After Fieldwork upgrades, refresh templates with:

```sh
fieldwork onboard <project> --reseed-templates
```

## Infrastructure Baseline

The developer preview is tested on:

- Ubuntu 24.04 VPS.
- Normal SSH (transport-agnostic: public, DNS, or a private-network name like Tailscale/WireGuard if you set it up yourself).
- Claude Code remote control.
- Codex Desktop + SSH preview path.
- GitHub and core GitLab.
- ntfy for basic mobile notifications.
- Telegram for approval-gate prompts.

The broker is the most reusable component. Advanced operators can install it standalone for other agents; see [broker-standalone.md](broker-standalone.md) and [agent-adapters.md](agent-adapters.md).

## Control Adapters

Claude Code remote control is the current full control adapter: it is how Claude mobile instructions reach the long-running Fieldwork-managed agent session. Codex support intentionally bypasses adapters because Codex Desktop owns the SSH-launched process lifecycle and remote-project picker.

Optional approval transports are intentionally narrow control surfaces. They may present Approve/Deny actions for approval-gated PRs/MRs, but they do not hold the forge credential and do not inject free text into the agent session. The broker remains the component that validates requests and performs forge operations.

## Current Constraints

- GitHub and core GitLab only. GitLab currently skips branch protection, secret scanning, CodeQL, `.github/` templates, and event-poller MR merge detection.
- Claude Code is the supported Fieldwork-launched agent adapter.
- Codex Desktop + SSH is supported as a developer-preview path, with no Fieldwork Codex service.
- Codex works in the canonical checkout; concurrent Codex tasks or simultaneous Claude+Codex work on that checkout are unsupported.
- ChatGPT mobile may show only the signed-in Mac/Windows Codex host; it is not guaranteed to show a separate VPS session like Claude's `vps-<slug>`.
- Default branch is detected during onboarding and stored in `.fieldwork/default-branch`.
- Repo slug must match `^[a-z0-9][a-z0-9-]{0,30}$`.
- Default project root is `/home/fieldwork/projects`.
- The approval gate is single-approver: any allowlisted Telegram chat can approve.

These are implementation constraints for the developer preview, not
architectural requirements forever.
