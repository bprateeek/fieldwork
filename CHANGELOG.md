# Changelog

## Unreleased

- No unreleased changes yet.

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
