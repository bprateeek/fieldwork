# Roadmap

## Delivered For v0.1.0

- No-VPS Docker evaluation path.
- Broker audit log and `fieldwork log`.
- Default-branch generalization.
- Public release integrity docs: signed tags and checksums.
- Backup, restore, and upgrade guidance.
- Adapter diagnostics for the Claude reference adapter.
- Codex App + SSH developer-preview support.

## Delivered For v0.2.0

- Core GitLab forge support: broker preflight, host-pinned push/MR creation,
  nested project paths, onboarding, token rotation, and setup wiring.
- Aider agent via a one-shot `fieldwork task` pipeline (dispatcher, Telegram
  `/task`, bring-your-own model).
- Advisory teams/managed attribution seams: `profile`/`actor` carried through
  task and agent-lifecycle notification envelopes.

## Next

- Homebrew and Debian packages that absorb the signing-key/provenance bootstrap.
- Local Codex mode when equivalent managed tool, network, and per-command
  exclusion controls exist.
- SHA-256 Git object format and binary pack framing.
- GHES support; faithful fake self-managed GitLab HTTPS API and promotion of
  GitLab local mode from experimental.
- Gitea broker implementation and deeper GitLab parity (branch protection,
  CodeQL/status surfaces, and event-poller MR merge detection).
- Additional approval transports such as Slack or a small web UI.
- Desktop-notification approvals and local verify-runner parity.
- Codex journaling, resume-context, and lifecycle notifications.
- Additional Fieldwork-launched agent adapters.
- Richer session history beyond broker events.
- Wider slug character support after policy/storage ambiguity review.
