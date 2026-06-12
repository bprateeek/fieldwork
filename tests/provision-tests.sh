#!/usr/bin/env bash
# Unit tests for the provisioning seam (lib/cli/provision.sh).
# Sources the helper directly and stubs `hcloud` + the display helpers that the
# bin/fieldwork entrypoint would normally provide, so nothing touches the network
# or a real Hetzner project.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/fieldwork-provision-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Isolate ~/.ssh writes into the temp dir.
HOME="$work"
export HOME

# Resolved config the way fieldwork_load_config would leave it.
FIELDWORK_SSH_HOST="fieldwork-vps"
FIELDWORK_REMOTE_USER="fieldwork"
FIELDWORK_PROFILE="default"

# --- stubs for helpers provided by bin/fieldwork ---------------------------
status_ok_line() { printf '  [ok] %s\n' "$1"; }
info_heading()   { printf '\n%s\n\n' "$1"; }
info_row()       { printf '  %s: %s\n' "$1" "$2"; }
label_line()     { printf '%s:\n' "$1"; }
confirm()        { [ "${CONFIRM_RC:-0}" = "0" ]; }

# Real message + ssh-config helpers (provision_write_ssh_alias depends on them).
# HOME is isolated to $work above, so the managed-block writer is safe here.
# shellcheck source=lib/cli/messaging.sh
source "$ROOT/lib/cli/messaging.sh"
# shellcheck source=lib/cli/ssh-config.sh
source "$ROOT/lib/cli/ssh-config.sh"

# --- hcloud stub: records every call, returns canned data ------------------
HCLOUD_LOG="$work/hcloud.log"
: >"$HCLOUD_LOG"
hcloud() {
  printf '%s\n' "$*" >>"$HCLOUD_LOG"
  case "$1 $2" in
    "server list")
      case "$*" in
        *"-l "*) printf '%s' "${HCLOUD_LIST_RESULT:-}" ;;   # destroy lookup
        *) : ;;                                              # preflight: empty ok
      esac ;;
    "server describe") return "${HCLOUD_SERVER_EXISTS_RC:-1}" ;;
    "ssh-key describe")
      [ "${HCLOUD_KEY_EXISTS_RC:-1}" = "0" ] || return 1
      printf '{"labels": {"managed-by": "fieldwork"}}\n' ;;
    "server ip") printf '203.0.113.7\n' ;;
    "ssh-key create"|"server create"|"server delete"|"ssh-key delete") : ;;
    *) : ;;
  esac
}

# shellcheck source=lib/cli/provision.sh
source "$ROOT/lib/cli/provision.sh"

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
check_contains() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf '  ok   %s\n' "$name" ;;
    *) printf '  FAIL %s: [%s] missing [%s]\n' "$name" "$hay" "$needle" >&2; fail=1 ;;
  esac
}
check_absent() {
  local name="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf '  FAIL %s: [%s] unexpectedly contains [%s]\n' "$name" "$hay" "$needle" >&2; fail=1 ;;
    *) printf '  ok   %s\n' "$name" ;;
  esac
}

echo "[provision] a. server-name validation"
check "valid-name" "$(provision_server_name fieldwork-vps)" "fieldwork-vps"
provision_server_name "bad_host" >/dev/null 2>&1 && { echo "  FAIL underscore-rejected" >&2; fail=1; } || echo "  ok   underscore-rejected"
provision_server_name "-lead" >/dev/null 2>&1 && { echo "  FAIL leading-hyphen-rejected" >&2; fail=1; } || echo "  ok   leading-hyphen-rejected"
provision_server_name "$(printf 'a%.0s' $(seq 1 64))" >/dev/null 2>&1 && { echo "  FAIL too-long-rejected" >&2; fail=1; } || echo "  ok   too-long-rejected"

echo "[provision] b. remote-user validation"
check "valid-user" "$(provision_validate_remote_user fieldwork)" "fieldwork"
provision_validate_remote_user "bad user" >/dev/null 2>&1 && { echo "  FAIL bad-user-rejected" >&2; fail=1; } || echo "  ok   bad-user-rejected"

echo "[provision] c. label selector"
check "labels" "$(provision_label_selector)" "managed-by=fieldwork,fieldwork-profile=default,fieldwork-ssh-host=fieldwork-vps"

