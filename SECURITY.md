# Security Policy

Fieldwork is developer preview security infrastructure. Treat it as inspectable
self-hosted infrastructure, not a turnkey security product.

## Supported Versions

Developer preview releases are supported according to [CHANGELOG.md](CHANGELOG.md).
Patch releases preserve developer preview config compatibility; breaking install or
config changes require migration notes.

## Reporting

Report security issues privately. The preferred channel is GitHub private
vulnerability reporting ("Report a vulnerability" under the repository Security
tab); otherwise contact the repository owner or maintainers directly. Do not
open a public issue with exploit details, token material, private keys, or full
environment dumps.

Response targets (best effort during developer preview):

- acknowledge a report within 3 business days
- triage and assess severity within 7 business days
- coordinated disclosure once a fix or mitigation is available, by default
  within 90 days of triage; the exact timeline is agreed with the reporter

Release integrity:

- verify signed release tags with `git tag -v <tag>`
- verify release archives with the published `SHA256SUMS`
- do not use blind `curl | bash` installation for Fieldwork

Fieldwork has no Fieldwork-operated telemetry. Outbound calls are limited to
GitHub, configured agent services, configured notification/approval transports,
OS/package registries during install, and user-configured network endpoints.

## Security Boundaries

Fieldwork tries to protect:

- the broker GitHub PAT from Claude's filesystem and environment
- direct pushes to the configured default branch
- accidental production deploys through PR-only writes
- notification tokens from Claude's inherited environment

Fieldwork treats the coding agent as adversarial. That is the reason the
broker owns GitHub writes, validates structured requests, and keeps the PAT out
of the agent session.

Fieldwork does not protect against:

- a compromised VPS root account
- a malicious systemd/root administrator
- a malicious GitHub administrator
- bugs in Claude Code, GitHub CLI, git, systemd, or the host kernel
- secrets manually pasted into chat, PR bodies, logs, or config

See [docs/threat-model.md](docs/threat-model.md) for the full model.
