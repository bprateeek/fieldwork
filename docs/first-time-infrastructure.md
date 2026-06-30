# First-Time Infrastructure

This is the reference manual behind `fieldwork setup`. You normally start with:

```sh
fieldwork setup
```

Use this document when setup says an infrastructure step is missing, or when you want to understand exactly what the command it printed does.

If you already have a reachable Ubuntu VPS with a `fieldwork` user, you can skip to [quickstart.md](quickstart.md).

If you are starting from nothing, setup will not create external accounts, buy a VPS, edit `~/.ssh/config`, log in to Claude, log in to GitHub for GitHub profiles, or paste your broker token. Those stay manual because they involve billing, browser/device approvals, local workstation config, or secrets. The value of setup is that it tells you which one is next, verifies it after you do it, and rechecks the remaining steps.

The purpose of this infrastructure is to create a narrow, repeatable control plane:

- Your workstation keeps the admin tools and SSH config.
- The VPS runs Claude or Codex work close to the code.
- Fieldwork uses normal SSH; if you want a private path, install Tailscale, WireGuard, or similar yourself outside Fieldwork.
- The `fieldwork` user runs day-to-day agent work.
- A separate broker owns the forge write token and only opens PRs/MRs.

## How To Read Commands

Commands marked "from your workstation" run on your Mac or Linux laptop. Commands marked "on the VPS" run after you SSH into the server.

Most examples use this pattern:

```sh
ssh fieldwork-vps 'whoami'
```

That command is typed on your workstation, but the quoted command runs on the VPS. Commands with `ssh -t` allocate a terminal because login flows, `sudo`, and consent prompts often need an interactive session.

## Accounts And Apps

Create or confirm access to:

- GitHub account with permission to create repositories and fine-grained personal access tokens.
- Claude Code account.
- OpenAI/Codex account if you use the Codex Desktop + SSH path.
- Hetzner Cloud account, or another provider that can create an Ubuntu 24.04 VPS.
- ntfy mobile app, so you can subscribe to the topic Fieldwork generates.

## 1. Create A Local SSH Key

`fieldwork setup` symptom: SSH alias or VPS access is blocked before a key exists.

On your workstation:

```sh
test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -C "fieldwork"
cat ~/.ssh/id_ed25519.pub
```

Add the public key to your VPS provider before creating the server.

## 2. Create The VPS

`fieldwork setup` symptom: VPS is not reachable because there is no server yet.

### Recommended: `fieldwork provision hetzner`

