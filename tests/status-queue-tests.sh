#!/usr/bin/env bash
# Unit tests for the Mobile -> PR queue + last-PR rendering (lib/cli/health.sh).
# Sources the lib directly, never the bin/fieldwork entrypoint.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NO_COLOR=1
# shellcheck source=lib/cli/messaging.sh
source "$ROOT/lib/cli/messaging.sh"
# shellcheck source=lib/cli/health.sh
source "$ROOT/lib/cli/health.sh"

fail=0
contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf '  ok   %s\n' "$name" ;;
    *) printf '  FAIL %s: output missing [%s]\n' "$name" "$needle" >&2; fail=1 ;;
  esac
}
absent() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf '  FAIL %s: output unexpectedly has [%s]\n' "$name" "$needle" >&2; fail=1 ;;
    *) printf '  ok   %s\n' "$name" ;;
  esac
}
check() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then printf '  ok   %s\n' "$name"
  else printf '  FAIL %s: got [%s] want [%s]\n' "$name" "$got" "$want" >&2; fail=1; fi
}

BOT=$'SERVICE_STATE=active\nDIR_PENDING_COUNT=2\nDIR_OLDEST_PENDING_AGE_SECONDS=4000\nDIR_PENDING_SOURCE=direct\nDIR_PENDING_ITEM=owner/app\tfieldwork/x\t4000\treq1\tapp\nDIR_PENDING_ITEM=owner/web\tfieldwork/y\t120\treq2\tweb'

# --- queue, no filter ---------------------------------------------------------
out="$(queue_render "$BOT")"
contains "queue count+oldest" "$out" "pending: 2 (oldest 1h)"
contains "queue item app"     "$out" "owner/app · fieldwork/x · 1h"
contains "queue item web"     "$out" "owner/web · fieldwork/y · 2m"

# --- queue, slug filter -------------------------------------------------------
out="$(queue_render "$BOT" app)"
contains "filter header"  "$out" "pending for app: 1"
contains "filter shows app" "$out" "owner/app"
absent   "filter hides web" "$out" "owner/web"

# --- unmatched (item without slug) --------------------------------------------
BOT_UM=$'DIR_PENDING_COUNT=2\nDIR_PENDING_SOURCE=direct\nDIR_PENDING_ITEM=o/app\tb\t10\tr\tapp\nDIR_PENDING_ITEM=o/legacy\tz\t20\tr2\t'
out="$(queue_render "$BOT_UM" app)"
contains "unmatched note" "$out" "had no slug and were not matched"

# --- zero pending -------------------------------------------------------------
out="$(queue_render $'DIR_PENDING_COUNT=0\nDIR_PENDING_SOURCE=direct')"
contains "zero pending" "$out" "pending: 0"

# --- bot/queue unavailable (sudo) ---------------------------------------------
out="$(queue_render $'DIR_PENDING_SOURCE=unavailable')"
contains "unavailable note" "$out" "needs broker sudo"

# --- missing count entirely ---------------------------------------------------
out="$(queue_render $'SERVICE_STATE=inactive')"
contains "unknown count" "$out" "pending: unknown"

# --- pr_audit_parse / pr_audit_row: latest event by ts wins -------------------
audit="$(printf '%s\n' \
  '{"ts":"2026-06-01T10:00:00Z","event":"request_queued","repo_path_slug":"app","branch":"fieldwork/x"}' \
  '{"ts":"2026-06-01T11:00:00Z","event":"pr_opened","repo_path_slug":"app","pr_url":"https://gh/pr/9","branch":"fieldwork/x"}' \
  '{"ts":"2026-06-01T09:00:00Z","event":"pr_opened","repo_path_slug":"other","pr_url":"https://gh/pr/1"}')"
contains "audit label opened" "$(printf '%s' "$audit" | pr_audit_row app)" "opened: https://gh/pr/9"

# request_queued newer than pr_opened -> queued wins, and an empty pr_url in a
# later (queued) record must not shift the branch field.
audit2="$(printf '%s\n' \
  '{"ts":"2026-06-01T10:00:00Z","event":"pr_opened","repo_path_slug":"app","pr_url":"https://gh/pr/9"}' \
  '{"ts":"2026-06-01T12:00:00Z","event":"request_queued","repo_path_slug":"app","branch":"fieldwork/z"}')"
contains "label queued (empty url preserved)" "$(printf '%s' "$audit2" | pr_audit_row app)" "queued, awaiting approval (fieldwork/z)"

# no matching slug -> "no recent PR activity"
contains "label no activity (no match)" "$(printf '%s' '{"ts":"x","event":"pr_opened","repo_path_slug":"zzz"}' | pr_audit_row app)" "no recent PR activity"
contains "label no activity (empty input)" "$(printf '' | pr_audit_row app)" "no recent PR activity"

# --- event label coverage -----------------------------------------------------
contains "label rejected" "$(pr_event_label request_rejected '' 'b')" "rejected (b)"
contains "label denied"   "$(pr_event_label request_denied '' '')"   "denied"
contains "label expired"  "$(pr_event_label request_expired '' '')"  "expired"

exit "$fail"
