# Notifications

Notifications and the Telegram approval bot are optional integrations. `fieldwork setup` installs the core mobile-to-PR path without them, and you can configure either one at any time afterward.

## Mobile notifications (ntfy)

Mobile notifications send a push when a Claude session needs input, finishes, or fails. They are a status convenience, not a safety control.

Codex preview note: Claude hooks do not run under Codex, so Fieldwork still cannot send Codex in-session "needs input" or "turn done" notifications. The VPS event poller does provide agent-agnostic git-state journaling, resume-context artifacts, PR merge checks, and optional notification drops based on observable broker audit + git state.

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

When the Telegram approval bot is installed, `notify.sh` writes a JSON drop file under `/var/lib/fieldwork-pr-broker/notifications` instead of sending directly. New drops use this versioned envelope:

```json
{
  "schema": 1,
  "kind": "agent_lifecycle",
  "source": "claude_hook",
  "event": "stop",
  "repo_slug": "example",
  "request_id": null,
  "branch": "fieldwork/example",
  "dedupe_key": "agent_lifecycle:example:fieldwork/example:stop:<drop-id>",
  "text": "human-readable notification text"
}
```

The bot still accepts legacy `{"text":"..."}` drops. If a versioned drop has a `dedupe_key`, the bot records it in a small TTL store under `/var/lib/fieldwork-bot` after successful delivery so a restart before file deletion does not resend the same notification.

Broker lifecycle drops use the same envelope with `kind: "broker_lifecycle"` and `source: "broker"`. They are controlled by `FIELDWORK_BROKER_NOTIFY_LIFECYCLE`; the default is off. Values `1`, `true`, `yes`, `on`, or `minimal` enable `request_queued` and `pr_opened`; `all` also enables `request_approved` and `request_denied`; a comma-separated event list enables only those events. The older `FIELDWORK_BROKER_NOTIFY_ON_PR_OPENED=1` remains a compatibility alias for `pr_opened`.

## Event Poller And Loop State

`fieldwork-event-poll.timer` runs as a systemd user timer about every 30 seconds. It scans canonical repos under `$HOME/projects`, asks each repo for `git worktree list --porcelain`, and records all linked worktrees, including Claude `--spawn=worktree` checkouts under `$HOME/worktrees`. It does not hold broker tokens, read pending approval requests, call the approve socket, or write broker state.

The poller uses this local state contract:

```text
~/.fieldwork/state/
  events/<repo-slug>.json
  resume-context/<repo-slug>.md
```

Journals remain at:

```text
~/.fieldwork/project-journals/<repo-slug>.md
```

The poller appends journal entries from git state only: branch plus latest commit subject. Claude transcript scraping is no longer part of durable journaling.

`events/<repo-slug>.json` is schema-versioned. The initial shape is:

```json
{
  "schema_version": 1,
  "repo_slug": "example",
  "worktrees": {
    "/home/fieldwork/worktrees/example-fieldwork-change": {
      "branch": "fieldwork/change",
      "rev": "abc123",
      "base_branch": "main",
      "ahead_of_base": 2,
      "staged_count": 0,
      "dirty_count": 1,
      "untracked_count": 0,
      "latest_commit_subject": "add feature",
      "last_seen": "2026-06-23T12:00:00Z"
    }
  },
  "prs": {
    "fieldwork/change": {
      "number": 12,
      "url": "https://github.com/owner/example/pull/12",
      "base_branch": "main",
      "repo": "owner/example",
      "last_checked": "2026-06-23T12:00:00Z"
    }
  },
  "open_prs": {
    "last_checked": "2026-06-23T12:00:00Z",
    "lines": ["#12 Add feature [fieldwork/change]"]
  },
  "last_throttled_checks": {
    "fieldwork/change:pr_state": "2026-06-23T12:00:00Z"
  }
}
```

Base branch resolution is `.fieldwork/default-branch`, then broker audit `base_branch`, then `origin/HEAD`. When audit entries contain `pr_opened`, the poller stores the PR number by branch and checks merge state by PR number, not by branch head, so branch deletion after merge does not hide the merge.

## Dashboard Snapshot

`fieldwork dashboard` uses the same durable state files as the event poller. The VPS service runs `fieldwork-status-snapshot` locally and serves the result through a loopback-only HTTP server reached by an SSH tunnel from your workstation.

The snapshot is read-only. It includes repo event files, resume-context presence, recent journal lines, PR/worktree state, and the latest broker audit event per repo when the agent user's audit-read ACL can read the audit JSONL log. It does not read Telegram bot secrets, broker PAT files, pending approval request bodies, or notification transport secrets.

## Telegram approval bot

The Telegram approval bot is one optional transport for the per-repo approval gate. PR approval also works directly through the broker's approve socket without Telegram.

Install the bot once per VPS:

```sh
fieldwork setup-notify --telegram-bot
```

You need a Telegram bot token from BotFather and at least one allowlisted chat ID. The bot runs as the `fieldwork-bot` user, holds the Telegram token and HMAC secret, and can only reach the broker approve socket. It never holds the forge write token.

Enable the gate per repo at onboarding time:

```sh
fieldwork onboard <project> --with-approval-gate
```

For the full approval flow, trust model, HMAC callbacks, health checks, and recovery, see [approval-gate.md](approval-gate.md).

## Uninstall

`fieldwork uninstall` discovers and removes both integrations if present: the local and remote `notify.env` files (when marked as Fieldwork-managed) and the `fieldwork-bot` service, binary, config, and state directories. See [uninstall.md](uninstall.md).
