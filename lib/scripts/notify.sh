#!/usr/bin/env bash
# Local-only notifier, invoked by .claude/hooks/notify-wrapper.sh on Stop /
# Notification / StopFailure. The script is generic; only ~/.fieldwork/notify.env
# carries the private topic/token.
#
# Loads creds at exec time. They reach `curl` (a child of this script) but
# DO NOT reach Claude. Env vars don't propagate upward and the systemd unit
# does not set EnvironmentFile.

set -euo pipefail

event="${1:-stop}"

# No notify.env: silently no-op. Fieldwork fills it with NTFY_TOPIC=<private-topic>.
[ -f "$HOME/.fieldwork/notify.env" ] || exit 0

set -a; . "$HOME/.fieldwork/notify.env"; set +a

# Stop/Notification/StopFailure pass the hook payload on stdin. Read it but
# don't put it in the message. Payloads can contain user content we don't
# want sent to the mobile notification channel.
payload="$(cat 2>/dev/null || true)"

repo="${CLAUDE_PROJECT_DIR:-$PWD}"
project="$(basename "$repo")"
branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"

case "$event" in
  stop)    icon="✓" ;;
  notify)  icon="❓" ;;
  failure) icon="✗" ;;
  *)       icon="•" ;;
esac

msg="$icon $project @ $branch [$event]"

# Stop fires when the agent ends a turn cleanly. `[stop]` alone leaves the user
# guessing whether work shipped. Enrich with staged-set size, worktree
# cleanliness, and whether a broker request file is sitting in .fieldwork/local.
#
# Every step must tolerate failure (missing journal, non-git $repo, etc.); a
# silent abort here would lose the entire notification because of `set -e`.
if [ "$event" = "stop" ]; then
  staged="$( (git -C "$repo" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ') 2>/dev/null || echo 0 )"
  dirty="$(  (git -C "$repo" status --porcelain        2>/dev/null | wc -l | tr -d ' ') 2>/dev/null || echo 0 )"
  if [ -f "$repo/.fieldwork/local/pr-request.json" ]; then pr_request=yes; else pr_request=no; fi
  msg="$msg | staged=$staged dirty=$dirty pr_request=$pr_request"
  journal_path="$HOME/.fieldwork/project-journals/$project.md"
  if [ -f "$journal_path" ]; then
    last_journal="$( (tail -n1 "$journal_path" 2>/dev/null | tr '\r\n' '  ' | cut -c1-80) 2>/dev/null || true )"
    [ -n "${last_journal:-}" ] && msg="$msg | $last_journal"
  fi
fi

bot_drop="${FIELDWORK_NOTIFICATIONS_DIR:-/var/lib/fieldwork-pr-broker/notifications}"

# When the bot daemon is configured, hand the message off via a JSON drop-off
# in the bot's notifications dir; the bot user holds the Telegram token, the
# agent user never reads it. This consolidates outbound Telegram traffic
# through the bot and removes TG_BOT_TOKEN from the agent's environment.
if [ -f /etc/fieldwork-bot/config.toml ] && [ -d "$bot_drop" ] && [ -w "$bot_drop" ]; then
  uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)"
  tmp="$bot_drop/.tmp-$uuid"
  out="$bot_drop/$uuid.json"
  if FW_NOTIFY_TEXT="$msg" \
    FW_NOTIFY_EVENT="$event" \
    FW_NOTIFY_REPO_SLUG="$project" \
    FW_NOTIFY_BRANCH="$branch" \
    FW_NOTIFY_PROFILE="${FIELDWORK_PROFILE:-default}" \
    FW_NOTIFY_UUID="$uuid" \
    python3 - "$tmp" <<'PY'
import json
import os
import sys

out = sys.argv[1]
event = os.environ.get("FW_NOTIFY_EVENT") or "unknown"
repo_slug = os.environ.get("FW_NOTIFY_REPO_SLUG") or "unknown"
branch = os.environ.get("FW_NOTIFY_BRANCH") or "-"
profile = os.environ.get("FW_NOTIFY_PROFILE") or "default"
uid = os.environ.get("FW_NOTIFY_UUID") or "unknown"
payload = {
    "schema": 1,
    "kind": "agent_lifecycle",
    "source": "claude_hook",
    "event": event,
    "repo_slug": repo_slug,
    "request_id": None,
    "branch": branch,
    "profile": profile,
    "dedupe_key": f"agent_lifecycle:{repo_slug}:{branch}:{event}:{uid}",
    "text": os.environ.get("FW_NOTIFY_TEXT") or "",
}
with open(out, "w") as f:
    json.dump(payload, f, sort_keys=True)
    f.write("\n")
PY
  then
    chmod 660 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  exit 0
fi

if [ -n "${NTFY_TOPIC:-}" ]; then
  curl -fsS -m 5 -d "$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
elif [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ]; then
  curl -fsS -m 5 -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT" \
    --data-urlencode "text=$msg" >/dev/null || true
fi
