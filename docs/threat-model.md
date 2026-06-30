# Threat Model

Fieldwork is designed around one rule: the coding agent should not hold the forge write token.

Fieldwork treats the coding agent as adversarial. The agent is allowed to do
useful work in the checkout, but every path that can write to GitHub or GitLab goes
through broker validation and optional human approval.

## Assets

- Forge write credential used to push branches and open PRs/MRs: a GitHub
  fine-grained PAT, a GitHub App private key that mints installation tokens, or
  a GitLab token held by the broker.
- SSH deploy keys used for read-only clones.
- Telegram bot token and approval HMAC secret.
- ntfy topic.
- Repository source code and local unpushed changes.
- GitHub branch protection and production deployment path after merge.

## Trust Boundaries

```text
fieldwork user
  owns repo checkout
  runs Claude/Codex and tokenless clients
  cannot read broker forge credential

fieldwork-pr-broker user
  owns forge write credential
  validates PR requests
  pushes and opens PRs
  does not run the coding agent

fieldwork-bot user
  owns Telegram token and HMAC secret
  watches pending approvals
  can call approve socket
  cannot submit PR requests
  cannot read broker forge credential
```

Root on the VPS can read everything. Fieldwork does not defend against compromised root.

## What The Agent Can Do

The agent can:

- read and edit the onboarded repo workspace
- run allowed development commands inside the workspace
- request verification through `fieldwork-verify`
- request commit creation through `fieldwork-pr-prepare`
- submit a structured PR request through `fieldwork-pr-submit`
- ask the human for input through the mobile agent session

The agent cannot, by Fieldwork design:

- read `/etc/fieldwork-pr-broker/gh-token`
- read `/etc/fieldwork-pr-broker/github-app-private-key.pem`
- read the Telegram bot token or HMAC secret
- push with the broker forge credential
- call the approve socket
- merge PRs
- push directly to `main` through the broker
- write to repos outside the validated project and credential scope

## GitLab Host Pin

For GitLab, `.fieldwork/expected-origin` and `remote.origin.url` are treated as
agent-writable hints, not authority for API host selection. The broker derives
the GitLab API and HTTPS push host only from `FIELDWORK_GITLAB_API` (default
`https://gitlab.com/api/v4`) and then requires the expected-origin host to
match that pin exactly. Token-bearing GitLab API calls use stdlib `urllib` with
TLS verification on, optional `FIELDWORK_GITLAB_CA_BUNDLE`, no ambient proxy,
explicit timeouts, and redirects refused so a token is not replayed to another
host. The deploy-key SSH remote is parsed only for the opaque project path.

The GitLab token is broker/root-only. Agent-side onboarding does not call the
GitLab API; token-requiring metadata routes through broker `/preflight`, while
clone/default-branch checks use tokenless git over the read-only deploy key.

## Agent Runtime Boundaries

Claude and Codex have different process lifecycles in this developer preview.

Claude is launched by Fieldwork through `fieldwork-agent@<slug>.service` and
`claude remote-control --sandbox --spawn=worktree --capacity=<N>`. Fieldwork
owns the service lifecycle, and Claude work happens in per-task worktrees. The
capacity value defaults to `2` and is bounded by non-secret
`~/.fieldwork/agent.conf` config parsed by `fieldwork-agent-session`.

Codex is launched by the official Codex Desktop app over SSH as the `fieldwork`
Linux user. Fieldwork does not wrap the `codex` binary or run a Codex systemd
service. Codex relies on Codex's own task sandbox. Fieldwork setup writes a
Codex sandbox allowlist for the Unix sockets required by delivery:

```text
/run/fieldwork-pr-broker/fieldwork-pr.sock
/run/user/<fieldwork-uid>/fieldwork-verify.sock
/run/user/<fieldwork-uid>/fieldwork-pr-prepare.sock
```

This is a real security delta from the Claude path: Codex is not inside
Fieldwork's `claude --sandbox` confinement. The forge write boundary does not
move, because the broker forge credential remains readable only by
`fieldwork-pr-broker`, PR/MR requests still go through broker validation, and
approval-gated repos still require the Telegram approval path before push.

Codex preview gaps:

- Claude hooks do not run under Codex.
- Codex journaling and resume-context are git-derived from the VPS event poller, not from in-session hooks.
- No Fieldwork "needs input" or "turn done" notifications from Codex session lifecycle.
- Broker and approval notifications still work.
- Codex works directly in the canonical checkout, so concurrent Codex tasks or
  simultaneous Claude+Codex work on that checkout are unsupported.

## Dashboard Boundary

The dashboard is a read-only operator convenience, not a delivery or approval path. `fieldwork dashboard` starts `fieldwork-dashboard.service` as the agent user and reaches it through SSH local forwarding. Both the service and the tunnel endpoints bind to `127.0.0.1`.

The server accepts GET requests only and shells only to `fieldwork-status-snapshot`, a local JSON snapshot helper. That helper reads Fieldwork-owned event state, resume-context artifacts, project journals, and broker audit JSONL entries when the agent user's audit-read ACL allows it. It does not read broker PAT files, Telegram bot secrets, approval HMAC secrets, pending approval bodies, or notification config secrets, and it does not mutate broker, repo, or approval state.

## Broker Defenses

The broker is the forge write boundary. It rejects requests unless they pass runtime validation.

Defenses:

- JSON schema subset validation with no extra fields.
- UUID-shaped `request_id`.
- persistent replay ledger under `/var/lib/fieldwork-pr-broker/requests`.
- UTC `created_at` validation.
- repo path limited to the configured projects root.
- branch limited to `fieldwork/...`.
- title and body size limits.
- `.fieldwork/expected-origin` must be an HTTPS GitHub URL.
- current `origin` must match `.fieldwork/expected-origin`.
- worktree must be clean.
- PR body is scanned by gitleaks.
- in-memory per-repo rate limit (`FIELDWORK_BROKER_RATE_LIMIT_PER_HOUR`,
  default 12/hour, clamped to `1..120`).
