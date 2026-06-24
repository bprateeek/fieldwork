#!/usr/bin/env bash
# Unit tests for credential-mode awareness in verify_security (lib/cli/verify-security.sh).
# Sources the helper directly and stubs `ssh` plus the display helpers that the
# bin/fieldwork entrypoint normally provides, so nothing touches a real VPS.
# The fake `ssh` answers every probe with canned, all-green responses; the tests
# assert that App mode inspects the App private key (not the PAT) and that a
# stale-but-unreadable gh-token is not a hard fail.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/fieldwork-verify-security-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
HOME="$work"
export HOME

FIELDWORK_SSH_HOST="fieldwork-vps"
FIELDWORK_REMOTE_USER="fieldwork"
FIELDWORK_PROFILE="default"
FIELDWORK_PROJECTS_DIR="$work/projects"

# --- stubs for helpers normally provided by bin/fieldwork ------------------
phase_section()    { printf '\n[%s]\n' "$1"; }
status_ok_line()   { printf '  [ok] %s\n' "$1"; }
setup_status_line(){ printf '  [%s] %s\n' "$1" "$2"; }
label_line()       { printf '%s:\n' "$1"; }
info_row()         { printf '  %s: %s\n' "$1" "$2"; }
remote_agents_value()                 { printf '%s' "${FAKE_AGENTS:-}"; }
agents_include()                      { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
temporary_passwordless_sudo_present() { return 1; }
remote_sudo_ssh_command()             { printf 'sudo %s' "$*"; }
remote_sudo_prefix()                  { printf 'sudo'; }
fieldwork_sudoers_path()              { printf '/etc/sudoers.d/fieldwork'; }
shell_quote()                         { printf '%s' "$1"; }
shell_double_quote()                  { printf '%s' "$*"; }
valid_slug()                          { return 0; }

# --- fake ssh: dispatch on the remote command (the last argument) ----------
# $MODE picks the broker credential mode the VPS reports.
ssh() {
  local cmd="${*: -1}"
  case "$cmd" in
    "true") return 0 ;;
    *FIELDWORK_GITHUB_APP_PRIVATE_KEY_PATH*)
      printf '/etc/fieldwork-pr-broker/github-app-private-key.pem' ;;
    *FIELDWORK_GITHUB_CREDENTIAL_MODE*)
      printf '%s' "${MODE:-pat}" ;;
    *stat*github-app-private-key.pem*)
      printf 'fieldwork-pr-broker:fieldwork-pr-broker 600' ;;
    *stat*gh-token*)
      printf 'fieldwork-pr-broker:fieldwork-pr-broker 600' ;;
    *stat*requests*)
      printf 'fieldwork-pr-broker:fieldwork-pr-broker 700' ;;
    *stat*audit.jsonl*)
      printf '%s' "${FAKE_AUDIT_META-fieldwork-pr-broker:fieldwork-pr-broker 640}" ;;
    *stat*fieldwork-pr.sock*)
      printf 'fieldwork-pr-broker:fieldwork 660' ;;
    *test\ !\ -r*github-app-private-key.pem*)
      # Return success (agent cannot read) unless the negative case flips it.
      [ "${FAKE_AGENT_CAN_READ_KEY:-0}" = "1" ] && return 1
      return 0 ;;
    *test*gh-token*) return 0 ;;
    *test\ -w*fieldwork-pr.sock*) return 0 ;;
    *id\ -gn*) printf 'fieldwork' ;;
    *SocketGroup*) printf '' ;;
    *systemctl\ cat*grep*) return 0 ;;
    *test\ -f\ /etc/systemd/system/fieldwork-bot.service*) return 1 ;;
    *ufw\ status*) printf 'Status: inactive\n' ;;
    *notify.env*) return 0 ;;
    *) return 0 ;;
  esac
}

# shellcheck source=lib/cli/verify-security.sh
source "$ROOT/lib/cli/verify-security.sh"

