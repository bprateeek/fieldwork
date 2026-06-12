---
name: pr-delivery
description: Open a PR via the fieldwork-pr-broker. Runs verify-before-pr, calls the prepare runner to branch + stage + commit outside the agent's sandbox cage, writes the broker request file, and invokes the broker thin client. Step order is load-bearing. Broker rejects dirty worktrees.
---

# /pr-delivery

Opens a PR through the broker path. Can be run from `main` with a dirty worktree. The prepare runner creates the new branch and the commit.

## Before step 1

Print the list of paths that will be committed and a one-paragraph rationale for the change. The user sees this BEFORE any state changes and can interrupt if the scope is wrong. Then proceed straight through steps 1–4 without asking for further confirmation. The broker submit in step 4 is already gated by the `permissions.ask` rule on `Bash(/home/fieldwork/.local/bin/fieldwork-pr-submit *)`, and a second confirmation in chat duplicates it. The prepare runner is unattended (no prompt).

## Step order (load-bearing)

The broker rejects dirty worktrees, so the prepare runner (which leaves a clean tree on a fresh branch) must precede the broker submit. The prepare runner refuses if the target branch already exists, so pick a fresh branch name per delivery.

The runner invocations in steps 3 and 5 must be typed exactly as shown: absolute path, single argument, nothing before it. The sandbox exclusion that lets them run is a literal prefix match on the command string; any prefix (`cd ... &&`, `env ...`, quoting the binary path, `;` chains) re-enables the per-call sandbox and the call fails with `bwrap: No permissions to create new namespace`. In Fieldwork remote sessions every other plain Bash command is expected to fail that way by design; if a helper command is denied or bwrap-fails, continue the flow using the Read and Write tools instead. Do not hand the PR back to the user.

### 1. Run verify-before-pr

```
/verify-before-pr
```

If it fails, **stop**. Nothing is committed or pushed.

### 2. Write the prepare request

Build `<repo>/.fieldwork/local/pr-prepare-request.json`:

```json
{
  "request_id": "<fresh uuid v4; read /proc/sys/kernel/random/uuid with the Read tool>",
  "created_at": "<UTC timestamp in YYYY-MM-DDTHH:MM:SSZ form; construct it from the session's known current date, the runner validates shape only>",
  "repo_path": "/home/fieldwork/projects/<slug>",
  "branch": "fieldwork/<short-feature-name>",
  "paths": ["<repo-relative path>", "<repo-relative path>", "..."],
  "message": "<commit message body, ≤8KiB>"
}
```

Field rules (full schema: `schema/pr-prepare-request.schema.json`):

- `branch` regex: `^fieldwork/[a-z0-9][a-z0-9/_-]{1,80}$`. Must not already exist locally; the runner refuses if it does.
- `paths` must list **every** modified or untracked file in the worktree, and only those. The runner refuses if the worktree has unexpected dirty files. No `..` segments, no absolute paths, no NUL/newline in path strings, ≤100 entries, each ≤256 bytes.
- `message` is the commit message body (title line + blank line + body, ≤8KiB). The runner spools it to a tmpfile and passes `-F` to `git commit` — no need to escape quotes or newlines.
- `request_id` must be a fresh UUID for every submit. The runner stores accepted IDs and rejects duplicates as replay attempts.

Recommended commit message format (derived from task-intake template fields):

```
<short imperative summary, ≤72 chars>

Why: <one paragraph on the motivation>
Changes: <bulleted list of what moves>

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

### 3. Invoke the prepare runner

```bash
/home/fieldwork/.local/bin/fieldwork-pr-prepare .fieldwork/local/pr-prepare-request.json
```

The runner creates the branch, stages exactly `paths`, commits with `message`, and leaves the worktree clean. On success it prints one JSON line: `{"head":"<sha>","branch":"<branch>","request_id":"<id>"}`.

The runner runs `git -c core.hooksPath=/dev/null` so repo-controlled hooks (`pre-commit`, `commit-msg`, …) do **not** execute during prepare. Verify in step 1 has already run lint/typecheck/tests/gitleaks/semgrep, so the gate is enforced earlier in the flow.

### 4. Write the broker request file

Build `<repo>/.fieldwork/local/pr-request.json`:

```json
{
  "request_id": "<fresh uuid v4, distinct from the prepare request_id>",
  "created_at": "<UTC timestamp>",
  "repo_path": "/home/fieldwork/projects/<slug>",
  "branch": "fieldwork/<same branch from step 2>",
  "title": "<≤200 chars, no newlines>",
  "body":  "<inline markdown body, ≤64KB, no secrets>"
}
```

`title` and `body` are the **PR** title and body shown on GitHub — separate from the commit message. The broker scans `body` with gitleaks and rejects on hit; use `<env-var-name>` placeholders for credentials, not the values.

### 5. Invoke the broker thin client

```bash
/home/fieldwork/.local/bin/fieldwork-pr-submit .fieldwork/local/pr-request.json
```

The user is prompted to confirm (because of the `permissions.ask` rule). On approval, the client forwards the request to the broker, which validates the request, pushes the branch, opens the PR, and applies the `ready for review` label.

## On runner rejection

`fieldwork-pr-prepare` exit codes and what to do:

| Exit | Reason | Fix |
|---|---|---|
| `10` | branch already exists | Pick a different `branch` name and re-issue with a fresh `request_id`. |
| `11` | worktree state mismatch | Either the worktree has dirty files not in `paths`, or `paths` lists files that aren't dirty. Reconcile and retry. |
| `12` | git checkout/add/commit failed | Inspect stderr; the worktree has been rolled back to the pre-call HEAD. Commit message empty, or git ident missing, are common causes. |
| `13` | path safety rejected | A `paths` entry escapes the repo (`..`), is absolute, or contains NUL/newline. |
| `20` | schema / setup error | Request shape rejected, or repo isn't onboarded. Re-validate against `schema/pr-prepare-request.schema.json`. |
| `21` | duplicate request_id (replay) | Generate a new UUID and retry. |

Rollback is automatic and uses `git reset --hard` to the pre-call HEAD. The new commit object remains in the reflog (recoverable via `git reflog`) until git GC.

## On broker rejection

Common reasons + fixes:

| Reason | Fix |
|---|---|
| `worktree not clean` | The prepare runner left dirty state somehow. Inspect with `git status` and re-stage what's missing. Usually means step 3 was skipped. |
| `expected-origin missing` | Add `.fieldwork/expected-origin` with the HTTPS URL. |
| `expected-origin not HTTPS` | Rewrite to `https://github.com/...`. |
| `body contains secret` | Replace credential-shaped strings with placeholders. |
| `branch matches main` | Branch must be `fieldwork/...`, never `main`/`master`/`develop`. |
| `rate limit (>6/hr)` | Wait, or split fewer larger PRs instead of many small. |

If the broker is down, do NOT bypass it with manual `git push` — the broker exists to keep the PAT off this user's filesystem. File an issue and use a different machine if urgent.
