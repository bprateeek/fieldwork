# Troubleshooting

Start with the diagnostic commands:

```sh
fieldwork health
fieldwork doctor --remote --explain
fieldwork verify-security [repo-slug]
fieldwork bot-status
```

`fieldwork health` is the fastest first look: one line per area, exiting nonzero only when something is blocked. Use the deeper commands below once it points at an area.

To separate broker problems from Claude/mobile problems:

```sh
fieldwork smoke <owner>/<repo>
```

`fieldwork smoke` is GitHub-only. For GitLab, use a throwaway project and prove
the onboarding/broker MR path instead.

When a command shows `[sudo] VPS Linux password for fieldwork:`, enter the VPS Linux password for the `fieldwork` user. It is not your Claude account password and not the broker token.

## Starting Without VPS Or SSH

Use [setup.md](setup.md) for the guided path and [first-time-infrastructure.md](first-time-infrastructure.md) for the long-form infrastructure reference. With confirmation, setup can append a Fieldwork-managed SSH alias; it will not overwrite an existing user-authored `Host fieldwork-vps` block.

## VPS Unreachable

`fieldwork health` shows a single `blocked` row, `VPS: unreachable over SSH`, and exits nonzero. The remote probe could not establish an SSH connection (it skips the broker/bot snapshot so nothing hangs).

Check, in order:

```sh
ssh fieldwork-vps true          # does the alias resolve and connect?
fieldwork doctor --remote       # full remote diagnosis once SSH is back
```

Common causes: the VPS is powered off or rebooting; the `~/.ssh/config` alias points at the wrong host/IP; a firewall or network path is blocking port 22. If the box is fine but the alias is wrong, fix the `Host fieldwork-vps` block (or re-run `fieldwork provision`/`setup`).

## VPS Untrusted

`fieldwork health` shows `VPS: reachable but Fieldwork untrusted (<reason>)`. The SSH connection works, but the remote Fieldwork checkout does not match this copy, usually because you changed local Fieldwork code and have not synced it, or the remote checkout is stale.

```sh
fieldwork sync-vps      # push the local checkout to the VPS
fieldwork setup         # re-verify end to end
```

The `<reason>` mirrors the probe fallback reason (for example `partial`, `malformed`, `nonzero`, or `helper-missing`); if it persists after a sync, run `fieldwork doctor --remote --explain` for the per-check detail.

## `fieldwork` Command Not Found

Run:

```sh
cd ~/fieldwork
bash install.sh
```