If you use Hetzner Cloud, Fieldwork can create the server for you. It uses the
[`hcloud` CLI](https://github.com/hetznercloud/cli) (macOS: `brew install hcloud`)
and a Hetzner Cloud API token. Fieldwork never reads or stores that token:
configure it once with `hcloud`:

```sh
hcloud context create fieldwork   # paste a Hetzner Cloud API token
# or: export HCLOUD_TOKEN=<token>
```

Then, from your workstation:

```sh
fieldwork provision hetzner --dry-run   # inspect the plan + cloud-init first
fieldwork provision hetzner
```

This creates an Ubuntu 24.04 server (default `cx23` in `nbg1`; override with
`--type` / `--location`), installs your `~/.ssh/id_ed25519.pub` key, creates the
`fieldwork` user with temporary passwordless sudo via cloud-init, writes the
`fieldwork-vps` alias to `~/.ssh/config`, and stops. It does **not** run setup.
continue with `fieldwork sync-vps` then `fieldwork setup` (steps 4 onward).

The server and its SSH key are labelled `managed-by=fieldwork`. To tear it down:

```sh
fieldwork provision hetzner --destroy
```

Steps 3 (create the `fieldwork` user) and the SSH-alias step below are handled by
provisioning. Skip ahead to step 4 once `ssh fieldwork-vps whoami` returns
`fieldwork`. The manual steps that follow remain the path for any other provider
or a bring-your-own VPS.

### Manual / bring-your-own VPS

Create a small Ubuntu 24.04 server. The developer preview is tested on Hetzner, but any equivalent VPS should work.

Recommended starting shape:

- Image: Ubuntu 24.04 LTS.
- Size: small shared CPU instance with at least 2 GB RAM.
- SSH key: the public key from step 1.
- Initial access: root SSH is okay only for first boot. If this is a reused
  VPS, any existing sudo-capable user can create or repair `fieldwork`.

Record the public IP. You will use it to create the non-root user and reach the VPS over SSH.

## 3. Create The `fieldwork` User

`fieldwork setup` symptom: SSH may work as `root` or another admin user, but Fieldwork needs an SSH alias that logs in as `fieldwork`.

From your workstation:

```sh
ssh root@<vps-public-ip>
```

This uses root only for first boot. On a reused VPS where root SSH is disabled,
log in as another sudo-capable account instead. Fieldwork itself should not run
as root. It runs as a normal `fieldwork` user with `sudo` available for setup
tasks.

On the VPS, run:

```sh
adduser fieldwork
usermod -aG sudo fieldwork
install -d -m 700 -o fieldwork -g fieldwork /home/fieldwork/.ssh
cp /root/.ssh/authorized_keys /home/fieldwork/.ssh/authorized_keys
chown fieldwork:fieldwork /home/fieldwork/.ssh/authorized_keys
chmod 600 /home/fieldwork/.ssh/authorized_keys
exit
```

What those commands do:

- `adduser fieldwork` creates the normal Linux user that will own projects and Claude sessions.
- `usermod -aG sudo fieldwork` allows that user to run setup commands with `sudo`.
- `install -d ... /home/fieldwork/.ssh` creates the SSH directory with safe permissions.
- `cp /root/.ssh/authorized_keys ...` lets the same SSH key you used for root also log in as `fieldwork`.
- `chown` and `chmod` make OpenSSH accept the authorized keys file.

If `fieldwork setup` creates the `fieldwork` user for you through root SSH or an
existing sudo-capable account, it configures temporary passwordless sudo for that
user so bootstrap and early root-owned setup can run without a Linux password
prompt. Once the broker is working, rerun `fieldwork setup`; it will offer to
remove `/etc/sudoers.d/fieldwork-fieldwork` so Claude sessions no longer have
passwordless root. If you create the user manually with `adduser`, bootstrap may
ask for the Linux password you set for `fieldwork`.

Bootstrap later disables root SSH and password SSH login. Before deleting the
`fieldwork` user on a reused VPS, make sure root SSH still works or that another
sudo-capable account remains. If neither exists, recovery requires your VPS
provider console or rescue mode.

Now add a workstation SSH alias. `fieldwork setup` can append this managed block
for you after confirmation. If you add it manually, it goes in `~/.ssh/config`
on your workstation, not on the VPS.

If the file does not exist yet:

```sh
mkdir -p ~/.ssh
touch ~/.ssh/config
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config
```

Open `~/.ssh/config` in your editor and add:

```sshconfig
Host fieldwork-vps
  HostName <vps-public-ip>
  User fieldwork
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

This alias is important because Fieldwork commands default to `fieldwork-vps`. It also keeps later commands stable if you later swap `HostName` for a private-network name.

Test it from your workstation:

```sh
ssh fieldwork-vps 'whoami && hostname'
```

Expected user is `fieldwork`. If it says `root`, fix the `User fieldwork` line before continuing.

## 4. Put Fieldwork On The VPS

`fieldwork setup` symptom: remote Fieldwork CLI is missing, or setup offers to run `fieldwork sync-vps`.

The VPS needs the Fieldwork scripts locally because bootstrap, broker install, repo templates, and systemd unit files are installed from this checkout.

For developer preview testing, the simplest path is to copy your local checkout:

```sh
fieldwork sync-vps
```

`fieldwork sync-vps` shows what it will copy and install before it asks for confirmation. It runs the remote installer quietly, configures the VPS shell profile for `~/.local/bin`, and uses `rsync --delete`, so `~/fieldwork/` on the VPS should be dedicated to Fieldwork.

If the Fieldwork repository is reachable from the VPS, cloning is also fine:

```sh
ssh fieldwork-vps 'git clone https://github.com/bprateeek/fieldwork.git ~/fieldwork && cd ~/fieldwork && bash install.sh'
```

## 5. Bootstrap The VPS

`fieldwork setup` symptom: Claude CLI, GitHub CLI, projects dir, or the `fieldwork-agent@` unit is missing.

Bootstrap installs the VPS runtime for remote coding work: system packages, GitHub CLI, firewall rules, fail2ban, user-mode systemd linger, rootless Docker, Claude Code, and the `fieldwork-agent@` systemd unit template.

It intentionally does not log in to Claude, log in to GitHub for GitHub profiles, or place the broker token. Those steps require browser/device prompts or secrets, so the human should do them explicitly. If you want a private network path, install Tailscale, WireGuard, or similar yourself outside Fieldwork.

During bootstrap, Fieldwork prints concise phase progress and saves the full command log under `~/.cache/fieldwork/` on the VPS with private directory and file permissions. If a phase fails, it prints the last relevant log lines and the full log path. To watch every installer line as it happens, pass `--verbose`.

Run the bootstrap as the `fieldwork` user:

```sh
ssh -t fieldwork-vps 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'
```

Verbose mode is useful when you are debugging a package manager or installer issue:

```sh
ssh -t fieldwork-vps 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps --verbose'
```

When it completes, `fieldwork setup` can guide these interactive follow-ups
from your workstation. It asks before opening each SSH session, then waits while
you complete the browser or account prompt. If you skip one, setup keeps going
through the rest of the phase and summarizes the unfinished item before moving
on:

```sh
ssh -t fieldwork-vps '~/.local/bin/claude login'
ssh -t fieldwork-vps 'gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key'
```

What each follow-up is for:

- `~/.local/bin/claude login` authenticates Claude Code on the VPS so the long-running remote sessions can start.
- `gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key` authenticates GitHub CLI on the VPS for GitHub read-only preflight checks such as resolving repositories. GitLab profiles skip this step and route token-required metadata through broker `/preflight`. This is separate from the broker token used for PR/MR pushes; onboarding checks that token through the broker socket after setup hardening, not through sudo.

When a command shows `[sudo] VPS Linux password for fieldwork:`, enter the VPS
Linux password for the `fieldwork` user. It is not your Claude account password or
the broker token.

For GitHub profiles, Fieldwork preselects GitHub.com, SSH as the preferred Git protocol, browser
login, and skip-SSH-key upload for `gh auth login`. Do not paste the broker token into gh;
the broker token belongs only to the `fieldwork-pr-broker` service user. Browser
login still gives GitHub CLI its own token after you approve the device code. On
a headless VPS, `gh` may say it could not open a browser; copy the printed code
and open `https://github.com/login/device` on your workstation. It may also warn
that authentication credentials were saved in plain text because no OS keychain
is available; that is the GitHub CLI token under the `fieldwork` user's config,
not the broker token.

If you set up a private network path (Tailscale, WireGuard, or similar that you install yourself), update `Host fieldwork-vps` to use the private hostname:

```sshconfig
Host fieldwork-vps
  HostName <vps-private-host-or-ip>
  User fieldwork
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

Confirm SSH still works, then consider restricting the public SSH firewall rule:

```sh
ssh fieldwork-vps 'whoami'
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' ufw delete allow 22/tcp"
```

If SSH fails after changing the alias, switch `HostName` back to the public IP, fix your private path, and try again. Do not remove the public SSH rule until the private path works.

Bootstrap does not reset UFW on reruns, so once you remove the public SSH rule, a later `bootstrap-vps` repair run should not add it back.

## 6. Set Up Notifications

Optional. `fieldwork doctor` reports local and remote notification config
informationally, but missing `notify.env` does not block setup, onboarding, or
PR delivery.

On your workstation:

```sh
fieldwork setup-notify
```

Subscribe to the generated topic in the ntfy mobile app. To copy the topic to
the VPS and trigger a remote test push:

```sh
fieldwork setup-notify --remote
```

Keep the topic private. Anyone who knows a public ntfy topic can read pushes for that topic.

## 7. Install The PR Broker

`fieldwork setup` symptom: PR broker socket is missing or not writable.

For GitHub, create a fine-grained personal access token in GitHub settings. The broker uses this token to push branches and open PRs; the agent itself does not receive it.

- Repository access: selected repositories you want Fieldwork to manage.
- Contents: read/write.
- Pull requests: read/write.
- Metadata: read.
- Workflows: read/write only if Fieldwork will add or update `.github/workflows/**`.

Default GitHub onboarding includes workflow templates. Use `fieldwork onboard <owner>/<repo> --no-workflows` if you want to keep the broker PAT narrower and add workflows manually later.

For GitLab, create a Project Access Token on the target project with Developer
role and `api` plus `write_repository` scopes. Configure `forge = "gitlab"` and,
for self-managed GitLab, `gitlab_api = "https://host/api/v4"`. GitLab onboarding
also requires explicit `commit_name` and `commit_email`; setup uploads
`gitlab_ca_bundle` to `/etc/fieldwork/gitlab-ca.pem` when a private CA is needed.

`fieldwork setup` normally guides this as the Install PR services step. If you
run the installer directly, it shows concise step progress and saves the full
root-only log under `/var/log/fieldwork/`:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh"
```

Place the token interactively so it does not land in shell history:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' env FIELDWORK_ROTATE_PAT_TTY=1 /usr/local/sbin/rotate-pat"
```

If sudo asks for a password, enter the VPS Linux password for the `fieldwork` user.
This is not your Claude account password and not the broker token. After sudo
succeeds, paste the token when prompted, then press Enter. The token input is
hidden.

Before storing the token, `rotate-pat` validates it against the selected forge:
GitHub uses `/rate_limit` plus an optional repo permission probe, while GitLab
uses `/user`. A token the forge definitively rejects is **not** stored and the
broker is left running on its previous token; a transient network failure prints
a warning and stores the token anyway. The guided `fieldwork setup` flow offers
an optional GitHub repo to validate against; to validate from the manual command,
prefix it with `FIELDWORK_PAT_PROBE_REPO=<owner>/<repo>`:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' env FIELDWORK_ROTATE_PAT_TTY=1 FIELDWORK_PAT_PROBE_REPO=<owner>/<repo> /usr/local/sbin/rotate-pat"
```

The broker installer defaults the submit socket to the `fieldwork` user's primary group so Claude's sandbox can still connect from inside its user namespace. If you override the broker socket group and `fieldwork doctor --remote --explain` later says the socket is not writable, reconnect to the VPS before onboarding so the new group membership is visible.

If setup created the `fieldwork` user for you through root SSH or another sudo-capable account, rerun setup after the broker socket is writable:

```sh
fieldwork setup
```

Setup will offer to remove the temporary passwordless sudo rule. This is the final privilege handoff: the broker service keeps the token, and agent sessions should no longer have passwordless root.

## 8. Create Or Choose A Repo Or Project

Fieldwork onboards a repo or project that already exists on GitHub or GitLab and records its default branch.

If you create the GitHub repo after creating the broker PAT, widen the existing fine-grained PAT or GitHub App installation to include the new repo. For GitLab, create or rotate a Project Access Token on the project. The deploy key used by `fieldwork onboard` is separate and stays read-only.

## 9. Verify

From your workstation:

```sh
fieldwork setup
fieldwork doctor --remote --explain
fieldwork verify-security
```

Expected:

- `claude`, GitHub `gh` when using GitHub, and the projects directory are ready.
- remote `notify.env` is present.
- `fieldwork-agent@` user unit is installed.
- PR broker socket is present.
- temporary passwordless sudo is absent, unless setup has not reached the broker handoff yet.
- broker token, socket, ledger, systemd hardening, and notification isolation checks pass or print one manual inspection command.

Then continue with:

```sh
fieldwork onboard <project>
```
