# Fieldwork

[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![Version](https://img.shields.io/github/v/tag/bprateeek/fieldwork?label=version&sort=semver)](CHANGELOG.md)

**Run a coding agent locally or on a VPS without giving it your forge write token.**

Fieldwork puts the credential in a checkout-blind broker. The agent produces a
clean Git commit, builds a non-thin Git pack, and uploads metadata plus that
pack. The broker reconstructs it in quarantine, scans it, applies an
operator-owned repository policy, and only then pushes the pinned commit and
opens a pull or merge request.

## Choose a mode

### Local hard-boundary mode

> **Unreleased acceptance gate:** the implementation is present for review,
> but must not be represented as a supported security boundary until the
> separately protected trusted builder is deployed and the documented real
> macOS/Linux forge-and-reboot acceptance run has passed.

Local mode runs the credential-bearing broker in hardened Docker containers and
launches Claude as a dedicated OS user with root-owned managed policy.

```sh
sudo bash lib/local/install.sh
sudo fieldwork-local up
sudo fieldwork-local token
sudo fieldwork-local wire my-repo owner/my-repo --base-branch main
sudo fieldwork-local claude --login
sudo fieldwork-local probe my-repo
sudo fieldwork-local claude my-repo
```

Local hard-boundary mode is Claude-only in the planned release. Docker access is
operator authority: anyone who controls the engine can read the forge token or
rewrite policy. See [local mode](docs/local-mode.md).

### VPS mode

VPS mode runs root-owned system units on Ubuntu 24.04 and keeps the broker under
a separate Linux identity.

```sh
git clone https://github.com/bprateeek/fieldwork.git ~/fieldwork
cd ~/fieldwork
bash install.sh
fieldwork setup
```

No VPS yet:

```sh
fieldwork provision hetzner
fieldwork setup
```

See the [quickstart](docs/quickstart.md) and [full setup guide](docs/setup.md).

### Credential-free evaluation

```sh
fieldwork eval up
fieldwork eval smoke
fieldwork eval down
```

The evaluation exercises protocol v2, Git quarantine, approval durability, and
idempotent resume without a real credential or network write.

## Delivery contract

After verification and a clean commit, the upload phase is exactly two
top-level calls:

```sh
fieldwork-pr-build .fieldwork/local/pr-build-request.json
/usr/local/bin/fieldwork-pr-upload <request-id>
```

The first command is sandboxed and writes only `meta.json` and `pack` to a
private per-UID spool. The second is a root-installed, subprocess-free uploader.
It is the only delivery client excluded from the agent network sandbox.

## Security properties

- The broker never reads an agent checkout.
- Repository destinations, base branches, approval mode, CA material, and
  private-network opt-in are broker-owned policy.
- `approval=require` performs no forge write before approval; deny and expiry
  perform none.
- Pending metadata is MAC-protected; packs and MAC keys are broker-only.
- Forge DNS answers are classified and pinned; redirects are disabled.
- GitHub and GitLab PR/MR creation use host-pinned REST, not `gh` or `glab`.
- Boundary runners and adapters are root-owned system assets.
- Telegram messages are rendered from a typed enum, never producer text.

Read [the architecture](docs/architecture.md), [broker contract](docs/broker-contract.md),
and [threat model](docs/threat-model.md) before using Fieldwork for a serious
repository.

## Developer preview

Supported today: Ubuntu 24.04 VPS; GitHub; experimental self-managed GitLab;
Claude; and VPS Codex over SSH. The local macOS/Linux implementation is present
but remains behind the acceptance gate above.

Deferred: local Codex hard-boundary mode, SHA-256 Git repositories, GHES,
Gitea, team RBAC, and automatic upgrades. See [known limitations](docs/known-limitations.md).

## Contributing

Fieldwork is security-sensitive infrastructure. Prefer small changes with
focused adversarial tests. Start with [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
