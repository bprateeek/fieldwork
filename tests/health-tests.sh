#!/usr/bin/env bash
# Unit tests for `fieldwork health` rendering (lib/cli/health.sh) plus guards
# that the probe key set and fingerprint lists stay in sync across their copies.
# Sources the libs directly, never the bin/fieldwork entrypoint (it dispatches
# at load and self-execs through /dev/fd/3, so it is not sourceable).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NO_COLOR=1
# shellcheck source=lib/cli/messaging.sh
source "$ROOT/lib/cli/messaging.sh"
# shellcheck source=lib/cli/health.sh
source "$ROOT/lib/cli/health.sh"

fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then printf '  ok   %s\n' "$name"
  else printf '  FAIL %s: got [%s] want [%s]\n' "$name" "$got" "$want" >&2; fail=1; fi
}
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
# render RESULT REASON SNAP BOT LOCAL -> sets $OUT and $RC
render() {
  RC=0
  OUT="$(health_render "$1" "$2" "$3" "$4" "$5")" || RC=$?
}

LOCAL_OK=$'tools=ok\ncmd=ok\nhelpers=ok'

# --- _health_kv ---------------------------------------------------------------
check "kv basic"        "$(_health_kv gh_live $'a=1\ngh_live=ok\nb=2')" "ok"
check "kv missing key"  "$(_health_kv nope $'a=1')" ""
check "kv value with =" "$(_health_kv url $'url=http://x?y=z')" "http://x?y=z"

# --- _health_has_agent --------------------------------------------------------
_health_has_agent "claude,codex" codex && check "has_agent codex" 0 0 || check "has_agent codex" 1 0
_health_has_agent "claude" codex && check "has_agent absent" 1 0 || check "has_agent absent" 0 0

# --- all-ok (valid) -----------------------------------------------------------
SNAP_OK=$'fieldwork_checkout=ok\nbootstrap_ready=ok\ngh_cli=ok\ngh_live=ok\ngh_hosts=ok\nconfigured_agents=claude,codex\nconfigured_agents_status=ok\nclaude_cli=ok\nclaude_login=ok\nclaude_service=ok\ncodex_cli=ok\ncodex_login=ok\nverify_runner=ok\nprepare_runner=ok\nbroker_socket=ok\nbroker_pat_tool=ok\nbroker_pat_marker=ok\nbroker_pat_sudo_probe=ok'
BOT_OK=$'SERVICE_STATE=active\nBROKER_SUBMIT_STATUS=ok\nTOKEN_CONFIG_STATUS=ok\nDIR_PENDING_COUNT=0'
render valid "" "$SNAP_OK" "$BOT_OK" "$LOCAL_OK"
check    "all-ok rc"       "$RC" "0"
contains "all-ok verdict"  "$OUT" "All systems go."
contains "all-ok claude"   "$OUT" "Agent: claude"
contains "all-ok codex"    "$OUT" "Agent: codex"
absent   "all-ok no needs" "$OUT" "needs  "

# --- transport_failed: blocked, rc=3, NO bot reads -----------------------------
render transport_failed "" "" "" "$LOCAL_OK"
check    "transport rc"       "$RC" "3"
contains "transport blocked"  "$OUT" "blocked"
contains "transport hint"     "$OUT" "fieldwork doctor --remote"

# --- reached_untrusted: needs (NOT blocked), rc=0 ------------------------------
render reached_untrusted "partial" "" "" "$LOCAL_OK"
check    "untrusted rc0"   "$RC" "0"
contains "untrusted needs" "$OUT" "untrusted (partial)"
contains "untrusted hint"  "$OUT" "sync-vps"

