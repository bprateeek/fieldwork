#!/usr/bin/env bash
# Real-host acceptance for the volatile VPS runtime spool after a reboot.
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  tests/vps-reboot-runtime-spool-acceptance.sh prepare
  tests/vps-reboot-runtime-spool-acceptance.sh verify <pre-reboot-boot-id> [repo-slug]

Run `prepare` immediately before reboot and retain its boot ID outside the VPS.
After the host returns, run `verify` with that ID. An optional repo slug also
checks that its hard-boundary Claude service recovered.
EOF
}

fail() {
  echo "[reboot-spool] FAIL: $*" >&2
  exit 1
}

pass() {
  echo "[reboot-spool] ok: $*"
}

boot_id_path=/proc/sys/kernel/random/boot_id
[ -r "$boot_id_path" ] || fail "Linux boot ID is unavailable"
current_boot_id="$(cat "$boot_id_path")"

case "${1:-}" in
  prepare)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    printf '%s\n' "$current_boot_id"
    exit 0
    ;;
  verify)
    [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    previous_boot_id="$2"
    repo_slug="${3:-}"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

[[ "$previous_boot_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || fail "pre-reboot boot ID is invalid"
[ "$current_boot_id" != "$previous_boot_id" ] || fail "boot ID did not change"
pass "boot ID changed"

spool=/run/fieldwork-agent/spool
[ "$(findmnt -n -o FSTYPE -T /run 2>/dev/null || true)" = tmpfs ] \
  || fail "/run is not backed by tmpfs"
[ -d "$spool" ] && [ ! -L "$spool" ] || fail "runtime spool is missing or symlinked"
[ "$(realpath -e "$spool")" = "$spool" ] || fail "runtime spool has a symlinked path component"

agent_user="$(systemctl show fieldwork-task-dispatcher.service -p User --value)"
[ -n "$agent_user" ] || fail "task dispatcher has no configured user"
agent_group="$(id -gn "$agent_user")"
expected_spool="$agent_user:$agent_group:700:directory"
actual_spool="$(stat -Lc '%U:%G:%a:%F' "$spool")"
[ "$actual_spool" = "$expected_spool" ] \
  || fail "runtime spool metadata is $actual_spool; expected $expected_spool"
pass "runtime spool is $expected_spool"

for unit in \
  fieldwork-pr-broker.socket fieldwork-pr-approve.socket \
  fieldwork-verify-runner.socket fieldwork-pr-prepare-runner.socket \
  fieldwork-task-dispatcher.service fieldwork-event-poll.timer; do
  systemctl is-active --quiet "$unit" || fail "$unit is not active"
done
pass "boundary sockets, dispatcher, and event timer are active"

poll_result="$(systemctl show fieldwork-event-poll.service -p Result --value)"
poll_status="$(systemctl show fieldwork-event-poll.service -p ExecMainStatus --value)"
[ "$poll_result:$poll_status" = success:0 ] \
  || fail "event poller result is $poll_result with status $poll_status"
pass "event poller completed successfully after boot"

if [ -n "$repo_slug" ]; then
  [[ "$repo_slug" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || fail "repo slug is invalid"
  systemctl is-active --quiet "fieldwork-agent@$repo_slug.service" \
    || fail "fieldwork-agent@$repo_slug.service did not recover"
  pass "fieldwork-agent@$repo_slug.service recovered"
fi

for socket_path in \
  /run/fieldwork-pr-broker/fieldwork-pr.sock \
  /run/fieldwork-pr-broker/fieldwork-pr-approve.sock \
  /run/fieldwork/fieldwork-verify.sock \
  /run/fieldwork/fieldwork-pr-prepare.sock; do
  [ -S "$socket_path" ] && [ ! -L "$socket_path" ] \
    || fail "socket is missing or symlinked: $socket_path"
done
pass "all boundary sockets were recreated"

echo "[reboot-spool] PASS boot_id=$current_boot_id"
