# Notifications

Notifications and the Telegram approval bot are optional integrations. `fieldwork setup` installs the core mobile-to-PR path without them, and you can configure either one at any time afterward.

## Mobile notifications (ntfy)

Mobile notifications send a push when a Claude session needs input, finishes, or fails. They are a status convenience, not a safety control.

Codex preview note: Claude hooks do not run under Codex, so Fieldwork does not send Codex session lifecycle notifications in this milestone. Broker and Telegram approval notifications still work because they are emitted by the broker/bot path, not by agent hooks.

Configure them with:

```sh
fieldwork setup-notify
fieldwork setup-notify --remote
```

`setup-notify` creates or reuses `~/.fieldwork/notify.env`, copies it to the VPS, and sends test pushes. `--remote` copies an existing local config to the VPS.

`~/.fieldwork/notify.env` holds either an ntfy topic or a Telegram destination:

```text
NTFY_TOPIC=fieldwork-<random>
```

Anyone who knows the ntfy topic can read that topic, so keep it private and out of logs and screenshots. See [../examples/notify.env.example](../examples/notify.env.example) for the full format, including the alternate `TG_BOT_TOKEN` / `TG_CHAT` direct-Telegram option.

The file is read at runtime by `~/.fieldwork/scripts/notify.sh`, which is invoked from the onboarded repo's `Stop`, `Notification`, and `StopFailure` Claude hooks. It is denied to Claude in the sandbox and is not placed in any systemd `EnvironmentFile`, so its contents never reach the agent's environment.

## Telegram approval bot

The Telegram approval bot is one optional transport for the per-repo approval gate. PR approval also works directly through the broker's approve socket without Telegram.

Install the bot once per VPS:

```sh
fieldwork setup-notify --telegram-bot
```

You need a Telegram bot token from BotFather and at least one allowlisted chat ID. The bot runs as the `fieldwork-bot` user, holds the Telegram token and HMAC secret, and can only reach the broker approve socket. It never holds the GitHub PAT.

Enable the gate per repo at onboarding time:

```sh
fieldwork onboard <owner>/<repo> --with-approval-gate
```

For the full approval flow, trust model, HMAC callbacks, health checks, and recovery, see [approval-gate.md](approval-gate.md).

## Uninstall

`fieldwork uninstall` discovers and removes both integrations if present: the local and remote `notify.env` files (when marked as Fieldwork-managed) and the `fieldwork-bot` service, binary, config, and state directories. See [uninstall.md](uninstall.md).
