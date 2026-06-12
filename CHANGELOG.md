# Changelog

## Unreleased

- No unreleased changes yet.

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
