# Quickstart

## Local Claude mode

Release target prerequisites: Ubuntu 24.04 Linux, Docker, Git, and Claude.
Verify the release through both chains in [supply chain](supply-chain.md), then:

```sh
sudo env FIELDWORK_CLAUDE_BIN="$(command -v claude)" bash lib/local/install.sh
sudo fieldwork-local up
sudo fieldwork-local token
sudo fieldwork-local wire app owner/app --base-branch main
sudo fieldwork-local claude --login
sudo fieldwork-local probe app
sudo fieldwork-local claude app
```

Put the checkout in `/srv/fieldwork/projects/app` and make it owned by
`fieldwork-agent`. Wiring defaults to required approval. The macOS
implementation is not included in this release target and remains unreleased
until its real-hardware acceptance gate is completed.

Inside the dedicated Claude session, commit a `fieldwork/...` branch and use
the two-call upload contract documented in [local mode](local-mode.md).

## VPS mode

Prerequisites: Mac/Linux workstation, Ubuntu 24.04 VPS, GitHub or GitLab
project, and Claude or Codex access.

```sh
git clone https://github.com/bprateeek/fieldwork.git ~/fieldwork
cd ~/fieldwork
bash install.sh
fieldwork setup --agent claude
```

Setup checks the local tools and SSH alias, syncs Fieldwork, bootstraps the VPS,
installs root-owned boundary units and the checkout-blind broker, guides agent
authentication, and asks for a broker credential. Rerun it after every manual
step:

```sh
fieldwork setup
fieldwork doctor --remote --explain
```

No VPS yet:

```sh
fieldwork provision hetzner
fieldwork setup
```

Onboard and start:

```sh
fieldwork onboard owner/app
fieldwork start app
```

The agent works on a read-only-cloned checkout. After a clean commit it runs
`/usr/local/bin/fieldwork-pr-build .fieldwork/local/pr-build-request.json`
and then the absolute root-owned uploader. The broker
fetches the operator-wired base, validates the pack in quarantine, and either
queues or opens the PR/MR.

After merge:

```sh
fieldwork refresh app
```

## Credential-free evaluation

```sh
fieldwork eval up
fieldwork eval smoke
fieldwork eval down
```

This verifies protocol-v2 quarantine and lifecycle behavior without a forge
write.

## Important boundaries

- Docker access is authority in local mode; never grant it to the agent.
- Local hard-boundary mode is Claude-only.
- VPS Fieldwork boundary services are root-owned system units; stale user units
  are disabled.
- New policies default to required approval.
- The broker accepts SHA-1, non-thin packs only.
- Installation from a release requires both tag and provenance verification.

Continue with [full setup](setup.md), [architecture](architecture.md), and
[threat model](threat-model.md).