fail=0
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) printf '  ok   %s\n' "$name" ;;
    *) printf '  FAIL %s: missing [%s]\n' "$name" "$needle" >&2; fail=1 ;;
  esac
}
assert_absent() {
  local name="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) printf '  FAIL %s: unexpected [%s]\n' "$name" "$needle" >&2; fail=1 ;;
    *) printf '  ok   %s\n' "$name" ;;
  esac
}

assert_rc() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s: rc got [%s] want [%s]\n' "$name" "$got" "$want" >&2; fail=1
  fi
}

echo "[verify-security] App mode inspects the App private key, not the PAT"
app_rc=0
app_out="$(MODE=app verify_security)" || app_rc=$?
assert_rc       "app mode passes"         "$app_rc" "0"
assert_contains "app mode reported"       "$app_out" "broker credential mode is GitHub App"
assert_contains "app key owner/mode"      "$app_out" "GitHub App private key owner/mode is fieldwork-pr-broker:fieldwork-pr-broker 600"
assert_contains "agent cannot read key"   "$app_out" "agent user cannot read GitHub App private key"
assert_contains "stale PAT tolerated"     "$app_out" "stale broker PAT is absent or unreadable by the agent"
assert_absent   "no PAT-mode check"       "$app_out" "broker PAT file owner/mode"
assert_contains "audit log owner/mode"    "$app_out" "broker audit log owner/mode is fieldwork-pr-broker:fieldwork-pr-broker 640"

echo "[verify-security] PAT mode inspects the gh-token file"
pat_rc=0
pat_out="$(MODE=pat verify_security)" || pat_rc=$?
assert_rc       "pat mode passes"         "$pat_rc" "0"
assert_contains "pat owner/mode"          "$pat_out" "broker PAT file owner/mode is fieldwork-pr-broker:fieldwork-pr-broker 600"
assert_contains "agent cannot read PAT"   "$pat_out" "agent user cannot read broker PAT"
assert_absent   "no App-mode check"       "$pat_out" "GitHub App private key"

echo "[verify-security] App mode fails when the agent can read the private key"
bad_rc=0
bad_out="$(MODE=app FAKE_AGENT_CAN_READ_KEY=1 verify_security)" || bad_rc=$?
assert_contains "reports key is readable" "$bad_out" "agent user can read GitHub App private key"
if [ "$bad_rc" -eq 0 ]; then
  printf '  FAIL readable key must be non-zero exit: rc [%s]\n' "$bad_rc" >&2; fail=1
else
  printf '  ok   readable key fails the check (rc %s)\n' "$bad_rc"
fi

echo "[verify-security] world-readable audit log (0644) is a hard fail"
audit_bad_rc=0
audit_bad_out="$(MODE=pat FAKE_AUDIT_META='fieldwork-pr-broker:fieldwork-pr-broker 644' verify_security)" || audit_bad_rc=$?
assert_contains "reports audit drift"     "$audit_bad_out" "broker audit log owner/mode is fieldwork-pr-broker:fieldwork-pr-broker 644"
assert_contains "audit remediation chown" "$audit_bad_out" "chown fieldwork-pr-broker:fieldwork-pr-broker /var/lib/fieldwork-pr-broker/audit.jsonl"
assert_contains "audit remediation chmod" "$audit_bad_out" "chmod 0640 /var/lib/fieldwork-pr-broker/audit.jsonl"
if [ "$audit_bad_rc" -eq 0 ]; then
  printf '  FAIL audit 0644 must be non-zero exit: rc [%s]\n' "$audit_bad_rc" >&2; fail=1
else
  printf '  ok   audit 0644 fails the check (rc %s)\n' "$audit_bad_rc"
fi

echo "[verify-security] unreadable audit metadata degrades to manual, not fail"
audit_manual_rc=0
audit_manual_out="$(MODE=pat FAKE_AUDIT_META= verify_security)" || audit_manual_rc=$?
assert_rc       "audit manual stays passing" "$audit_manual_rc" "0"
assert_contains "audit manual inspection"    "$audit_manual_out" "broker audit log metadata needs sudo inspection"

if [ "$fail" -ne 0 ]; then
  echo "verify-security-tests FAILED" >&2
  exit 1
fi
echo "verify-security-tests OK"
