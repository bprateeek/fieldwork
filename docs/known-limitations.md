# Known Limitations

Fieldwork is a developer preview. This page lists what it does not do well yet,
so you can decide whether it fits before investing setup time.

## Platform

- VPS support is Ubuntu 24.04 only. Other distributions are untested; bootstrap
  assumes apt, root-owned systemd system units, and bubblewrap.
- The local hard-boundary release target is Ubuntu 24.04 Linux with Docker and
  Claude. Local Codex is unsupported until equivalent managed sandbox controls
  exist. The Linux implementation is not a supported security claim until its
  external trusted-builder and real acceptance gate passes. The macOS
  implementation remains separately unreleased until a disposable real Mac can
  exercise install, keychain login, hostile probes, reboot persistence,
  recovery, and uninstall without risking an operator workstation.

## Scope

- GitHub and core GitLab are supported. GitLab support covers broker preflight,
  broker-owned push/MR creation, nested project paths, and managed onboarding.
  GitLab branch protection, secret scanning, CodeQL, `.github/` templates, and
  event-poller MR status/merge detection are deferred.
- Self-managed GitLab is bounded to a host-root install with SSH on the API host
  at port 22. Set `gitlab_api` / `FIELDWORK_GITLAB_API` to the exact
  `https://host/api/v4` API root; path-prefixed installs such as
  `https://host/gitlab/api/v4` are rejected. A private CA can be uploaded from
  `gitlab_ca_bundle`; the VPS stores it at `/etc/fieldwork/gitlab-ca.pem`.
- `fieldwork smoke` is GitHub-only. The GitLab live gate is a throwaway-project
  E2E: deploy-key clone, `fieldwork-init`, `rotate-pat`, broker push, MR create,
  approval-gated push, no-diff path, and verify-fail path.
- GitLab tokens should be Project Access Tokens with Developer role and `api`
  plus `write_repository` scopes. The `api` scope is broad, and GitLab project
  tokens act as internal users that may see Internal-visibility projects, so
  prefer private projects for live testing. On gitlab.com, project tokens may
  require a paid or trial namespace; a personal/group token can be used for the
  live gate.
- Single operator. There is no multi-user, RBAC, or shared-team model yet.
- No managed or hosted option. You bring your own VPS, SSH config, and GitHub
  write credential. PAT mode is the default; GitHub App mode is available for
  operators who can create and install an App per repository.

## Agents

- Claude (remote_control_daemon), Codex (desktop_relay), and Aider
  (one_shot_job, queued via `fieldwork task` / Telegram `/task`) are supported;
  other agents are not yet. Aider requires an operator-installed venv at
  `/opt/fieldwork/aider-venv` and a BYO model in `~/.fieldwork/aider.conf`.
- Codex parity is partial. Claude session hooks do not run under Codex, so Codex
  sessions still have no hook-derived "needs input" or "turn done" activity
  notifications. Git-derived journaling and resume-context artifacts are
  produced by the VPS event poller. Telegram approval-gate prompts still work
  because they are broker- and bot-driven, not agent-driven.
- Codex uses the Codex Desktop + SSH remote-project path. ChatGPT mobile may
  show only the Mac/Windows Desktop host, not a separate VPS session, and
  Fieldwork cannot force the mobile app to list the VPS.
- Fieldwork diagnoses Codex Desktop SSH host/folder state and sanitized
  app-server signals, but it does not auto-kill, restart, or manage Codex
  app-server processes in this milestone.
- Codex relies on its own sandbox plus the broker boundary; Fieldwork does not
  wrap Codex in the `NoNewPrivileges` + user-namespace confinement it applies to
  Claude.
- In `both` mode, concurrent Claude and Codex activity on the same checkout is
  not supported.
- Direct VPS `codex remote-control`, a Fieldwork-owned Codex mobile controller,
  and queued mobile Codex jobs are future scope.

## Operations

- No metrics export or alerting. The broker writes an audit log and
  `fieldwork log` reads it; there is no metrics endpoint or crash alerting.
- No web UI. Control and status are CLI plus optional Telegram approval.
- No automatic updates. Upgrades require signed-tag plus trusted-builder
  provenance verification and the discrete maintenance transaction.
- Protocol v2 accepts SHA-1 Git repositories and non-thin packs only. Mature
  full-pack uploads may exceed the conservative 8 MiB input cap.

See [developer-preview.md](developer-preview.md) for the supported stack and
[threat-model.md](threat-model.md) for security boundaries and non-goals.
