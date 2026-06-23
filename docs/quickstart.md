# Quickstart

This is the short guided VPS path. For a no-VPS demo, start with
[evaluation.md](evaluation.md).

The public command is resumable:

```sh
fieldwork quickstart --agent codex
fieldwork quickstart <owner>/<repo> --agent codex --with-approval-gate
```

Quickstart records only phase completion under
`~/.config/fieldwork/quickstart/`: setup completion is per Fieldwork profile,
and onboarding completion is per repo. It skips completed phases on later runs
and delegates the real work to the existing setup and onboarding flows.

To preview remaining setup friction without changing the VPS, repo, or local
quickstart ledger, run:

```sh
fieldwork quickstart <owner>/<repo> --dry-run
```

The dry run delegates to `fieldwork doctor --remote --explain`, so it reports the
same readiness rows and next action that setup would use before mutating.

Run `fieldwork setup` first only if you want the step-by-step command path.

For developer preview fit and support boundaries, read [developer-preview.md](developer-preview.md).

The VPS path assumes you either already have, or are ready to create:

- a Mac or Linux workstation with `git`, `ssh`, `jq`, and `bash`
- an Ubuntu 24.04 VPS; Hetzner is the known-good tested baseline
- a GitHub repo
- a Claude Code account for `--agent claude`, or an OpenAI/Codex account for `--agent codex`

If you do not have the VPS user, SSH alias, or GitHub token yet, quickstart's
setup phase will guide the next step.

## Infrastructure Overview

Fieldwork is intentionally opinionated for developer preview:

- **VPS**: use a small Ubuntu 24.04 server. The original tested path uses Hetzner, but any equivalent Ubuntu VPS should work.
- **SSH access**: Fieldwork uses normal SSH. Configure `~/.ssh/config` however you like: public IP, DNS name, a private-network name (Tailscale, WireGuard, or similar that you install yourself), VPN address, or a bastion-backed SSH config. Bootstrap opens public port 22 with fail2ban; restricting it later is your call.
- **Notifications**: optional. Use ntfy if you want mobile pushes when Claude needs input, finishes a turn, or fails. Codex lifecycle notifications are not wired in this milestone.
- **Source control**: use GitHub. The broker opens PRs; humans still merge.

## 1. Install Fieldwork Locally

```sh
git clone https://github.com/bprateeek/fieldwork.git ~/fieldwork
cd ~/fieldwork
bash install.sh
fieldwork setup --agent claude
```

`bash install.sh` links the local `fieldwork` command into `~/.local/bin`, links Fieldwork-owned scripts/templates/infra into `~/.fieldwork`, and keeps Claude discovery assets under `~/.claude`. It does not install secrets or change GitHub repositories.

If `--agent` is omitted, setup prompts in an interactive terminal and defaults to `claude`. Use `fieldwork setup --agent codex` for the Codex Desktop + SSH path, or `--agent both` if you want both surfaces on one VPS.

The guided setup checks local dependencies and PATH, then guides VPS access, remote Fieldwork install, VPS bootstrap, interactive logins, and PR services one phase at a time. If `fieldwork` is missing, setup can offer to create the normal `fieldwork` user through root SSH or another sudo-capable VPS account after showing exactly what it will change. With confirmation, it can append a Fieldwork-managed `Host fieldwork-vps` block to `~/.ssh/config`; it will not overwrite an existing user-authored block.

`fieldwork setup` prints a setup map and a status legend for `[ready]`, `[needs-action]`, `[manual]`, `[blocked]`, and `[info]` rows in copied output. When a phase still has unfinished work, setup summarizes that before moving on, then ends with one primary `Next action`, one `After completing it` command, and any remaining follow-ups it already found. Do the next action, then rerun:

```sh
fieldwork setup
```

When something is missing, use the repair guide:

```sh
fieldwork doctor --remote --explain
```

It groups checks by technical area, explains why each pending item matters, and ends with the next action plus remaining follow-ups.

