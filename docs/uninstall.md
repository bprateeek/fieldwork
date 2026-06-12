# Uninstall And Reset

Use the guided uninstall command for normal teardown:

```sh
fieldwork uninstall
```

It prints a plan first, then asks for confirmation. The default scope removes
Fieldwork-managed local files, remote user services/scripts, the PR broker, and
the approval bot when they are discovered.

It does **not** remove repositories, GitHub pull requests, SSH keys, non-Fieldwork
SSH config, the VPS user account, Docker, GitHub CLI, Claude Code, or
user-authored Claude config. It ends with a manual checklist for account-level
and provider-level cleanup that Fieldwork cannot safely automate.

## Preview First

```sh
fieldwork uninstall --dry-run
```

Dry run prints what would be removed and what would be kept without changing
local or remote state.

## Common Scopes

```sh
fieldwork uninstall --local
```

Removes only local Fieldwork-owned CLI, config, `.fieldwork`, and marked Claude discovery symlinks/files.

```sh
fieldwork uninstall --remote
```

Removes only remote user-level Fieldwork services, scripts, and synced checkout.
It stops `fieldwork-agent@*.service` sessions and the verify/PR-prepare runner
sockets, but keeps repo checkouts and worktrees.

```sh
fieldwork uninstall --broker
```

Removes only the remote broker/system services and broker-owned config/state.
This uses sudo on the VPS.

```sh
fieldwork uninstall --bot
```

Removes only the Telegram approval-bot service, binary, config, state, and
guarded temporary setup files when discovered. This uses sudo on the VPS.

```sh
fieldwork uninstall --no-broker
```

Runs the default uninstall but skips broker/system cleanup.

```sh
fieldwork uninstall --yes
```

Runs the same safe uninstall without confirmation prompts. Unmarked
`~/.fieldwork/notify.env` files are still kept.

```sh
fieldwork uninstall --quiet
```

Suppresses successful and skipped removal rows. Failures and the final manual
checklist still print.

## Purge

```sh
fieldwork uninstall --purge
```

Adds Fieldwork cache/log/state cleanup. It still keeps repositories, SSH
material, third-party tools, and system users/groups.

To remove Fieldwork-created broker/bot users and groups too:

```sh
fieldwork uninstall --purge --remove-system-users
```

Interactive runs require typing:

```text
remove fieldwork users
```

This extra gate exists because deleting system users can affect file ownership,
logs, audit trails, and standalone broker installs.

## Notification Config

Fieldwork now marks generated notification files:

```text
# Managed by Fieldwork
```

Uninstall removes marked `~/.fieldwork/notify.env` files by default. If the file is
not marked, interactive uninstall asks before removing it. `--yes` keeps
unmarked notification config.

## Manual Checklist

The final checklist always prints. It includes exact follow-up URLs or commands
for the things uninstall cannot own directly:

- GitHub broker PAT revocation:
  `https://github.com/settings/personal-access-tokens`
- Telegram bot deletion:
  open `https://t.me/BotFather` and send `/deletebot`
- Recorded VPS `authorized_keys` fingerprint and, when available, a command to
  remove the recorded public key
- Any remaining `Host fieldwork-vps` block in `~/.ssh/config`
- UFW public SSH rule inspection/removal:
  `ssh -t fieldwork-vps 'sudo ufw status numbered'` and
  `ssh -t fieldwork-vps 'sudo ufw delete allow 22/tcp'`
- Provider firewall/security-group cleanup outside the VPS
- Optional VPS Linux user removal:
  `sudo userdel -r fieldwork`

Fieldwork bootstrap disables root SSH. If you remove the `fieldwork` user on a
reused VPS, future setup on that same VPS needs root SSH, another sudo-capable
account, or provider console/rescue mode to recreate it. Uninstall does not
restore root SSH or root authorized keys.

After uninstall, unsubscribe from any ntfy topic in your mobile app. If you used
a private notification provider with account-level tokens, revoke or rotate those
tokens in that provider.

## Ownership Rules

For files under `~/.claude`, uninstall removes only Fieldwork-owned symlinks or
marked files. Real user-authored `~/.claude/CLAUDE.md` and
`~/.claude/settings.json` are kept. Fieldwork-owned scripts, templates, state,
markers, and project journals live under `~/.fieldwork` and are removed only
when they match Fieldwork-owned paths.

For broker/system paths such as `/etc/fieldwork-pr-broker`, the Fieldwork-specific
path is the ownership boundary.

## One Repo Only

`fieldwork uninstall` is for removing Fieldwork itself. To detach one repository,
stop its remote session and remove its GitHub deploy key manually:

```sh
ssh fieldwork-vps 'systemctl --user disable --now fieldwork-agent@<slug>'
```

Keep or remove the VPS checkout under `~/projects/<slug>` yourself after copying
any work you still need.

If the broker PAT is scoped only to selected repositories, remove that repo from
the token's repository access in GitHub.
