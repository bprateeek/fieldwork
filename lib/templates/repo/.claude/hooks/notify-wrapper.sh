#!/usr/bin/env bash
# Wired to Stop, Notification, StopFailure events.
#
# Committed to repos. No-ops in cloud / CI / Action runs (journal + notify are
# local-only) and when the local notify.sh isn't installed (so the same hook
# config is safe in repos that opt out of W-Notify).

set -euo pipefail

# Skip in cloud / Action / CI. FIELDWORK_SKIP_LOCAL_HOOKS is the agent-neutral
# signal an agent adapter can set; CLAUDE_CODE_REMOTE is the Claude Code
# adapter's own equivalent and is kept as a fallback.
[ -n "${CI:-}${GITHUB_ACTIONS:-}${FIELDWORK_SKIP_LOCAL_HOOKS:-}${CLAUDE_CODE_REMOTE:-}" ] && exit 0

# No-op if local script not installed.
[ -x "$HOME/.fieldwork/scripts/notify.sh" ] || exit 0

event="${1:-stop}"
exec "$HOME/.fieldwork/scripts/notify.sh" "$event"