echo "[provision] d. cloud-init render"
ci="$(provision_render_cloud_init fieldwork 'ssh-ed25519 AAAA test')"
check_contains "ci-user" "$ci" "name: fieldwork"
check_contains "ci-sudo" "$ci" "/etc/sudoers.d/fieldwork-fieldwork"
check_contains "ci-nopasswd" "$ci" "fieldwork ALL=(ALL) NOPASSWD:ALL"
check_contains "ci-key" "$ci" "- ssh-ed25519 AAAA test"

echo "[provision] e. pubkey redaction"
keyfile="$work/k.pub"
ssh-keygen -t ed25519 -N "" -C "mycomment" -f "$work/k" >/dev/null 2>&1
red="$(provision_redact_pubkey "$keyfile")"
check_contains "redact-type" "$red" "ssh-ed25519"
check_contains "redact-comment" "$red" "mycomment"
check_contains "redact-fp" "$red" "SHA256:"
blob="$(awk '{print $2}' "$keyfile")"
check_absent "redact-no-blob" "$red" "$blob"

echo "[provision] f. create builds correct hcloud argv + writes alias"
: >"$HCLOUD_LOG"
HCLOUD_SERVER_EXISTS_RC=1 HCLOUD_KEY_EXISTS_RC=1 \
  provision_hetzner_create cx23 nbg1 fieldwork-vps "$keyfile" 0 1 >/dev/null
create_line="$(grep '^server create' "$HCLOUD_LOG")"
check_contains "create-name"   "$create_line" "--name fieldwork-vps"
check_contains "create-type"   "$create_line" "--type cx23"
check_contains "create-image"  "$create_line" "--image ubuntu-24.04"
check_contains "create-loc"    "$create_line" "--location nbg1"
check_contains "create-key"    "$create_line" "--ssh-key fieldwork-vps"
check_contains "create-userdata" "$create_line" "--user-data-from-file"
check_contains "create-label-managed" "$create_line" "--label managed-by=fieldwork"
check_contains "create-label-profile" "$create_line" "--label fieldwork-profile=default"
check_contains "create-label-host" "$create_line" "--label fieldwork-ssh-host=fieldwork-vps"
alias_block="$(cat "$work/.ssh/config")"
check_contains "alias-begin"  "$alias_block" "# BEGIN FIELDWORK SSH CONFIG: fieldwork-vps"
check_contains "alias-ip"     "$alias_block" "HostName 203.0.113.7"
check_contains "alias-accept" "$alias_block" "StrictHostKeyChecking accept-new"

echo "[provision] g. create is idempotent when server exists (no create call)"
: >"$HCLOUD_LOG"
rm -f "$work/.ssh/config"
HCLOUD_SERVER_EXISTS_RC=0 provision_hetzner_create cx23 nbg1 fieldwork-vps "$keyfile" 0 1 >/dev/null
if grep -q '^server create' "$HCLOUD_LOG"; then
  echo "  FAIL idempotent-no-create" >&2; fail=1
else
  echo "  ok   idempotent-no-create"
fi

echo "[provision] h. destroy requires exactly one match"
: >"$HCLOUD_LOG"
HCLOUD_LIST_RESULT="$(printf 'fieldwork-vps\n')" CONFIRM_RC=0 \
  provision_hetzner_destroy "" 1 >/dev/null
if grep -q '^server delete fieldwork-vps' "$HCLOUD_LOG"; then
  echo "  ok   destroy-single-match-deletes"
else
  echo "  FAIL destroy-single-match-deletes" >&2; fail=1
fi

: >"$HCLOUD_LOG"
HCLOUD_LIST_RESULT="$(printf 'a\nb\n')" \
  provision_hetzner_destroy "" 1 >/dev/null 2>&1 && rc=0 || rc=$?
check "destroy-ambiguous-refuses" "$rc" "2"
if grep -q '^server delete' "$HCLOUD_LOG"; then
  echo "  FAIL destroy-ambiguous-no-delete" >&2; fail=1
else
  echo "  ok   destroy-ambiguous-no-delete"
fi

: >"$HCLOUD_LOG"
HCLOUD_LIST_RESULT="" provision_hetzner_destroy "" 1 >/dev/null 2>&1
if grep -q '^server delete' "$HCLOUD_LOG"; then
  echo "  FAIL destroy-zero-no-delete" >&2; fail=1
else
  echo "  ok   destroy-zero-no-delete"
fi

if [ "$fail" = "0" ]; then
  echo "[provision] ok"
else
  echo "[provision] FAILED" >&2
  exit 1
fi
