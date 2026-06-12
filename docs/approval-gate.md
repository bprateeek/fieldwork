# Approval Gate

The approval gate makes every PR request from an opted-in repo wait for a human tap before the broker pushes a branch or opens a PR.

It extends Fieldwork's token split:

```text
tokenless agent
  -> broker with GitHub PAT
  -> tokenless Telegram approver
  -> GitHub PR
```

The approver does not hold GitHub credentials. It can only tell the broker to approve or deny a pending request.

## Quick Flow

```text
Claude prepares PR request
  -> fieldwork-pr-submit posts /pr to broker submit socket
  -> broker validates request
  -> broker sees .fieldwork/approval-gate
  -> broker writes pending/<request_id>.json
  -> fieldwork-bot sends Telegram Approve/Deny buttons
  -> human taps a button
  -> bot posts /approve to broker approve socket
  -> broker revalidates repo state
  -> approve: push branch and open PR
  -> deny: delete pending request
```

Requests expire after 24 hours by default.

## Opt In

A repo opts in by committing:

```text
.fieldwork/approval-gate
```

The file can be empty. Presence is the v1 policy signal.

At onboarding time:

```sh
fieldwork onboard <owner>/<repo> --with-approval-gate
```

For an already onboarded repo, add and commit the marker. The broker checks it on each request, so no broker restart is needed.

## Bot Setup

Install the bot once per VPS:

```sh
fieldwork setup-notify --telegram-bot
```

You need:

- a Telegram bot token from BotFather
- one or more Telegram chat IDs allowed to approve

The setup writes:

```text
/etc/fieldwork-bot/config.toml    bot token and allowed chat IDs
/etc/fieldwork-bot/secret         HMAC secret, owned by fieldwork-bot, mode 400
```

The bot service is:

```text
fieldwork-bot.service
```

It long-polls Telegram. It does not open an inbound public port.

## Trust Model

| Identity | Holds GitHub PAT | Holds Telegram token | Can submit `/pr` | Can call `/approve` |
|---|---:|---:|---:|---:|
| `fieldwork` agent user | no | no | yes | no |
| `fieldwork-pr-broker` broker user | yes | no | broker owns socket | broker owns socket |
| `fieldwork-bot` bot user | no | yes | no | yes |

Installed sockets:

```text
/run/fieldwork-pr-broker/fieldwork-pr.sock
  submit socket
  writable by broker user and the agent user's primary group

/run/fieldwork-pr-broker/fieldwork-pr-approve.sock
  approve socket
  writable by broker user and fieldwork-bot group
```

The checked-in submit socket template uses `fieldwork-pr`, but the broker installer rewrites it to the agent user's primary group by default. That keeps it reachable from inside Claude's sandbox user namespace.

The bot user must not be in the submit socket group. The agent user must not be in the bot group.

## Broker Behavior

For a gated repo, the broker still validates the full `/pr` request before queueing it. It reserves the `request_id` in the replay ledger, then writes:

```text
/var/lib/fieldwork-pr-broker/pending/<request_id>.json
```

The pending file contains the repo, branch, title, body, request ID, and expiry. It is group-readable by `fieldwork-bot`.

On approval, the broker reloads the pending record and revalidates drift-sensitive state:

- repo still exists
- origin still matches `.fieldwork/expected-origin`
- worktree is still clean
- request has not expired

Then it uses the same push and PR creation path as a non-gated request.

On denial, the broker deletes the pending file and sidecar notification file.

## HMAC Callback Buttons

Telegram callback data is signed:

```text
callback_data = "<a|d>:<request_id>:<sig16>"
sig16 = first 16 hex chars of HMAC-SHA256(secret, "<approve|deny>:<request_id>")
```

The 64-bit truncated signature keeps callback data under Telegram's size limit. The callback is one-shot because the pending file disappears after approve, deny, or expiry.

Callbacks from non-allowlisted chats are logged and silently ignored.

## Day-To-Day Use

When Claude submits a PR request for a gated repo, `fieldwork-pr-submit` prints:

```text
queued for human approval; expires at <UTC timestamp>
```

Telegram shows:

- repo
- branch
- PR title
- expiry
- request ID
- Approve and Deny buttons

After approval, the bot edits the original message to include the PR URL. After denial, it edits the message to show the denial. The agent has already exited successfully after queueing; there is no callback into the agent session.

## Health And Status

Run:

```sh
fieldwork bot-status
fieldwork verify-security
```

`bot-status` checks service state, Telegram polling freshness, pending queue, submit socket, approve socket, token config, and chat binding.

`verify-security` additionally checks user separation, PAT readability, HMAC secret mode, and approve socket live connectivity as the bot user when sudo permits.

## Recovery

Bot service active but polling stale:

```sh
fieldwork bot-status
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' systemctl restart fieldwork-bot.service"
```

Approve socket stale or unreachable:

```sh
ssh -t fieldwork-vps "sudo -p '[sudo] VPS Linux password for fieldwork: ' systemctl stop fieldwork-pr-broker.service fieldwork-pr-broker.socket fieldwork-pr-approve.socket && sudo -p '[sudo] VPS Linux password for fieldwork: ' rm -f /run/fieldwork-pr-broker/*.sock && sudo -p '[sudo] VPS Linux password for fieldwork: ' systemctl start fieldwork-pr-broker.socket fieldwork-pr-approve.socket"
```

Pending request stuck after an interrupted approve path:

```sh
sudo rm /var/lib/fieldwork-pr-broker/pending/<request_id>.json
sudo rm -f /var/lib/fieldwork-pr-broker/pending/<request_id>.json.notified
```

The replay ledger remains, so that `request_id` cannot be reused.

Rotate HMAC secret:

```sh
openssl rand -hex 32 | sudo install -o fieldwork-bot -g fieldwork-bot -m 400 /dev/stdin /etc/fieldwork-bot/secret
sudo systemctl restart fieldwork-bot.service
```

Pending requests that were notified with the old secret are re-notified on restart with fresh signatures.

## Limits

The approval gate is:

- not full Telegram control of the agent
- not multi-approver or quorum-based
- not a defense against compromised VPS root
- not a replacement for GitHub review and merge discipline

It is the human control point before a prepared PR request becomes a broker-owned GitHub push.
