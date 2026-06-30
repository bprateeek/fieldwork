# Setup

This is the full guided setup path for Fieldwork. Start with `fieldwork setup`; use this page when you want to understand each phase or run a step manually.

## Prerequisites

You need:

- A Mac or Linux workstation with `bash`, `git`, `ssh`, `scp`, `rsync`, and `jq`.
- A small Ubuntu 24.04 VPS that `fieldwork setup` can connect to. Hetzner is
  the tested developer-preview baseline, but Fieldwork does not depend on
  Hetzner APIs.
- A normal Linux user on the VPS, usually `fieldwork`; setup can create it through one-time root SSH or another sudo-capable VPS account when you approve.
- Claude Code authenticated on the VPS when using `--agent claude` or `--agent both`.
- Codex CLI authenticated on the VPS when using `--agent codex` or `--agent both`.
- For GitHub projects: GitHub CLI authenticated on the VPS for repo-resolution
  preflights, a GitHub repo, and a fine-grained GitHub PAT for the broker by
  default. GitHub App credential mode is available with an App id,
  installation id, and private key.
- For GitLab projects: `forge = "gitlab"` in config or
  `FIELDWORK_FORGE=gitlab`, a GitLab project, explicit `commit_name` and
  `commit_email`, and a GitLab Project Access Token for the broker with
  Developer role plus `api` and `write_repository` scopes. For self-managed
  GitLab, set `gitlab_api` / `FIELDWORK_GITLAB_API` to the exact
  `https://host/api/v4` root before setup/onboard.

Fieldwork assumes project checkouts live under `/home/fieldwork/projects/<slug>` unless you override config.

## 1. Install Locally

From your workstation:

```sh
git clone https://github.com/bprateeek/fieldwork.git ~/fieldwork
cd ~/fieldwork
bash install.sh
fieldwork setup --agent claude
```

`bash install.sh` links the local `fieldwork` command into `~/.local/bin`, links Fieldwork-owned scripts/templates/infra into `~/.fieldwork`, and keeps Claude discovery assets under `~/.claude`. It does not install secrets or change repositories.

If `--agent` is omitted, setup prompts in an interactive terminal and defaults to `claude`. Use `--agent codex` for the Codex Desktop + SSH path or `--agent both` to prepare both surfaces on the same VPS.

If `~/.local/bin` is not on `PATH`, add it to your shell profile:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## 2. Prepare VPS Access

Run `fieldwork setup` and let it connect your VPS. When the alias is missing,
setup asks for the VPS hostname or IP and can append this managed SSH config
entry after confirmation:

```sshconfig
Host fieldwork-vps
  HostName <vps-host-or-ip>
  User fieldwork
  IdentityFile ~/.ssh/<key>
```

Fieldwork uses normal SSH and does not manage your network path. Use whatever fits your setup: public IP, DNS name, a private-network hostname (Tailscale, WireGuard, or similar that you install yourself), VPN address, or a bastion-backed SSH config.

For the long-form infrastructure walkthrough, use [first-time-infrastructure.md](first-time-infrastructure.md).

### SSH config

Both `fieldwork setup` and `fieldwork provision` write a **Fieldwork-managed** block, delimited by `# BEGIN/END FIELDWORK SSH CONFIG: fieldwork-vps`. How a re-run treats `~/.ssh/config`:

- **No block yet**: appends the managed block (the file is created `0600` if missing).
- **One managed block, stale**: refreshes it in place. Your previous file is saved to a timestamped `~/.ssh/config.fieldwork.<UTC>.bak` first; an already-current block is left untouched (no backup churn).
- **A hand-authored `Host fieldwork-vps`** (no Fieldwork markers): left **byte-identical**; setup/provision warn and ask you to reconcile it by hand against the block above.
- **Two or more managed blocks** for the host: refused as ambiguous; remove the duplicates (leave one) and rerun.
- **`~/.ssh/config` is a symlink**: refused (not followed); edit the target by hand.

## 3. Sync And Bootstrap The VPS

Copy the current Fieldwork checkout to the VPS:

```sh
fieldwork sync-vps
```

Then bootstrap the VPS as the `fieldwork` user:

```sh
ssh -t fieldwork-vps 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'
```

Bootstrap installs the VPS runtime, user systemd units, Claude Code support when configured, the verify runner socket, and the pr-prepare runner socket. It writes a private command log under `~/.cache/fieldwork/`.