You can still run the notification step directly:

```sh
fieldwork setup-notify
```

This writes `~/.fieldwork/notify.env` and sends a local ntfy test push. Anyone who knows the ntfy topic can read pushes for that topic, so keep it private.

## 2. Connect The VPS When Setup Asks

When `fieldwork setup` asks for the VPS hostname or IP, it can append this managed SSH alias for you:

```sshconfig
Host fieldwork-vps
  HostName <vps-host-or-ip>
  User fieldwork
  IdentityFile ~/.ssh/<key>
```

For first-time SSH key and VPS user setup details, use [first-time-infrastructure.md](first-time-infrastructure.md). That document is the reference version of the steps that setup cannot safely automate.

You can override the alias with:

```sh
FIELDWORK_SSH_HOST=my-vps fieldwork onboard <owner/repo>
```

## 3. Bootstrap The VPS When Setup Asks

Put Fieldwork on the VPS. For developer preview testing, copying your local checkout is the simplest path:

```sh
fieldwork sync-vps
```

Then run bootstrap as the `fieldwork` sudo-capable user:

```sh
ssh -t fieldwork-vps 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'
```

Bootstrap shows concise phase progress and saves the full command log under `~/.cache/fieldwork/` on the VPS. Use `./bin/fieldwork bootstrap-vps --verbose` if you want to watch raw installer output.

Complete the interactive follow-ups. `fieldwork setup` can offer to open each
SSH session for you and then continue after the account prompt exits:

```sh
ssh -t fieldwork-vps '~/.local/bin/claude login'
ssh -t fieldwork-vps 'gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key'
```

These commands authenticate Claude Code on the VPS and authenticate GitHub CLI for repo-resolution preflights. For Codex, setup guides `codex login`, verifies Codex resolves on the SSH login PATH, enables linger/runner sockets, and checks the Codex sandbox Unix-socket allowlist. Fieldwork preselects GitHub.com, SSH git protocol, browser/device auth, and skip-SSH-key upload for `gh auth login`; do not paste the broker PAT there. Browser login still gives GitHub CLI its own token after you approve the device code; on a headless VPS, `gh` may warn that credentials were saved in plain text because no OS keychain is available. That token is separate from the broker PAT, which is checked later through the broker socket, without sudo impersonation. Bootstrap installs the `fieldwork-agent@` systemd user unit template for Claude and the runner socket units used by both agents.

When a command shows `[sudo] VPS Linux password for fieldwork:`, enter the VPS
Linux password for the `fieldwork` user. It is not your Claude account password or
the GitHub PAT.

Once a private SSH path is working (Tailscale, WireGuard, or similar that you set up yourself), consider restricting public SSH:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' ufw delete allow 22/tcp"
```

## 4. Install The Broker When Setup Asks

`fieldwork setup` guides this as the Install PR services step. If you run the installer
directly, it shows concise step progress and saves the full root-only log under
`/var/log/fieldwork/`:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh"
```

By default, create a fine-grained GitHub PAT with:

- Contents: read/write
- Pull requests: read/write
- Metadata: read

The default onboarding template includes `.github/workflows/**`, so it also needs Workflows read/write. If you want a narrower token or do not want Fieldwork's workflow templates in the init PR, onboard with `fieldwork onboard <owner>/<repo> --no-workflows` and add workflow files manually later.

