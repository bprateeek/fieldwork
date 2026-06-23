# Broker Contract

The PR broker is Fieldwork's write boundary.

Claude can edit and commit in the repo workspace, but it does not receive the GitHub write token. To open a pull request, Claude writes a structured request under the repo and sends it through a tokenless Unix-socket client. The broker validates the request, pushes a branch with its own GitHub credential, and opens the PR.

## Request Location

The thin client accepts a request file under:

```text
<repo>/.fieldwork/local/*.json
```

The default path is:

```text
<repo>/.fieldwork/local/pr-request.json
```

`fieldwork-pr-submit` rejects request files that are missing, symlinks, outside `.fieldwork/local/`, larger than 128 KiB, or missing the required top-level fields.

## JSON Shape

The documented schema lives at [../schema/pr-request.schema.json](../schema/pr-request.schema.json).

Current required fields:

```json
{
  "request_id": "2d7b8cf0-6c9d-42e2-a0e1-f8d3c4d5f678",
  "created_at": "2026-05-11T10:30:00Z",
  "repo_path": "/home/fieldwork/projects/example",
  "branch": "fieldwork/fix-login-redirect",
  "title": "Fix login redirect after auth",
  "body": "Summary...\n\nTests..."
}
```

The broker reads the PR base from `<repo>/.fieldwork/default-branch`, falling back
to the configured broker default when the file is absent.

## Socket Boundary

The client sends the request to:

```text
/run/fieldwork-pr-broker/fieldwork-pr.sock
```

The checked-in systemd template uses `SocketGroup=fieldwork-pr`, but the installer rewrites the installed socket group. By default the installed socket is owned by `fieldwork-pr-broker:<agent-primary-group>` with mode `0660` (for the standard install, usually `fieldwork-pr-broker:fieldwork`).

The agent's primary group is preserved by the user namespace that `claude remote-control --sandbox` puts the agent into. A dedicated supplementary group would be stripped from the agent's effective group set inside the sandbox and the kernel would deny `connect()` against the 0660 group-gated socket. The broker user owns the socket and the GitHub credential, but the agent user cannot read the PAT or GitHub App private key (`/etc/fieldwork-pr-broker/gh-token` and `/etc/fieldwork-pr-broker/github-app-private-key.pem` are mode `0600`, owned by the broker user when present).

An operator who wants to gate the socket with a dedicated group can override the default via `FIELDWORK_BROKER_SOCKET_GROUP=<group>` in `lib/broker/install.sh`, but must then arrange for the agent's userns mapping to preserve that group. Otherwise this kind of regression resurfaces.

## Preflight Endpoint

Onboarding can ask the broker to prove credential reachability before it creates a checkout:

```text
POST /preflight
```

Request:

```json
{
  "repo": "owner/repo"
}
```

The broker validates the owner/repo shape, obtains its own PAT or GitHub App installation token, and runs `gh repo view` in the broker environment. Success means the token can resolve the repo. A `404` response means the fine-grained PAT probably does not include that selected repository, or the GitHub App is not installed on it. This endpoint does not push, open a PR, or expose the token to the caller.

## Broker Validations

The broker rejects requests when:

- the JSON is invalid
- the request fails the runtime-enforced JSON Schema contract
- required fields are missing or not strings
- `request_id` is not a UUID
- `request_id` was already accepted by this broker
- `created_at` is not a valid UTC timestamp like `2026-05-11T10:30:00Z`
- `repo_path` is outside the configured projects root
- `repo_path` is not a Git repository
- `branch` does not match `^fieldwork/[a-z0-9][a-z0-9/_-]{1,80}$`
- `title` is over 200 characters or contains a newline
- `body` is over 64 KiB as UTF-8
- `.fieldwork/expected-origin` is missing or not an HTTPS GitHub URL
- the repo's current `origin` remote does not match `.fieldwork/expected-origin`
- the worktree has unstaged or staged changes
- `gitleaks` detects secret-shaped content in the PR body
- the in-memory per-repo rate limit is exceeded
- `git push` or `gh pr create` fails