For raw installer output:

```sh
ssh -t fieldwork-vps 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps --verbose'
```

Complete the manual account steps when setup asks:

```sh
ssh -t fieldwork-vps '~/.local/bin/claude login'
ssh -t fieldwork-vps 'gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key'
```

For Codex, setup additionally verifies that `codex` resolves on the non-interactive SSH login PATH, is at least the reviewed minimum version, `loginctl enable-linger fieldwork` is active, `$XDG_RUNTIME_DIR` points at `/run/user/<fieldwork-uid>`, runner sockets are enabled, and Codex's sandbox can connect to the Fieldwork broker/runner Unix sockets. Setup uses the pinned npm package in `FIELDWORK_CODEX_NPM_PACKAGE` when it offers to install Codex, defaulting to `@openai/codex@0.137.0`. Setup writes the Fieldwork socket allowlist into Codex config before accepting Codex readiness.

For GitHub profiles, Fieldwork preselects GitHub.com, SSH git protocol,
browser/device auth, and skip-SSH-key upload for `gh auth login`. Do not paste
the broker token. Browser
login gives GitHub CLI its own token after you approve the device code. On a
headless VPS, `gh` may warn that credentials were saved in plain text because
no OS keychain is available; that token lives under the `fieldwork`
user's GitHub CLI config and is separate from the broker token. The broker token is
installed later into the broker user's root-owned config path.

For GitLab profiles, setup skips GitHub CLI login. Agent-side onboarding does
not call the GitLab API; broker `/preflight` proves the broker token can see the
project, while clone/default-branch checks use tokenless git over the read-only
deploy key. If `gitlab_ca_bundle` is set to a local PEM path, setup uploads it
to the VPS as `/etc/fieldwork/gitlab-ca.pem` and stores only that broker-side
path in the broker environment.

Once a private SSH path is working (Tailscale, WireGuard, or similar that you set up yourself), point `HostName` at the private name and consider restricting public SSH:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' ufw delete allow 22/tcp"
```

## 4. Install The PR Broker

`fieldwork setup` guides this phase. To run it directly:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh"
```

The broker installer creates:

- `fieldwork-pr-broker` system user.
- `/run/fieldwork-pr-broker/fieldwork-pr.sock` for agent PR submissions.
- `/run/fieldwork-pr-broker/fieldwork-pr-approve.sock` for bot approvals.
- `/var/lib/fieldwork-pr-broker/requests` replay ledger.
- `/var/lib/fieldwork-pr-broker/pending` approval queue.
- `/usr/local/sbin/rotate-pat`.

The installed submit socket defaults to the agent user's primary group, not a dedicated supplementary group. That matters because sandboxed agent sessions can strip supplementary groups.

## 5. Store The Broker Forge Credential

For GitHub, PAT mode is the default. Create a fine-grained GitHub PAT for the
broker. Required permissions:

- Contents: read/write.
- Pull requests: read/write.
- Metadata: read.

Optional permission:

- Workflows: read/write, only if Fieldwork will push `.github/workflows/**`.

Default onboarding includes workflow templates. Use `fieldwork onboard <owner>/<repo> --no-workflows` if you want to avoid granting Workflows permission.

For GitLab, create a Project Access Token on the target project with Developer
role and `api` plus `write_repository` scopes. GitLab tokens do not have a
required prefix; `rotate-pat` proves liveness with `/user` and stores the token
without placing it in argv or environment.