Place the token interactively so it does not land in shell history:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' env FIELDWORK_ROTATE_PAT_TTY=1 /usr/local/sbin/rotate-pat"
```

If sudo asks for a password, enter the VPS Linux password for the `fieldwork` user.
This is not your Claude account password and not the GitHub PAT. After sudo
succeeds, paste the token when prompted, then press Enter. The token input is
hidden.

If the broker socket is reported as not writable, run `fieldwork doctor --remote --explain`. In the default install the submit socket uses the `fieldwork` user's primary group; custom socket-group overrides may require reconnecting to pick up group membership.

If setup created the `fieldwork` user for you over root SSH or another sudo-capable VPS account, rerun `fieldwork setup` after the broker socket is writable. It will offer to remove the temporary passwordless sudo rule so the broker PAT remains isolated from agent sessions. Bootstrap disables root SSH, so keep another sudo-capable account if you plan to delete and recreate `fieldwork` later.

Verify the remote setup:

```sh
fieldwork doctor --remote --explain
```

Then verify the broker trust boundary:

```sh
fieldwork verify-security
```

## 5. Onboard a Repo

On your local machine:

```sh
fieldwork quickstart <owner>/<repo> --with-approval-gate
```

This resumes from the first incomplete quickstart phase. If setup has already
completed through quickstart, it will not run setup again. If you prefer to drive
only the repo onboarding phase directly, use:

```sh
fieldwork onboard <owner>/<repo> --with-approval-gate
```

Use plain `fieldwork onboard <owner>/<repo>` only if you do not want Telegram approval before broker pushes.

Use `--no-workflows` if the broker PAT should not have Workflows read/write permission:

```sh
fieldwork onboard <owner>/<repo> --no-workflows
```

Advanced: the broker can use a GitHub App instead of a PAT by running
`rotate-pat` with `FIELDWORK_GITHUB_CREDENTIAL_MODE=app`, the App id, the
installation id, and the App private key PEM.

In Claude mode, the command pauses for three manual actions:

- paste a read-only deploy key into GitHub
- run Claude's workspace-trust prompt; Fieldwork cannot safely automate this
- run Claude's remote-control consent prompt; Fieldwork cannot safely automate this

In Codex mode, Codex Desktop owns the SSH session lifecycle and remote-project picker, so there is no per-repo Codex service to start. The command opens an init PR through the broker and writes a non-secret checkpoint under `.fieldwork/local/` in the VPS checkout, so rerunning the same command resumes from the next incomplete step.

To inspect progress without changing anything:

```sh
fieldwork onboard <owner>/<repo> --status
```

If the checkpoint looks stale or corrupt, remove only that checkpoint and let Fieldwork recompute what it can:

```sh
fieldwork onboard <owner>/<repo> --reset-state
```

## 6. Prove The Broker Path

Before testing mobile-agent behavior, create a tiny PR through the broker only:

```sh
fieldwork smoke <owner>/<repo>
```

This does not use Claude or Codex. It proves the onboarded checkout, broker socket, broker PAT, GitHub branch push, and PR creation path. If the repo is approval-gated, approve the queued smoke request first; then review and close or merge the smoke PR after it opens.

## 7. Use It Day to Day

For Claude, open Claude mobile, select `vps-<repo-slug>`, and describe the task. Claude works on the VPS, opens a PR through the broker, and ntfy tells you when input or review is needed.

For Codex, open Codex Desktop, go to `Connections -> SSH`, add or open the VPS
connection as `fieldwork`, and in Details enable `"Available from signed-in devices"`
for mobile access. Then open `/home/fieldwork/projects/<repo-slug>` on
mobile or desktop and describe the task. Codex follows `AGENTS.md` for verify,
prepare, submit, approval-gate, and no-direct-push behavior. If the remote folder
is missing, run `fieldwork doctor --remote <repo-slug> --explain`. Codex works in
the canonical checkout, so avoid concurrent Codex tasks or simultaneous
Claude+Codex work on that checkout. Before asking Codex to open a PR from
mobile, make sure the mobile header shows the repo on the configured VPS SSH
connection (for example, `fieldwork-vps`; it may display as the server name),
not the local Mac/Windows host.

If the init PR's workflow checks fail, read the failing jobs before merging. A failed workflow may mean the template needs project-specific tuning, GitHub Actions billing is locked, or the repo should have been onboarded with `--no-workflows`.

After merging any PR, refresh the VPS checkout:

```sh
fieldwork refresh <slug>
```