The broker derives the push URL from `.fieldwork/expected-origin`; it does not trust the repo's current `origin` remote for push auth. It still checks that the current `origin` points at the same owner/repo so an attacker cannot silently swap the local checkout's origin while asking the broker to push elsewhere.

Broker git subprocesses set `safe.directory` for the validated repo path in the broker-owned process environment. Onboarding therefore does not need to run `sudo git config --system --add safe.directory ...` for each repo after setup has removed temporary passwordless sudo.

## Replay Protection

Clients generate a fresh UUID `request_id` for every PR request. After validation and rate-limit checks, the broker stores accepted request IDs under:

```text
/var/lib/fieldwork-pr-broker/requests/
```

Each ledger file is mode `0600` and owned by `fieldwork-pr-broker`. Duplicate `request_id` values are rejected with HTTP `409`.

## Responses

Success:

```json
{
  "ok": true,
  "request_id": "2d7b8cf0-6c9d-42e2-a0e1-f8d3c4d5f678",
  "url": "https://github.com/owner/repo/pull/123"
}
```

Validation failure:

```json
{
  "ok": false,
  "request_id": "2d7b8cf0-6c9d-42e2-a0e1-f8d3c4d5f678",
  "error": "worktree not clean, commit before submitting"
}
```

After schema validation, `request_id` is the client-provided UUID. For invalid JSON and other pre-schema failures, the broker may return a short generated fallback request ID for log correlation.

## Audit Log

The broker logs to:

```text
/var/log/fieldwork-pr-broker.log
```

Logs include request IDs, validation results, push attempts, PR creation attempts, and rejection reasons. They do not include the GitHub token.

The structured audit log lives at:

```text
/var/lib/fieldwork-pr-broker/audit.jsonl
```

`audit.jsonl` and rotated `audit.jsonl.N` files are owned by the broker user and group, mode `0640`. On ACL-capable systems the installer grants the agent user a direct read ACL on those files plus traverse-only access to `/var/lib/fieldwork-pr-broker`. That lets the future event poller and local dashboard open the known audit path without joining `fieldwork-bot` or reading `pending/` and `requests/`. The broker re-applies mode and the direct read ACL after audit writes and rotation.

Accepted request IDs are also recorded in the replay ledger:

```text
/var/lib/fieldwork-pr-broker/requests/<request_id>.json
```

Ledger entries include request ID, created timestamp, repo, repo path, branch, and accepted timestamp.

## Accepted And Rejected Examples

Accepted shape:

```json
{
  "request_id": "2d7b8cf0-6c9d-42e2-a0e1-f8d3c4d5f678",
  "created_at": "2026-05-11T10:30:00Z",
  "repo_path": "/home/fieldwork/projects/my-app",
  "branch": "fieldwork/fix-auth-redirect",
  "title": "Fix auth redirect",
  "body": "Summary:\n- Preserve next URL during login.\n\nTests:\n- npm test"
}
```

Rejected branch:

```json
{
  "request_id": "2d7b8cf0-6c9d-42e2-a0e1-f8d3c4d5f679",
  "created_at": "2026-05-11T10:30:00Z",
  "repo_path": "/home/fieldwork/projects/my-app",
  "branch": "main",
  "title": "Push directly",
  "body": "This is rejected because the branch is not under fieldwork/."
}
```

Rejected repo path:

```json
{
  "request_id": "2d7b8cf0-6c9d-42e2-a0e1-f8d3c4d5f680",
  "created_at": "2026-05-11T10:30:00Z",
  "repo_path": "/tmp/my-app",
  "branch": "fieldwork/fix-auth-redirect",
  "title": "Fix auth redirect",
  "body": "This is rejected because the repo path is outside the projects root."
}
```

## Future Contract Work

These behaviors are still future work, not current runtime behavior:

- signed requests
- timestamp freshness windows
- JSON Schema enforcement through a full draft 2020-12 library instead of Fieldwork's small stdlib validator
