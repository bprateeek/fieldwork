#!/usr/bin/env bash
# Unit tests for the shared message helpers (lib/cli/messaging.sh).
# Sources the lib directly, never the bin/fieldwork entrypoint.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/cli/messaging.sh
source "$ROOT/lib/cli/messaging.sh"

fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s: got [%s] want [%s]\n' "$name" "$got" "$want" >&2
    fail=1
  fi
}
contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf '  ok   %s\n' "$name" ;;
    *) printf '  FAIL %s: [%s] does not contain [%s]\n' "$name" "$hay" "$needle" >&2; fail=1 ;;
  esac
}
absent() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf '  FAIL %s: [%s] unexpectedly contains [%s]\n' "$name" "$hay" "$needle" >&2; fail=1 ;;
    *) printf '  ok   %s\n' "$name" ;;
  esac
}

export NO_COLOR=1

# warn → stderr, with Next/See followups, returns 0.
out="$(fieldwork_warn "broker down" "run fieldwork setup" "docs/troubleshooting.md#broker" 2>&1)"
contains "warn message"  "$out" "Warning: broker down"
contains "warn next"     "$out" "Next: run fieldwork setup"
contains "warn see"      "$out" "See: docs/troubleshooting.md#broker"
fieldwork_warn "x" >/dev/null 2>&1; check "warn returns 0" "$?" "0"

# warn to stderr only (nothing on stdout).
stdout_only="$(fieldwork_warn "to stderr" 2>/dev/null)"
check "warn writes nothing to stdout" "$stdout_only" ""

# hint → stdout, guidance only.
hint_out="$(fieldwork_hint "fieldwork doctor --remote" "docs/troubleshooting.md#vps-unreachable")"
contains "hint next" "$hint_out" "Next: fieldwork doctor --remote"
contains "hint see"  "$hint_out" "See: docs/troubleshooting.md#vps-unreachable"

# die → stderr, exits 1.
die_out="$( (fieldwork_die "boom" "fix it") 2>&1 )" || true; die_rc=0
( fieldwork_die "boom" ) >/dev/null 2>&1 || die_rc=$?
contains "die message" "$die_out" "Error: boom"
contains "die next"    "$die_out" "Next: fix it"
check    "die exits 1" "$die_rc" "1"

# No-colour mode emits no ANSI escapes.
esc="$(printf '\033')"
absent "warn no ANSI when NO_COLOR" "$(fieldwork_warn "plain" 2>&1)" "$esc"

# Explicit colour mode emits an escape (overrides tty detection).
unset NO_COLOR
colored="$(FIELDWORK_UI_COLOR=1 fieldwork_warn "bright" 2>&1)"
contains "warn ANSI when FIELDWORK_UI_COLOR=1" "$colored" "$esc"

exit "$fail"
