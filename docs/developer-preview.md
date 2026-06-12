# Developer Preview

Fieldwork developer preview is for developers who want inspectable, self-hosted
coding-agent infrastructure with broker-owned repository writes.

Supported now:

- Ubuntu 24.04 VPS
- GitHub repositories
- Claude Code remote-control adapter
- Codex Desktop + SSH preview path
- broker-owned GitHub PR creation
- optional Telegram approval transport
- optional ntfy notifications

Evaluation only:

- Docker Compose localhost harness via `fieldwork eval`

Planned:

- local shell evaluation mode
- other forge brokers
- additional approval transports
- Codex journaling, resume-context, lifecycle notifications, and stronger
  Fieldwork-managed sandbox parity
- additional Fieldwork-launched coding-agent adapters
- packages such as Homebrew and Debian

Costs and accounts:

- a small Ubuntu VPS
- Claude or OpenAI/Codex account usage, depending on agent choice
- a GitHub fine-grained PAT for the broker
- optional notification or approval transport accounts

Fieldwork has no Fieldwork-operated telemetry. Outbound calls are limited to
GitHub, configured agent services, configured notification/approval transports,
OS/package registries during install, and user-configured network endpoints.

Developer-preview releases use signed Git tags and published SHA256 checksums.
See [supply-chain.md](supply-chain.md) and [versioning.md](versioning.md).