If `~/.local/bin` is missing from `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Restart the shell or run `./bin/fieldwork` from inside the repo.

## VPS Still Uses Old Installed Assets

If install output says existing `~/.claude` assets were skipped, force refresh the VPS copy:

```sh
fieldwork sync-vps --force-install
```

Existing real files are backed up with `.bak.<timestamp>` before Fieldwork-managed links replace them.

## Stale Copied Skill In An Onboarded Repo

Onboarded repos receive copies of `lib/templates/repo`, not live symlinks. If Fieldwork upgraded a skill or hook and the repo still has the old copy:

```sh
fieldwork onboard <project> --reseed-templates
```

Then review the generated PR like any other repo change.

## Broker Token Cannot Reach Project

`fieldwork onboard` asks the broker over the submit socket to prove the broker-owned token can see the project. It does not expose the token to the `fieldwork` user.

For GitHub, required PAT permissions:

- Contents: read/write.
- Pull requests: read/write.
- Metadata: read.

Optional:

- Workflows: read/write, only when pushing `.github/workflows/**`.

If the fine-grained PAT is selected-repo scoped, add the repo to the existing PAT. Do not rotate unless you intend to replace the VPS token.

For GitLab, use a Project Access Token on the target project with Developer role
and `api` plus `write_repository` scopes. For self-managed GitLab, confirm
`FIELDWORK_GITLAB_API` / `gitlab_api` is the exact `https://host/api/v4` root and
that any private CA was uploaded through setup as `/etc/fieldwork/gitlab-ca.pem`.

If the error mentions broker socket, missing token, or preflight failure:

```sh
fieldwork doctor --remote --explain
```

If the broker appears to be running an old contract:

```sh
fieldwork sync-vps --force-install
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh"
```

## Broker Unreachable

Symptoms:

- `fieldwork-pr-submit` reports broker socket missing.
- `fieldwork smoke` cannot connect.
- `fieldwork status <slug>` shows Broker warning.

Repair:

```sh
fieldwork doctor --remote --explain
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' systemctl status fieldwork-pr-broker.socket fieldwork-pr-broker.service --no-pager"
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh"
```

If the token is missing:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' env FIELDWORK_ROTATE_PAT_TTY=1 /usr/local/sbin/rotate-pat"
```

## Submit Socket Permission Or Group Mismatch

Default installs rewrite the submit socket group to the `fieldwork` user's primary group, usually `fieldwork`. That is intentional for Claude's sandbox user namespace.

Check:

```sh
ssh fieldwork-vps 'stat -c "%U:%G %a" /run/fieldwork-pr-broker/fieldwork-pr.sock'
ssh fieldwork-vps 'id'
```

Expected default shape:

```text
fieldwork-pr-broker:fieldwork 660
```

If you deliberately configured a custom broker socket group, reconnect after install so the new group membership is visible. If Claude still cannot submit from inside the sandbox, use the agent user's primary group instead.

## Approve Socket Unreachable

Symptoms:

- Telegram button says broker unreachable.
- `fieldwork bot-status` reports approve socket unreachable.
- `fieldwork verify-security` fails the approve socket probe.

Check:

```sh
fieldwork bot-status
fieldwork verify-security
```

Restart the broker sockets and remove stale socket files:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' systemctl stop fieldwork-pr-broker.service fieldwork-pr-broker.socket fieldwork-pr-approve.socket && sudo -p '[sudo] VPS Linux password for fieldwork: ' rm -f /run/fieldwork-pr-broker/*.sock && sudo -p '[sudo] VPS Linux password for fieldwork: ' systemctl start fieldwork-pr-broker.socket fieldwork-pr-approve.socket"
```

Expected approve socket:

```text
fieldwork-pr-broker:fieldwork-bot 660
```

## Stale Or Dangling Unix Socket Bind

A socket file can exist with correct permissions while connects still fail if the systemd socket/service state is stale. Treat correct `stat` output as necessary but not sufficient.

Use a live probe:

```sh
fieldwork verify-security
```

It attempts an approve-socket request as `fieldwork-bot` when sudo permits. If that fails, restart both socket units as shown in the previous section.

## Bot Service Active But Polling Broken

`systemctl is-active fieldwork-bot.service` is not enough. The bot can be active while Telegram polling is stale or failing.

Run:

```sh
fieldwork bot-status
```

It reads `/var/lib/fieldwork-bot/bot-health.json` and checks last poll time, last poll error, pending queue, token config, chat binding, and sockets.

Common fixes:

```sh
fieldwork setup-notify --telegram-bot
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' systemctl restart fieldwork-bot.service"
```

## Pending Approval Stuck

List pending requests:

```sh
fieldwork bot-status
```

If a pending file is stuck after an interrupted approval path, remove it as root:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' rm -f /var/lib/fieldwork-pr-broker/pending/<request_id>.json /var/lib/fieldwork-pr-broker/pending/<request_id>.json.notified"
```

The broker replay ledger remains. The same `request_id` cannot be reused.

## `fieldwork onboard` Reports An Unsupported Default Branch

Fieldwork records the GitHub default branch in `.fieldwork/default-branch` during
onboarding. Branch names must be normal Git branch names without `..`, `@{`, or
leading slashes. Rename unusual default branches before onboarding.

## Workspace Trust Or Remote-Control Consent Loop

Run the priming commands from onboarding:

```sh
ssh -t fieldwork-vps 'cd ~/projects/<slug> && ~/.local/bin/claude'
ssh -t fieldwork-vps 'cd ~/projects/<slug> && ~/.local/bin/claude remote-control'
ssh fieldwork-vps 'systemctl --user restart fieldwork-agent@<slug>'
```

Then:

```sh
fieldwork status <slug> --verbose
```

## Codex Desktop Shows SSH Host But No VPS Folder Or Mobile Session

Codex does not create a Claude-style `vps-<slug>` mobile session. The supported
path is Codex Desktop connecting to the VPS over SSH, then opening the remote
folder `/home/fieldwork/projects/<slug>`. In Codex Desktop `Connections -> SSH`,
enable `"Available from signed-in devices"` in Details before relying on mobile
access.

Run:

```sh
fieldwork doctor --remote <slug> --explain
```

Read the `Codex Desktop`, `Account access`, and `Codex runtime` sections:

- `Codex SSH host not selected` means Codex Desktop knows the VPS but the current
  selected host is something else. Select the configured VPS SSH connection
  (for example, `fieldwork-vps`; it may display as the server name), reopen the
  repo folder, and make sure the mobile header shows that remote repo before PR
  work.
- `Codex Desktop repo folder not opened` means Desktop knows the SSH host but
  has not recorded `/home/fieldwork/projects/<slug>`. Open that folder in Codex
  Desktop first.
- `remote Codex CLI ... older than ...` means the VPS Codex binary is stale.
  Run the upgrade command doctor prints, then reconnect Codex Desktop.
- `Codex login not authenticated` means Codex itself reports the VPS user is
  logged out. Rerun the device-code login command doctor prints.
- `Codex app-server stale socket seen` or `Codex app-server saw ended app
  session` is a sanitized signal from the app-server log. Reconnect Codex
  Desktop after refreshing login; Fieldwork does not print raw Codex logs or
  restart Codex services automatically.

Direct VPS `codex remote-control` is future experimental scope. Use Codex
Desktop's SSH connection to the VPS remote project; the mobile-visible host name
may be your SSH alias or server name.

## Codex Verify Socket Permission Denied

Symptoms:

- `fieldwork-verify: runner socket connect failed (...fieldwork-verify.sock): [Errno 1] Operation not permitted`.
- The socket exists and `fieldwork doctor --remote <slug> --explain` may pass
  from a fresh probe.

Repair:

Select the configured VPS SSH connection in Codex Desktop, reopen
`/home/fieldwork/projects/<slug>`, and start or retry the mobile thread from
that remote repo. The mobile header should show the repo on the VPS connection
(whether it displays the SSH alias or server name), not the local Mac/Windows
host. Then rerun:

```sh
fieldwork doctor --remote <slug> --explain
```

If doctor reports `Codex Unix-socket allowlist missing` or
`Codex sandbox cannot reach Fieldwork sockets`, rerun `fieldwork setup --agent
codex` and reconnect Codex Desktop.

## Verify Runner Socket Missing

Symptoms:

- `fieldwork-verify` says runner socket not available.
- `/verify-before-pr` cannot start.

Repair:

```sh
ssh fieldwork-vps 'systemctl --user daemon-reload'
ssh fieldwork-vps 'systemctl --user enable --now fieldwork-verify-runner.socket'
ssh fieldwork-vps 'systemctl --user status fieldwork-verify-runner.socket --no-pager'
```

If the unit files are missing:

```sh
fieldwork sync-vps --force-install
ssh -t fieldwork-vps 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'
```

## PR-Prepare Runner Socket Missing

Symptoms:

- `fieldwork-pr-prepare` says runner socket not available.
- `/pr-delivery` stops before commit creation.

Repair:

```sh
ssh fieldwork-vps 'systemctl --user daemon-reload'
ssh fieldwork-vps 'systemctl --user enable --now fieldwork-pr-prepare-runner.socket'
ssh fieldwork-vps 'systemctl --user status fieldwork-pr-prepare-runner.socket --no-pager'
```

## PR-Prepare Request Path Rejected

Symptoms:

- `fieldwork-pr-prepare` says the request must live under
  `<repo>/.fieldwork/local/`.
- Codex tries to mirror request JSON into `.claude/local`.

Repair:

Write and pass the documented request path only:

```sh
/home/fieldwork/.local/bin/fieldwork-pr-prepare .fieldwork/local/pr-prepare-request.json
```

Do not create a `.claude/local` mirror. Fieldwork-owned delivery state lives
under `.fieldwork/local`, and `fieldwork-pr-submit` uses the same directory for
`.fieldwork/local/pr-request.json`.

## AppArmor, userns, Or bwrap Failures

Symptoms:

- `fieldwork-verify` exits `20`.
- Output mentions `inner-sandbox unavailable`.
- bwrap reports permission denied or uid map failure.

Check:

```sh
ssh fieldwork-vps 'cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || true'
ssh fieldwork-vps 'cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || true'
```

Install Fieldwork's narrow bwrap AppArmor profile:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' install -m 644 ~/fieldwork/lib/apparmor/fieldwork-bwrap /etc/apparmor.d/fieldwork-bwrap && sudo -p '[sudo] VPS Linux password for fieldwork: ' apparmor_parser -r /etc/apparmor.d/fieldwork-bwrap"
```

Do not disable AppArmor's userns restriction globally unless you accept the host-wide risk.

## Verify Reports Dependencies Missing

`fieldwork-verify` does not install dependencies inside an agent session. Install deps as maintenance outside the delivery flow:

```sh
ssh -t fieldwork-vps 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'
ssh fieldwork-vps 'cd ~/projects/<slug> && npm ci'
fieldwork doctor --remote <slug> --explain
```

Use the equivalent manual dependency command for the repo stack. Missing host toolchains are reported separately: Node/npm, Go, Rust/cargo, and Python are checked as stack-specific verify readiness.

## Broker Rejects `worktree not clean`

The broker only accepts clean worktrees. In normal `/pr-delivery`, the prepare runner should leave the tree clean before submit. If this error appears, inspect the checkout:

```sh
ssh fieldwork-vps 'cd ~/projects/<slug> && git status --short'
```

Likely causes:

- prepare step was skipped
- extra dirty file was created after prepare
- manual edits happened in the checkout
- old repo skill submitted directly without prepare

Refresh repo skills if needed:

```sh
fieldwork onboard <project> --reseed-templates
```

## GitHub Rejects Workflow Updates

Fine-grained PATs need Workflows read/write to push `.github/workflows/**`.

For onboarding without workflow permission:

```sh
fieldwork onboard <owner>/<repo> --no-workflows
```

If the init branch already exists, inspect or reset it before rerunning onboarding.

## GitHub Actions Billing Locked

If GitHub says workflows cannot run because billing is locked, the broker path worked. GitHub is refusing to start Actions for account or org billing reasons.

Fix billing in GitHub, then rerun failed workflows or push a follow-up commit.

## ntfy Does Not Send Pushes

Run:

```sh
fieldwork setup-notify
fieldwork setup-notify --remote
```

Check remote config presence without printing the topic:

```sh
ssh fieldwork-vps 'test -s ~/.fieldwork/notify.env && echo ok'
```

Do not paste ntfy topics into public logs.

## GitHub CLI Logged Out On VPS

Run:

```sh
ssh -t fieldwork-vps 'gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key'
```

This is for onboarding preflights. It preselects browser/device login and skips
SSH-key upload. It is not the broker token.

## `fieldwork smoke` Fails

Smoke does not use Claude. Debug broker and repo state first:

```sh
fieldwork doctor --remote --explain
fieldwork verify-security <repo-slug>
ssh fieldwork-vps 'cd ~/projects/<slug> && git status --short'
```

## `verify-security` Reports Token Or Ledger Permission Issues

Repair broker install and rotate token:

```sh
fieldwork sync-vps --force-install
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh"
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' env FIELDWORK_ROTATE_PAT_TTY=1 /usr/local/sbin/rotate-pat"
```

Some sensitive checks intentionally use non-interactive sudo so `verify-security` will not hang. If it prints a manual row, run the exact command it shows.

## Temporary Passwordless Sudo Still Present

If setup created the `fieldwork` user over root SSH, it may have created a temporary sudoers file for early setup. Remove it after broker setup works:

```sh
fieldwork setup
```

Or:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' rm -f /etc/sudoers.d/fieldwork-fieldwork"
```

Then:

```sh
fieldwork verify-security
```

## Onboarding Stopped Halfway

Rerun the same command:

```sh
fieldwork onboard <project>
```

Inspect checkpoint:

```sh
fieldwork onboard <project> --status
```

If checkpoint state is corrupt:

```sh
fieldwork onboard <project> --reset-state
```

This does not delete the checkout, branch, commits, PR, deploy key, broker token, or systemd unit.

## Static Checks Or CI Fail

Run locally:

```sh
tests/static-checks.sh
```

Common patterns:

- README must keep a broker-standalone pointer.
- `fieldwork --help` output must include current commands.
- Broker socket-group defaults must remain userns-safe.
- Runner units must keep `SocketMode=0600` and must not set `NoNewPrivileges=true`.
- JSON schemas must parse.
- Python scripts must compile.

For docs-only PRs, also verify links:

```sh
rg -n "\]\(([^)#]+\.md)" README.md docs
```
