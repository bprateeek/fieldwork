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

- Local shell evaluation mode.
- Gitea broker implementation and deeper GitLab parity (branch protection,
  secret scanning, CodeQL/status surfaces, and event-poller MR merge detection).
- Additional approval transports such as Slack or a small web UI.
- Codex journaling, resume-context, lifecycle notifications, and stronger Fieldwork-managed sandbox parity.
- Additional Fieldwork-launched agent adapters.
- Homebrew and Debian packaging.
- Richer session history beyond broker events.
