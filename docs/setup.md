# VPS setup

This guide covers the Ubuntu 24.04 hard-boundary deployment. For no-VPS usage,
see [local mode](local-mode.md).

## Prerequisites

- macOS or Linux workstation with Bash, Git, SSH, rsync, and jq;
- Ubuntu 24.04 VPS with a normal sudo-capable `fieldwork` user;
- Claude for remote-control mode, Codex Desktop for VPS SSH mode, or both;
- GitHub or GitLab repository and a least-privilege broker credential;
- a Fieldwork artifact verified through [both release chains](supply-chain.md).

GitHub CLI may be used during bootstrap/onboarding, but it is not a broker
runtime dependency.

## Workstation install

```sh
cd /path/to/verified/fieldwork
bash install.sh
fieldwork setup --agent claude
```

The convenience installer links the user CLI and discovery assets. Security
boundary components are copied root-owned on the VPS by setup; they are never
executed from those user symlinks in hard-boundary sessions.

Setup can create a marked `Host fieldwork-vps` SSH block after confirmation.
It preserves hand-authored blocks and refuses ambiguous duplicates or symlinked
SSH config.

## Sync and bootstrap

```sh
fieldwork sync-vps
ssh -t fieldwork-vps 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'
```

Bootstrap installs dependencies and calls the root boundary installer. Confirm:

```sh
ssh fieldwork-vps 'test -x /usr/local/bin/fieldwork-pr-upload'
ssh fieldwork-vps 'test -f /etc/systemd/system/fieldwork-agent@.service'
ssh fieldwork-vps 'systemctl is-active fieldwork-verify-runner.socket fieldwork-pr-prepare-runner.socket'
```

The verify and prepare sockets live under `/run/fieldwork`. The agent session,
event poller, task dispatcher, clients, runners, and adapters are root-owned.
The dashboard is disabled. Rootless Docker may remain user-scoped.

Authenticate Claude/Codex only when setup prompts. Claude hard-boundary launch
uses root-owned managed settings and empty setting/MCP sources. VPS Codex uses
its own sandbox with explicit access to the broker and two runner sockets.
For Claude, setup runs the root-owned hostile probe and records its exact pinned
executable digest. A failed, inconclusive, or changed digest keeps Claude
session startup disabled; rerun it explicitly with:

```sh
ssh -t fieldwork-vps \
  'sudo env FIELDWORK_REMOTE_USER=fieldwork /usr/local/sbin/fieldwork-session-probe-record'
```

## Install the broker

```sh
ssh -t fieldwork-vps \
  'sudo env FIELDWORK_REMOTE_USER="$(id -un)" bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh'
```

The install creates the broker identity, submit/approve sockets, non-enabled
maintenance socket, split pending stores, policy/CA stores, persistent HMAC key,
ledger, tombstones, REST/Git helpers, and root-owned protocol-v2 clients.

The broker service has no home/checkout access and has systemd device, process,
CPU, memory, and file-size limits.

## Credential

GitHub fine-grained PAT minimum:

- Contents read/write;
- Pull requests read/write;
- Metadata read.

Use workflow write permission only when the agent must change workflows.
GitLab project tokens need Developer role plus `api` and
`write_repository`.

```sh
ssh -t fieldwork-vps \
  'sudo env FIELDWORK_ROTATE_PAT_TTY=1 /usr/local/sbin/rotate-pat'
```

The helper reads from a TTY, validates forge reachability, and stores a broker-
only 0600 credential. GitHub App mode is supported through the documented
`FIELDWORK_GITHUB_CREDENTIAL_MODE=app` installer/rotation inputs.

## Onboard and wire

```sh
fieldwork onboard owner/app
```

Onboarding creates a read-only deploy-key clone and repository instructions,
then writes the broker policy through the privileged policy writer. It performs
a checkout-blind broker preflight against the policy slug before creating init
artifacts, so a stale credential or missing repository grant fails early.
Policy contains project, base branch, approval, fixed forge endpoints, CA
reference, and private-network choice. Approval defaults to `require`.

For self-managed GitLab, explicitly confirm the HTTPS API/Git host and private
CA. Any access to private address space requires the policy opt-in.

Start Claude:

```sh
fieldwork start app
```

Codex users open `/home/fieldwork/projects/app` through Codex Desktop SSH.
Do not run Claude and Codex concurrently in one checkout.

## Delivery

The repository instructions require:

1. verify with `/usr/local/bin/fieldwork-verify "$PWD"`;
2. commit all intended files, using the prepare runner if required;
3. create a v2 build request with slug, `fieldwork/...` branch, title, body;
4. call `fieldwork-pr-build`;
5. call `/usr/local/bin/fieldwork-pr-upload <request-id>` separately.

Status is durable:

```sh
/usr/local/bin/fieldwork-pr-upload --status <request-id>
```

## Verify

```sh
fieldwork doctor --remote --explain
fieldwork verify-security
fieldwork smoke owner/app
```

The smoke command creates a clean commit, builds a real pack, and uses the v2
uploader. With required approval it queues without pushing; approve it, then
review/close the PR.

## Upgrade

Do not overwrite a running v1 install. Follow the maintenance transaction in
[runbook](runbook.md): stop sessions/intake, drain v1 pending work, verify and
install v2, re-wire policies, migrate exact-known instructions through PRs in
maintenance mode, then explicitly restart normal intake.
