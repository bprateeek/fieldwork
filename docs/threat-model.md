# Threat Model

Fieldwork is designed around one rule: the coding agent should not hold the GitHub write token.

Fieldwork treats the coding agent as adversarial. The agent is allowed to do
useful work in the checkout, but every path that can write to GitHub goes
through broker validation and optional human approval.

## Assets

- GitHub fine-grained PAT used to push branches and open PRs.
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
  cannot read broker PAT

fieldwork-pr-broker user
  owns GitHub PAT
  validates PR requests
  pushes and opens PRs
  does not run the coding agent

fieldwork-bot user
  owns Telegram token and HMAC secret
  watches pending approvals
  can call approve socket
  cannot submit PR requests
  cannot read broker PAT
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
- read the Telegram bot token or HMAC secret
- push with the broker PAT
- call the approve socket
- merge PRs
- push directly to `main` through the broker
- write to GitHub repos outside the broker PAT's selected repositories

## Agent Runtime Boundaries

Claude and Codex have different process lifecycles in this developer preview.

Claude is launched by Fieldwork through `fieldwork-agent@<slug>.service` and
`claude remote-control --sandbox --spawn=worktree --capacity=1`. Fieldwork owns
the service lifecycle, and Claude work happens in per-task worktrees.

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
Fieldwork's `claude --sandbox` confinement. The GitHub write boundary does not
move, because the broker PAT remains readable only by `fieldwork-pr-broker`, PR
requests still go through broker validation, and approval-gated repos still
require the Telegram approval path before push.

Codex preview gaps:

- Claude hooks do not run under Codex.
- No Codex journaling or resume-context in this milestone.
- No Fieldwork activity notifications from Codex session lifecycle.
- Broker and approval notifications still work.
- Codex works directly in the canonical checkout, so concurrent Codex tasks or
  simultaneous Claude+Codex work on that checkout are unsupported.

## Broker Defenses

The broker is the GitHub write boundary. It rejects requests unless they pass runtime validation.

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
- in-memory per-repo rate limit.
- Git push uses `GIT_ASKPASS`; token is not passed in git argv.
- `gh pr create` gets `GH_TOKEN` only in the broker process environment.

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

The verify and pr-prepare runners exist to bridge from the agent's NNP/userns cage to normal user-manager execution. They are not a GitHub credential boundary.

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

Neither runner reads the GitHub PAT, Telegram token, HMAC secret, deploy key, or ntfy topic.

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

The agent service does not load notification secrets into its environment. Hooks call wrapper scripts that load notification config at execution time. The Telegram bot token is owned by `fieldwork-bot`; the broker PAT is owned by `fieldwork-pr-broker`.

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
- broker PAT owner and mode
- agent user cannot read broker PAT
- Codex SSH identity is `fieldwork` when Codex is configured
- Codex SSH identity can reach the submit socket but cannot read the broker PAT
- broker socket owner and mode
- broker ledger owner and mode
- broker systemd hardening directives
- bot user is not in the submit socket group
- approve socket owner, group, mode, and live connectivity
- bot cannot read broker PAT
- bot HMAC secret owner and mode
- notification secrets are not injected into the agent service
- optional repo origin checks

## Non-Goals

Fieldwork does not defend against:

- compromised root on the VPS
- malicious kernel, systemd, git, GitHub CLI, Claude Code binary, or Codex binary
- malicious GitHub account or organization administrator
- a user pasting secrets into chat, code, or PR text
- all same-host side channels
- production deployment triggered after a human merges a PR
- GitHub branch protection being disabled outside Fieldwork

Remote coding work is the point. The defense is credential separation, scoped request validation, brokered GitHub writes, approval gating where enabled, and human PR review.

## High-Risk Changes

Review these carefully in forks:

- giving deploy keys write access
- putting a GitHub token in the agent environment
- widening broker repo path validation
- letting the broker push directly to `main`
- letting the agent call the approve socket
- removing `core.hooksPath=/dev/null` from pr-prepare
- disabling PR review on repos that auto-deploy from `main`
