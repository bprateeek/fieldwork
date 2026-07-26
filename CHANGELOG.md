# Changelog

## Unreleased

- **Breaking:** replace checkout-reading broker protocol v1 with checkout-blind
  protocol v2. Agents build a clean SHA-1, non-thin Git pack and upload it with
  slug-based metadata in two top-level calls. Remove `repo_path`, broker
  `--projects-root`, and the one-call `fieldwork-pr-submit` client.
- Add broker-owned per-slug policy, strict quarantine/object caps, title/body
  and object secret scans, SSRF address classification with DNS/port pinning,
  host-restricted askpass, and GitHub/GitLab REST PR creation without `gh`.
- Make approval and auto modes durable before forge writes. Add HMAC-protected
  split pending stores, permanent replay IDs, terminal tombstones, authenticated
  status, idempotent reconciliation, and `needs_operator` on policy drift.
- Add Claude-only local hard-boundary mode with a root-owned control plane,
  hardened broker/bot containers, dedicated OS user, policy helper, pinned
  Claude digest, private per-UID spool, TTY token rotation, and local approval.
- Scope the initial local hard-boundary release claim to Ubuntu 24.04 Linux;
  keep macOS unreleased pending a disposable real-hardware gate. Add a
  root-only, non-persistent CI OAuth-token path whose hostile probe verifies
  credential scrubbing from Bash and the Linux process view.
- Move VPS Fieldwork boundary runners, poller, dispatcher, sessions, clients,
  and adapters to root-owned system units/assets. Disable the dashboard in
  hard-boundary mode; rootless Docker remains a user service.
- Replace free-text notifications with a typed enum rendered by fixed bot
  templates, and remove agent write access to the queue.
- Add a discrete maintenance/migration transaction and exact-byte structural
  instruction migrator. Existing repositories must be re-wired; approval
  defaults to `require`.
- Replace self-authorized release construction with a request to a separately
  protected, commit-pinned trusted builder. Installation now requires both an
  operator-pinned signed tag and trusted-builder artifact provenance.
- Git is SHA-1-only for this protocol. GHES and local Codex hard-boundary mode
  remain deferred; self-managed GitLab local mode is experimental.

## v0.2.0 - 2026-06-30

- Add core GitLab forge support: set `forge = "gitlab"` (or
  `FIELDWORK_FORGE=gitlab`) to open merge requests through the GitLab REST API.
  New config keys: `gitlab_api` (the operator-pinned API host, the broker's
  security pin), `gitlab_ca_bundle` (private CA for self-managed instances), and
  required `commit_name`/`commit_email` identity (the agent has no GitLab token).
  Supports nested `group/subgroup/project` paths; `rotate-pat` validates a GitLab
  token via `GET /user`. GitLab branch protection, secret scanning, CodeQL,
  `.github/` templates, and event-poller MR merge detection are deferred.
- Add Aider as a Fieldwork-launched agent through a one-shot task pipeline:
  `fieldwork task add|list|discard`, the Telegram `/task` command, a VPS task
  dispatcher, and bring-your-own model via `~/.fieldwork/aider.conf`.
- Carry `profile` and `actor` attribution through task and agent-lifecycle
  notification envelopes (advisory only; the broker request schema is unchanged).

## v0.1.0 - 2026-06-03

- Reposition Fieldwork for developer preview.
- Add Docker Compose evaluation harness.
- Add broker audit events and `fieldwork log`.
- Add adapter diagnostics.
- Document release integrity, versioning, backup/restore, cost, telemetry, and
  supported developer preview boundaries.
- Add Codex agent support via the official Codex App + SSH model, including
  `fieldwork setup --agent claude|codex|both` and a Codex sandbox socket
  allowlist for the broker and runner sockets.
- Make Codex sandbox probes version-tolerant across `codex sandbox` invocation
  forms used by different Codex CLI releases.
- **Breaking:** scope Fieldwork-owned state out of `.claude/` into `.fieldwork/`.
  Affected repo files: `expected-origin`, `default-branch`, `approval-gate`, and
  `local/`; VPS home assets move under `~/.fieldwork/`. Claude discovery paths
  (`.claude/{settings.json,hooks,skills,agents,rules}`) are unchanged. Migration:
  re-onboard the repo, or move the committed
  `.claude/{expected-origin,default-branch,approval-gate}` files to `.fieldwork/`
  and update `.gitignore` (`.claude/local/` -> `.fieldwork/local/`).
- Rotate the broker audit log by size (`FIELDWORK_BROKER_AUDIT_LOG_MAX_BYTES`,
  `FIELDWORK_BROKER_AUDIT_LOG_BACKUPS`).

## Versioning Policy

Fieldwork uses semver during developer preview.

- Patch releases preserve developer preview config compatibility.
- Minor releases may add config keys, commands, adapters, or transports.
- Breaking config or install changes require migration notes in this changelog.
- `0.x` releases may still change operational shape, but changes must be called
  out clearly before users upgrade.
