# Threat model

## Security objective

An agent that controls its checkout, prompts, commits, filenames, branch
content, and sandboxed commands must not obtain the forge write credential,
choose a different destination/base/approval policy, make a forge write before
required approval, or exfiltrate arbitrary text through notifications.

## Trusted components

- the operator and independently obtained release signing key;
- the separately protected trusted-builder workflow and restricted runner;
- root-owned local/VPS control assets and system units;
- Docker engine and root in local mode;
- broker identity, credential, policy, MAC key, and persistent state;
- the forge and configured CA/DNS infrastructure.

The agent checkout, per-UID spool, uploaded metadata/pack, repository hooks and
config, project/user Claude settings, task prompts, commit data, and notification
producer inputs are untrusted.

## Main defenses

### Checkout blindness

The broker has no checkout or projects-root input. Destination, project, base
branch, approval mode, endpoints, CA, and private-network opt-in come only from
the broker-owned slug policy.

### Sandbox escape control

Hard-boundary Claude sessions fail if sandboxing is unavailable and disallow
unsandboxed commands. Root-owned managed policy has an empty Bash-child network
domain set, denies outbound tools and unmanaged MCP, denies credential/Docker/
user-bus reads, and excludes only absolute root-owned clients. Clients are
invoked as separate top-level commands. A root-owned managed `PreToolUse`
validator permits only the exact documented client forms and denies compound,
wrapped, redirected, substituted, backgrounded, or malformed variants before
Claude evaluates sandbox exclusions. The operator-invoked hostile probe activates a
fixed hook mode that rewrites harmless marker calls into those exact clients;
normal agent sessions cannot activate the rewrites, and the probe separately
feeds a compound client event directly to the root-owned validator.

Boundary system units and adapters are root-owned. The systemd user manager is
not trusted; agent units, dispatcher, poller, and escape runners do not execute
from its search path. The launcher refuses an incomplete or writable asset
inventory and an unprobed Claude digest.

### Untrusted pack containment

Upload size is bounded while streaming. A fresh quarantine store runs strict
Git indexing without thin-pack repair. Physical objects, expanded objects,
delta chains, ancestry, and exact expected object sets are bounded. Title,
body, identities, signatures, tree names, and blobs are scanned before a write.

### Network destination control

Only HTTPS policy endpoints are accepted. DNS results are address-classified;
one forbidden answer rejects the destination unless private networking was
explicitly allowed. Accepted addresses and policy ports are pinned for Git and
REST. Redirects, proxies, ambient Git config, alternate object stores, lazy
fetch, credential helpers, and interactive prompts are disabled.

### Durable authority

Required approval is a zero-write state. Metadata and pack digests are
HMAC-protected. Approval rechecks content and the complete policy digest under a
per-slug lock. Auto mode is durable before its first write. UUID replay is
permanently reserved; terminal tombstones make retries and status deterministic.

### Notification confinement

The queue accepts only a versioned enum and bounded identifiers/error codes.
The bot renders fixed templates. Captured stderr, PR body, commit text,
filenames, and arbitrary producer fields cannot become Telegram text.

## Local-mode boundary

Anyone with Docker access has operator authority and can read the token or
rewrite policy. Same-UID processes outside the dedicated Claude sandbox can
read the loopback bearer; the bearer is defense in depth, not uploader identity.
The agent must not have Docker access.

## Non-goals and current limits

- Protecting against a compromised root, Docker daemon, broker host, forge,
  trusted builder, signing-key channel, or dedicated operator account.
- Local Codex hard-boundary mode.
- SHA-256 Git object format and binary protocol framing.
- GHES. Self-managed GitLab is experimental and requires explicit endpoint
  confirmation/private-network opt-in.
- Unlimited full packs; mature repositories can exceed conservative caps.

## Incident response

Stop agent sessions and broker intake. Revoke the forge token first if exposure
is possible. Preserve audit, policy, MAC key, pending stores, tombstones, and
container/system logs. Do not rotate the MAC key with pending requests; drain or
quarantine them first. Reinstall only from a release verified through both
chains in [supply chain](supply-chain.md).