Store the token interactively:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' env FIELDWORK_ROTATE_PAT_TTY=1 /usr/local/sbin/rotate-pat"
```

Paste the token only after `rotate-pat` prompts for it. The token is written to `/etc/fieldwork-pr-broker/gh-token`, owned by `fieldwork-pr-broker`, mode `600`.

Advanced GitHub option: instead of a PAT, set `FIELDWORK_GITHUB_CREDENTIAL_MODE=app`
when running `rotate-pat` and provide `FIELDWORK_GITHUB_APP_ID`,
`FIELDWORK_GITHUB_APP_INSTALLATION_ID`, and the GitHub App private key PEM on
stdin. The broker stores the private key and mints short-lived installation
tokens for requests.

## 6. Verify The Host

Run:

```sh
fieldwork doctor --remote --explain
fieldwork verify-security
```

`doctor` tells you the next setup action. `verify-security` checks token permissions, socket permissions, broker hardening, notification isolation, optional approval-bot separation, and optional per-repo origin state.

`fieldwork setup` reuses SSH connections during a run with OpenSSH
ControlMaster and verifies setup state with one remote probe when possible.
The control sockets live under `~/.cache/fieldwork/ssh-control/` and can be
reset safely:

```sh
rm -rf ~/.cache/fieldwork/ssh-control
```

To disable connection reuse for one command, run:

```sh
FIELDWORK_SSH_MULTIPLEX=0 fieldwork setup
```

## 7. Onboard A Repo Or Project

For the recommended approval-gated flow:

```sh
fieldwork onboard <project> --with-approval-gate
```

Without the approval marker:

```sh
fieldwork onboard <project>
```

To avoid workflow templates:

```sh
fieldwork onboard <project> --no-workflows
```

Use `owner/repo` for GitHub. Use the GitLab project path for GitLab, including
nested groups such as `group/subgroup/project`. Onboarding is resumable. It
clones with a read-only deploy key, applies repo templates, and asks the broker
to open the init PR or MR. For GitLab, `.github/` templates, branch protection,
secret scanning, and CodeQL setup are skipped. In Claude mode it also primes
Claude workspace trust and remote-control consent and starts
`fieldwork-agent@<slug>.service`; those two Claude prompts are interactive
confirmations that Fieldwork cannot safely automate. In Codex mode, Codex
Desktop owns the live SSH connection and remote-project folder state.

Inspect progress without changing state:

```sh
fieldwork onboard <project> --status
```

If Fieldwork-managed templates changed after an upgrade, refresh an existing onboarded repo:

```sh
fieldwork onboard <project> --reseed-templates
```

## 8. Prove The Broker Path

Before relying on a mobile agent session, create a broker-only PR:

```sh
fieldwork smoke <owner>/<repo>
```

This does not use Claude or Codex. It proves the checkout, broker socket, broker token, push, and PR creation path. Close or merge the smoke PR afterward. `fieldwork smoke` is GitHub-only; for GitLab, use a throwaway project and exercise onboarding, broker preflight, push/MR creation, approval-gated push, no-diff, and verify-fail paths.

## 9. Start A Work Session

If onboarding did not already start the session, run:

```sh
fieldwork start <repo-slug>
```

Check status:

```sh
fieldwork status <repo-slug>
fieldwork bot-status
```

In Claude mode, open Claude mobile and select `vps-<repo-slug>`.

In Codex mode, sign in to Codex Desktop, go to `Connections -> SSH`, add or open
the VPS connection as `fieldwork`, and in Details enable `"Available from signed-in devices"`
for mobile access. Open the VPS checkout folder
`/home/fieldwork/projects/<repo-slug>` on mobile or desktop and work via the
repo's `AGENTS.md` delivery instructions. If the folder does not appear, run
`fieldwork doctor --remote <repo-slug> --explain`. Fieldwork diagnoses stale
Codex app-server state, version drift, and missing Desktop folder state, but it
does not start or restart a Codex service. Before asking Codex to create a PR,
confirm the mobile header shows the repo on the configured VPS SSH connection
(for example, `fieldwork-vps`; it may display as the server name), not the
local Mac/Windows host.

## 10. Create A PR From Mobile

Ask the agent to make a change. Claude uses the repo template's `pr-delivery` skill. Codex uses `AGENTS.md`. The delivery flow is:

1. Print intended paths and rationale.
2. Run `/verify-before-pr`.
3. Write `.fieldwork/local/pr-prepare-request.json`.
4. Call `fieldwork-pr-prepare`.
5. Write `.fieldwork/local/pr-request.json`.
6. Call `fieldwork-pr-submit`.
7. If gated, wait for approval.
8. Broker pushes and opens the PR.

After merge, refresh the VPS checkout:

```sh
fieldwork refresh <slug>
```

## Repair Commands

Use these first:

```sh
fieldwork doctor --remote --explain
fieldwork verify-security [repo-slug]
fieldwork report [repo-slug]
```

For known failure patterns, see [troubleshooting.md](troubleshooting.md).

## Optional integrations

These are not part of the core setup path and can be configured at any time:

- Notifications: [notifications.md](notifications.md)
- Approval gate: [approval-gate.md](approval-gate.md)