# --- valid-but-stale + invalid agents + token unavailable + approvals optional -
SNAP_STALE=$'fieldwork_checkout=missing\nbootstrap_ready=missing\ngh_cli=ok\ngh_live=missing\ngh_hosts=ok\nconfigured_agents=claude\nconfigured_agents_status=invalid\nverify_runner=ok\nprepare_runner=ok\nbroker_socket=ok\nbroker_pat_tool=ok\nbroker_pat_marker=missing\nbroker_pat_sudo_probe=unavailable'
BOT_STALE=$'SERVICE_STATE=inactive\nBROKER_SUBMIT_STATUS=ok\nTOKEN_CONFIG_STATUS=unknown\nDIR_PENDING_COUNT=0'
render valid "" "$SNAP_STALE" "$BOT_STALE" "$LOCAL_OK"
check    "stale rc0 (needs not blocked)" "$RC" "0"
contains "stale sync row"     "$OUT" "remote out of date"
contains "stale invalid agents" "$OUT" "unparseable"
contains "stale token unknown"  "$OUT" "sudo unavailable"
contains "stale approvals opt"  "$OUT" "not configured (optional)"

# --- token tri-state ----------------------------------------------------------
render valid "" $'broker_pat_marker=missing\nbroker_pat_sudo_probe=missing\nfieldwork_checkout=ok\nbootstrap_ready=ok\ngh_cli=ok\ngh_live=ok\nverify_runner=ok\nprepare_runner=ok\nbroker_socket=ok\nbroker_pat_tool=ok\nconfigured_agents=claude\nconfigured_agents_status=ok\nclaude_cli=ok\nclaude_login=ok\nclaude_service=ok' "$BOT_OK" "$LOCAL_OK"
contains "token not confirmed -> needs" "$OUT" "Broker token: not confirmed"

# --- pending + bot down -> Approvals needs -------------------------------------
BOT_PENDING=$'SERVICE_STATE=inactive\nBROKER_SUBMIT_STATUS=ok\nTOKEN_CONFIG_STATUS=ok\nDIR_PENDING_COUNT=2'
render valid "" "$SNAP_OK" "$BOT_PENDING" "$LOCAL_OK"
contains "pending+down -> needs" "$OUT" "2 pending, bot not running"

# --- older remote: agent keys absent -> info "unknown" -------------------------
SNAP_OLD=$'fieldwork_checkout=ok\nbootstrap_ready=ok\ngh_cli=ok\ngh_live=ok\nconfigured_agents=claude\nconfigured_agents_status=ok\nverify_runner=ok\nprepare_runner=ok\nbroker_socket=ok\nbroker_pat_tool=ok\nbroker_pat_marker=ok'
render valid "" "$SNAP_OLD" "$BOT_OK" "$LOCAL_OK"
contains "older remote agent unknown" "$OUT" "older remote probe"

# --- guard: fingerprint lists in bin/fieldwork and static-checks match ---------
bin_list="$(sed -n 's/^FIELDWORK_FINGERPRINT_FILES="\(.*\)"$/\1/p' "$ROOT/bin/fieldwork")"
test_list="$(sed -n 's/^FIELDWORK_TEST_FINGERPRINT_FILES="\(.*\)"$/\1/p' "$ROOT/tests/static-checks.sh")"
check "fingerprint list non-empty" "$([ -n "$bin_list" ] && echo 1 || echo 0)" "1"
check "fingerprint lists match"    "$bin_list" "$test_list"
contains "fingerprint has messaging.sh" "$bin_list" "lib/cli/messaging.sh"
contains "fingerprint has health.sh"    "$bin_list" "lib/cli/health.sh"

# --- guard: the 7 probe keys are emitted by BOTH probe copies ------------------
probe_standalone="$ROOT/lib/scripts/fieldwork-setup-probe"
probe_inline="$ROOT/bin/fieldwork"
for tok in \
  'emit configured_agents_raw' \
  'emit configured_agents_status' \
  'status_for claude_cli command -v claude' \
  'status_for codex_cli codex_cli_ready' \
  'status_for codex_login test -f "$HOME/.fieldwork/state/codex-login-confirmed"' \
  'broker_pat_sudo_probe' \
  'agents_probe'; do
  if grep -qF "$tok" "$probe_standalone" && grep -qF "$tok" "$probe_inline"; then
    printf '  ok   probe parity: %s\n' "$tok"
  else
    printf '  FAIL probe parity: [%s] not in both probe copies\n' "$tok" >&2
    fail=1
  fi
done

exit "$fail"