- Git push uses `GIT_ASKPASS`; token is not passed in git argv.
- `gh pr create` gets `GH_TOKEN` only in the broker process environment.
- The credential provider chooses the GitHub token source; the GitHub backend
  still routes that token through `GIT_ASKPASS` for `git push` and `GH_TOKEN`
  for `gh`.
- In GitHub App mode, installation tokens are minted on demand, cached until
  shortly before expiry, written only to a broker-private request file under
  `/run/fieldwork-pr-broker` for askpass, and removed after the request.

The broker derives the push URL from `.fieldwork/expected-origin`. It does not trust a repo-controlled `origin` remote as the destination.

## Socket Permission Model

There are two broker sockets:

```text
/run/fieldwork-pr-broker/fieldwork-pr.sock
/run/fieldwork-pr-broker/fieldwork-pr-approve.sock
```

The checked-in submit socket template uses `SocketGroup=fieldwork-pr`, but the installer rewrites this at install time. By default the installed submit socket group is the agent user's primary group, usually `fieldwork`.

That matters because `claude remote-control --sandbox` puts the agent in a user namespace where supplementary groups are stripped. If the submit socket were only writable by a supplementary group, `connect()` could fail from inside the sandbox even though `id` in a normal SSH shell looked correct.

The approve socket is group-writable to `fieldwork-bot`, not to the agent. The bot user must not be in the submit socket group.

## Runner Boundary

The verify and pr-prepare runners exist to bridge from the agent's NNP/userns cage to normal user-manager execution. They are not a forge credential boundary.

Runner access checks:

- sockets live under `$XDG_RUNTIME_DIR`
- sockets are mode `0600`
- only the agent uid can connect, plus root
- each request is revalidated before work runs

Verify runner:

- allowlists repo paths under `/home/fieldwork/projects` or `/home/fieldwork/worktrees`
- refuses symlinked path components
- probes bwrap sandbox support by creating namespaces
- runs each repo-controlled check with network off
- masks `.claude/` inside bwrap

PR-prepare runner:

- accepts request files only under `<repo>/.fieldwork/local/`
- rejects symlinks, NULs, oversize requests, malformed JSON
- requires exact dirty-path matching
- refuses existing branches
- validates paths do not escape the repo
- stores a prepare replay ledger
- commits with `git -c core.hooksPath=/dev/null`
- rolls back failed branch/add/commit attempts where possible

Neither runner reads the forge write credential, Telegram token, HMAC secret, deploy key, or ntfy topic.

## Approval Gate Role

The approval gate adds a human decision before broker push for opted-in repos.

It protects against an agent submitting an unwanted but syntactically valid PR request. It does not protect against a compromised VPS root or a malicious broker process.

Controls:

- repo opts in with `.fieldwork/approval-gate`
- broker queues validated requests in `/var/lib/fieldwork-pr-broker/pending`
- bot sends HMAC-signed Telegram callbacks
- callbacks from non-allowlisted chats are ignored
- pending requests expire after 24 hours by default
- broker revalidates origin and clean worktree before approved push

See [approval-gate.md](approval-gate.md).

## Notification Secrets

The agent service does not load notification secrets into its environment. Hooks call wrapper scripts that load notification config at execution time. The Telegram bot token is owned by `fieldwork-bot`; the broker forge credential is owned by `fieldwork-pr-broker`.

The agent/dashboard user gets direct read ACL access to the broker audit log only. It does not join `fieldwork-bot`, cannot enter `pending/` or `requests/`, and cannot call the approve socket. The notifications directory is a deliberate drop path: the agent may write outbound notification files, the bot may read/delete them, and the broker may write lifecycle drops via a direct ACL.

## Telemetry And Outbound Calls

Fieldwork has no Fieldwork-operated telemetry. Outbound calls are limited to
GitHub, configured agent services, configured notification/approval transports,
OS/package registries during install, and user-configured network endpoints.

## Security Verification

Run:

```sh
fieldwork verify-security [repo-slug]
```

It checks:

- temporary passwordless sudo cleanup
- broker token or GitHub App private key owner and mode
- agent user cannot read broker forge credentials
- Codex SSH identity is `fieldwork` when Codex is configured
- Codex SSH identity can reach the submit socket but cannot read the broker forge credential
- broker socket owner and mode
- broker ledger owner and mode
- broker systemd hardening directives
- bot user is not in the submit socket group
- approve socket owner, group, mode, and live connectivity
- bot cannot read broker forge credentials
- bot HMAC secret owner and mode
- notification secrets are not injected into the agent service
- optional repo origin checks

## Non-Goals

Fieldwork does not defend against:

- compromised root on the VPS
- malicious kernel, systemd, git, GitHub CLI, Claude Code binary, or Codex binary
- malicious GitHub or GitLab account, project, or organization administrator
- a user pasting secrets into chat, code, or PR text
- all same-host side channels
- production deployment triggered after a human merges a PR
- GitHub/GitLab branch protection being disabled outside Fieldwork

Remote coding work is the point. The defense is credential separation, scoped request validation, brokered forge writes, approval gating where enabled, and human review.

## High-Risk Changes

Review these carefully in forks:

- giving deploy keys write access
- putting a forge token in the agent environment
- widening broker repo path validation
- letting the broker push directly to `main`
- letting the agent call the approve socket
- removing `core.hooksPath=/dev/null` from pr-prepare
- disabling review on repos that auto-deploy from `main`
