#!/usr/bin/env bash
# Install the Fieldwork PR broker daemon. Run as root on the VPS.
#
# The broker is agent-agnostic and can be installed on its own (it does not
# require the full Fieldwork bootstrap). Identities and the projects root
# default to the neutral Fieldwork layout and can be overridden with the
# FIELDWORK_BROKER_* / FIELDWORK_REMOTE_USER environment variables below.

set -euo pipefail

VERBOSE=0
LOG_FILE=""

# --- Configurable identities and paths -------------------------------------
# The broker daemon user (owns the PAT, runs server.py).
BROKER_USER="${FIELDWORK_BROKER_USER:-fieldwork-pr-broker}"
# The group that may write to the broker socket. Default is the agent user's
# own primary group. That group survives the userns mapping that
# `claude remote-control --sandbox` applies to the agent, whereas a dedicated
# supplementary group (e.g. fieldwork-pr) is stripped from the agent's effective
# group set inside the sandbox and the kernel then denies connect() against
# the 0660 group-gated socket. The trust boundary that matters (PAT in
# /etc/fieldwork-pr-broker/gh-token, mode 0400, owned by the broker user) is
# unchanged: the broker daemon validates every request regardless of caller.
BROKER_SOCKET_GROUP="${FIELDWORK_BROKER_SOCKET_GROUP:-}"
# The group that may write to the approve socket. Only the Telegram bot user
# joins this group; the agent user is NOT in it (uid-by-socket separation,
# the agent cannot fabricate /approve traffic). The group is created here so
# the broker's pending/notifications directories and the approve socket can
# reference it; the bot user is provisioned separately by
# `fieldwork setup-notify --telegram-bot` when the operator opts in.
BROKER_BOT_GROUP="${FIELDWORK_BROKER_BOT_GROUP:-fieldwork-bot}"
# The bot user (provisioned later by setup-notify --telegram-bot). Used only to
# grant a task-queue ACL when it already exists; absence is not an error here.
BOT_USER="${FIELDWORK_BOT_USER:-fieldwork-bot}"
# The unprivileged user that runs the coding agent and submits PR requests.
AGENT_USER="${FIELDWORK_REMOTE_USER:-fieldwork}"
# Root of per-repo checkouts the broker is allowed to read and push from.
PROJECTS_ROOT="${FIELDWORK_BROKER_PROJECTS_ROOT:-/home/fieldwork/projects}"
# Fixed FHS-style locations. server.py reads these from the FIELDWORK_BROKER_*
# env vars at runtime if they ever need to move; the installer keeps them fixed.
CONFIG_DIR="/etc/fieldwork-pr-broker"
STATE_DIR="/var/lib/fieldwork-pr-broker"
LIB_DIR="/usr/local/lib/fieldwork-pr-broker"
BROKER_LOG="/var/log/fieldwork-pr-broker.log"
# Shared one_shot_job task spool: agent-owned, traversable+queue-writable by the
# bot (which cannot reach the agent's $HOME). See docs/agent-adapters.md.
TASKS_DIR="${FIELDWORK_TASKS_DIR:-/var/lib/fieldwork-tasks}"
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
usage: sudo -p "[sudo] VPS Linux password for $USER: " bash install.sh [--verbose] [--log-file <path>]

Installs or repairs the root-owned PR broker daemon, socket, and rotate-pat
helper. By default it prints concise progress and saves command output to a
root-only log. Use --verbose to stream raw command output.

Identities and the projects root can be overridden via environment variables:
  FIELDWORK_BROKER_USER          broker daemon user (default fieldwork-pr-broker)
  FIELDWORK_BROKER_SOCKET_GROUP  socket access group (default: agent user's primary group)
  FIELDWORK_REMOTE_USER          agent user that submits requests (default fieldwork)
  FIELDWORK_BROKER_PROJECTS_ROOT projects root (default /home/fieldwork/projects)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    --log-file)
      LOG_FILE="${2:?--log-file requires a path}"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *) echo "unknown broker install argument: $1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

SRC="$(cd -P "$(dirname "$0")" && pwd)"
# shellcheck source=lib/scripts/fieldwork-status
source "$SRC/../scripts/fieldwork-status"
trap 'fieldwork_status_cleanup' EXIT
LOG_DIR="${FIELDWORK_BROKER_INSTALL_LOG_DIR:-/var/log/fieldwork}"
install -d -m 700 "$LOG_DIR"
if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$LOG_DIR/pr-broker-install-$(date -u +%Y%m%d-%H%M%S).log"
fi
if [ -L "$LOG_FILE" ]; then
  echo "refusing to write broker install log through symlink: $LOG_FILE" >&2
  exit 1
fi
umask 077
: >"$LOG_FILE"
chmod 600 "$LOG_FILE"

USE_COLOR=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  USE_COLOR=1
fi

SUPPORTS_UTF8=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*) SUPPORTS_UTF8=1 ;;
esac

DOT_DONE="*"
DOT_TODO="."
if [ -t 1 ] && [ "$SUPPORTS_UTF8" = "1" ]; then
  DOT_DONE="●"
  DOT_TODO="○"
fi

TOTAL_PHASES=6
PHASE_INDEX=0
CURRENT_STEP=""

green() {
  if [ "$USE_COLOR" = "1" ]; then
    printf '\033[32m%s\033[0m' "$1"
  else
    printf '%s' "$1"
  fi
}

yellow() {
  if [ "$USE_COLOR" = "1" ]; then
    printf '\033[33m%s\033[0m' "$1"
  else
    printf '%s' "$1"
  fi
}

red() {
  if [ "$USE_COLOR" = "1" ]; then
    printf '\033[31m%s\033[0m' "$1"
  else
    printf '%s' "$1"
  fi
}

progress_dots() {
  local i
  i=1
  while [ "$i" -le "$TOTAL_PHASES" ]; do
    if [ "$i" -le "$PHASE_INDEX" ]; then
      green "$DOT_DONE"
    else
      printf '%s' "$DOT_TODO"
    fi
    i=$((i + 1))
  done
}

step() {
  PHASE_INDEX=$((PHASE_INDEX + 1))
  CURRENT_STEP="$*"
  echo
  if [ -t 1 ]; then
    printf 'Step %02d/%02d  %s\n' "$PHASE_INDEX" "$TOTAL_PHASES" "$*"
  else
    printf '[%02d/%02d] %s\n' "$PHASE_INDEX" "$TOTAL_PHASES" "$*"
  fi
}

ok() {
  if [ -t 1 ] && [ "$SUPPORTS_UTF8" = "1" ]; then
    printf '  %s  %s\n' "$(green "✓ ready")" "$*"
  else
    printf '  [ready] %s\n' "$*"
  fi
}

note() {
  if [ -t 1 ] && [ "$SUPPORTS_UTF8" = "1" ]; then
    printf '  i %s\n' "$*"
  else
    printf '  [info] %s\n' "$*"
  fi
}

fail() {
  if [ -t 1 ] && [ "$SUPPORTS_UTF8" = "1" ]; then
    printf '  %s  %s\n' "$(red "× blocked")" "$*" >&2
  else
    printf '  [blocked] %s\n' "$*" >&2
  fi
}

print_failure_tail() {
  local cmd_log="$1"
  echo "  Log: $LOG_FILE"
  if [ -s "$cmd_log" ]; then
    echo "  Last output:"
    tail -40 "$cmd_log" | sed 's/^/    /'
  fi
  echo
  echo "Fix the issue, then rerun:"
  if [ "${FIELDWORK_SETUP_CONTEXT:-}" = "guided" ]; then
    echo "  fieldwork setup"
  else
    echo "  sudo bash install.sh"
  fi
}

run_logged() {
  local label="$1"
  shift
  local cmd_log status
  cmd_log="$(mktemp "${TMPDIR:-/tmp}/fieldwork-broker-install-step.XXXXXX")"

  {
    printf '\n### %s\n' "$label"
    printf '$'
    printf ' %q' "$@"
    printf '\n'
  } >>"$LOG_FILE"

  if [ "$VERBOSE" = "1" ]; then
    note "run: $label"
    set +e
    "$@" 2>&1 | tee "$cmd_log" | tee -a "$LOG_FILE"
    status=${PIPESTATUS[0]}
    set -e
  else
    fieldwork_status_start "[$PHASE_INDEX/$TOTAL_PHASES] $label"
    set +e
    "$@" >"$cmd_log" 2>&1
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
      fieldwork_status_succeed ""
    else
      fieldwork_status_fail ""
    fi
    cat "$cmd_log" >>"$LOG_FILE"
  fi

  if [ "$status" -eq 0 ]; then
    [ "$VERBOSE" = "1" ] && ok "$label"
    rm -f "$cmd_log"
    return 0
  fi

  fail "${CURRENT_STEP:-broker install} failed at: $label"
  print_failure_tail "$cmd_log"
  rm -f "$cmd_log"
  return "$status"
}

setup_users_groups() {
  id "$AGENT_USER" >/dev/null 2>&1 || { echo "agent user '$AGENT_USER' is missing"; return 1; }
  if ! id "$BROKER_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$BROKER_USER"
  fi
  # Default the socket access group to the agent user's primary group so the
  # agent retains access inside its userns (see comment on BROKER_SOCKET_GROUP
  # at the top of this file). An explicit FIELDWORK_BROKER_SOCKET_GROUP
  # override is honoured but the operator owns the userns interaction in that
  # case.
  if [ -z "$BROKER_SOCKET_GROUP" ]; then
    BROKER_SOCKET_GROUP="$(id -gn "$AGENT_USER")"
  fi
  getent group "$BROKER_SOCKET_GROUP" >/dev/null || groupadd --system "$BROKER_SOCKET_GROUP"
  if [ "$BROKER_SOCKET_GROUP" != "$(id -gn "$AGENT_USER")" ]; then
    # Only needed when the operator overrode away from the agent's primary
    # group; the agent is already in its own primary group.
    usermod -a -G "$BROKER_SOCKET_GROUP" "$AGENT_USER"
  fi
  # The bot group always exists, even when the bot daemon is not installed,
  # the broker writes pending request files group-readable by it, and the
  # approve socket carries this as its SocketGroup. The agent user must NOT
  # be added to this group; the bot user joins it later, only when the
  # operator runs `fieldwork setup-notify --telegram-bot`.
  getent group "$BROKER_BOT_GROUP" >/dev/null || groupadd --system "$BROKER_BOT_GROUP"
}

setup_directories() {
  local agent_home audit_path
  install -o "$BROKER_USER" -g "$BROKER_USER" -m 700 -d "$CONFIG_DIR"
  install -o "$BROKER_USER" -g "$BROKER_USER" -m 700 -d "$STATE_DIR"
  install -o "$BROKER_USER" -g "$BROKER_USER" -m 700 -d "$STATE_DIR/requests"
  # Pending requests directory is shared between broker (writes pending files)
  # and bot (writes .notified sidecars + deletes after decisions). Both are
  # member-or-owner of the bot group; the agent user is not.
  install -o "$BROKER_USER" -g "$BROKER_BOT_GROUP" -m 2770 -d "$STATE_DIR/pending"
  # Notifications drop-off: agent user writes one JSON per outbound message,
  # bot user reads and deletes. Owner=agent + group=bot + setgid so files
  # created by the agent inherit the bot group and are deletable by the bot.
  install -o "$AGENT_USER" -g "$BROKER_BOT_GROUP" -m 2770 -d "$STATE_DIR/notifications"
  if [ ! -f "$STATE_DIR/audit.jsonl" ]; then
    install -o "$BROKER_USER" -g "$BROKER_USER" -m 640 /dev/null "$STATE_DIR/audit.jsonl"
  fi
  for audit_path in "$STATE_DIR"/audit.jsonl "$STATE_DIR"/audit.jsonl.[0-9]*; do
    [ -e "$audit_path" ] || continue
    chown "$BROKER_USER:$BROKER_USER" "$audit_path"
    chmod 640 "$audit_path"
  done
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m "u:$AGENT_USER:--x" "$STATE_DIR"
    setfacl -d -m "u:$AGENT_USER:r--" "$STATE_DIR"
    for audit_path in "$STATE_DIR"/audit.jsonl "$STATE_DIR"/audit.jsonl.[0-9]*; do
      [ -e "$audit_path" ] || continue
      setfacl -m "u:$AGENT_USER:r--" "$audit_path"
    done
    setfacl -m "u:$BROKER_USER:rwx" "$STATE_DIR/notifications"
    setfacl -d -m "u:$BROKER_USER:rwx" "$STATE_DIR/notifications"
    # Bot traverse on STATE_DIR. The bot reaches pending/ + notifications/ only
    # by traversing STATE_DIR; it otherwise relies on the systemd StateDirectory
    # 0755 (other=r-x), which install's 0700 transiently removes until the broker
    # service next starts - crash-looping the bot. An explicit traverse ACL makes
    # the bot independent of that race. Guarded: the bot user is created later by
    # setup-notify, which (re)applies this; harmless when absent.
    if getent passwd "$BOT_USER" >/dev/null 2>&1; then
      setfacl -m "u:$BOT_USER:--x" "$STATE_DIR"
    fi
  else
    echo "setfacl unavailable; audit/dashboard read access and broker lifecycle drops need manual ACL setup" >&2
  fi
  # One_shot_job task spool. Agent-owned; the bot can only enqueue (traverse the
  # base + rwx on queue/), never touch processing/done/failed. The bot user is
  # created later by setup-notify --telegram-bot, which (re)applies the bot ACL;
  # apply it here too when the user already exists so re-runs converge.
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 700 -d "$TASKS_DIR"
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 700 -d \
    "$TASKS_DIR/queue" "$TASKS_DIR/processing" "$TASKS_DIR/done" "$TASKS_DIR/failed"
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -d -m "u:$AGENT_USER:rwx" "$TASKS_DIR/queue"
    if getent passwd "$BOT_USER" >/dev/null 2>&1; then
      setfacl -m "u:$BOT_USER:--x" "$TASKS_DIR"
      setfacl -m "u:$BOT_USER:rwx" "$TASKS_DIR/queue"
      setfacl -d -m "u:$BOT_USER:rwx" "$TASKS_DIR/queue"
    fi
  else
    echo "setfacl unavailable; Telegram /task enqueue needs manual ACL setup for $TASKS_DIR/queue" >&2
  fi
  install -o root -g root -m 755 -d "$LIB_DIR"
  # The broker reads each repo checkout under the agent user's home; that home
  # and projects root need traversal bits so the broker user can reach the
  # checkout. Repos themselves get a targeted ACL during onboarding.
  agent_home="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
  [ -n "$agent_home" ] && chmod o+x "$agent_home"
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 755 -d "$PROJECTS_ROOT"
  chmod o+x "$PROJECTS_ROOT"
}

# Substitute the configured Unix identities and projects root into a systemd
# unit as it is installed. Only the user/group lines and the projects root are
# rewritten. The service and directory names (fieldwork-pr-broker.socket,
# StateDirectory=, RuntimeDirectory=, /etc|/var/lib|/usr/local/lib paths) are
# the broker's fixed identity and are left intact. The checked-in unit files
# carry the neutral defaults, so this is a no-op for a default install.
install_unit() {
  local src="$1" dst="$2"
  sed \
    -e "s|^User=fieldwork-pr-broker$|User=$BROKER_USER|" \
    -e "s|^Group=fieldwork-pr-broker$|Group=$BROKER_USER|" \
    -e "s|^Environment=FIELDWORK_BROKER_AUDIT_READ_USER=fieldwork$|Environment=FIELDWORK_BROKER_AUDIT_READ_USER=$AGENT_USER|" \
    -e "s|^SocketUser=fieldwork-pr-broker$|SocketUser=$BROKER_USER|" \
    -e "s|^SocketGroup=fieldwork-pr$|SocketGroup=$BROKER_SOCKET_GROUP|" \
    -e "s|^SocketGroup=fieldwork-bot$|SocketGroup=$BROKER_BOT_GROUP|" \
    -e "s|/home/fieldwork/projects|$PROJECTS_ROOT|g" \
    "$src" >"$dst"
  chown root:root "$dst"
  chmod 644 "$dst"
}

install_broker_files() {
  install -o root -g root -m 644 "$SRC/server.py" "$LIB_DIR/server.py"
  install -o root -g root -m 644 "$SRC/../../schema/pr-request.schema.json" "$LIB_DIR/pr-request.schema.json"
  install -o "$BROKER_USER" -g "$BROKER_USER" -m 750 "$SRC/git-askpass" "$LIB_DIR/git-askpass"
  install_unit "$SRC/fieldwork-pr-broker.socket" /etc/systemd/system/fieldwork-pr-broker.socket
  install_unit "$SRC/fieldwork-pr-approve.socket" /etc/systemd/system/fieldwork-pr-approve.socket
  install_unit "$SRC/fieldwork-pr-broker.service" /etc/systemd/system/fieldwork-pr-broker.service
  install -o root -g root -m 700 "$SRC/rotate-pat" /usr/local/sbin/rotate-pat
  install -o "$BROKER_USER" -g "$BROKER_USER" -m 640 /dev/null "$BROKER_LOG"
}

install_thin_client() {
  local agent_home
  agent_home="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
  [ -n "$agent_home" ] || { echo "cannot resolve home for agent user '$AGENT_USER'"; return 1; }
  sudo -u "$AGENT_USER" install -d -m 755 "$agent_home/.local/bin"
  sudo -u "$AGENT_USER" ln -sfn "$agent_home/.fieldwork/scripts/fieldwork-pr-submit" "$agent_home/.local/bin/fieldwork-pr-submit"
}

skip_thin_client() {
  # Standalone broker installs do not ship the Fieldwork thin client; the
  # operator wires up their own client per docs/broker-standalone.md.
  note "skipping fieldwork-pr-submit thin client (standalone broker install)"
}

setup_systemd() {
  systemctl daemon-reload
  # Socket units can stay active with an unlinked AF_UNIX path while the
  # broker service keeps its inherited fd. Reopen the pair together so both
  # filesystem socket paths match their unit state after a repair install.
  systemctl stop fieldwork-pr-broker.service fieldwork-pr-broker.socket fieldwork-pr-approve.socket
  systemctl enable --now fieldwork-pr-broker.socket
  systemctl enable --now fieldwork-pr-approve.socket
}

verify_installation() {
  sleep 1
  test -S /run/fieldwork-pr-broker/fieldwork-pr.sock
  test "$(stat -c '%U:%G %a' /run/fieldwork-pr-broker/fieldwork-pr.sock)" = "$BROKER_USER:$BROKER_SOCKET_GROUP 660"
  test -S /run/fieldwork-pr-broker/fieldwork-pr-approve.sock
  test "$(stat -c '%U:%G %a' /run/fieldwork-pr-broker/fieldwork-pr-approve.sock)" = "$BROKER_USER:$BROKER_BOT_GROUP 660"
  test -f "$STATE_DIR/audit.jsonl"
  test "$(stat -c '%U:%G %a' "$STATE_DIR/audit.jsonl")" = "$BROKER_USER:$BROKER_USER 640"
  id "$AGENT_USER" | grep -qw "$BROKER_SOCKET_GROUP"
  if id "$AGENT_USER" | grep -qw "$BROKER_BOT_GROUP"; then
    echo "agent user '$AGENT_USER' must NOT be in '$BROKER_BOT_GROUP' (would let it fabricate /approve traffic)" >&2
    return 1
  fi
  test -f /usr/local/sbin/rotate-pat
  test "$(stat -c '%U:%G %a' /usr/local/sbin/rotate-pat)" = "root:root 700"
}

resolve_socket_group_for_display() {
  if [ -z "$BROKER_SOCKET_GROUP" ] && id "$AGENT_USER" >/dev/null 2>&1; then
    BROKER_SOCKET_GROUP="$(id -gn "$AGENT_USER")"
  fi
}

resolve_socket_group_for_display

echo "PR broker install"
echo
echo "  Installs the root-owned broker daemon, socket, and rotate-pat helper."
echo "  The GitHub credential is stored in the next setup step, not by this installer."
echo
echo "  Identities:"
printf '    %-14s %s\n' "broker user:"  "$BROKER_USER"
printf '    %-14s %s\n' "socket group:" "$BROKER_SOCKET_GROUP"
printf '    %-14s %s\n' "bot group:"    "$BROKER_BOT_GROUP"
printf '    %-14s %s\n' "agent user:"   "$AGENT_USER"
echo
echo "  Full log: $LOG_FILE"

step "users and groups"
run_logged "broker user and socket group ready" setup_users_groups
ok "users and groups ready"

step "directories"
run_logged "broker directories ready" setup_directories
ok "directories ready"

step "broker files"
run_logged "broker daemon and helper files installed" install_broker_files
ok "broker files ready"

step "thin client"
if [ "${FIELDWORK_BROKER_STANDALONE:-0}" = "1" ]; then
  run_logged "fieldwork-pr-submit thin client skipped (standalone)" skip_thin_client
else
  run_logged "fieldwork-pr-submit thin client linked" install_thin_client
fi
ok "thin client ready"

step "systemd socket"
run_logged "broker sockets reopened" setup_systemd
ok "systemd socket ready"

step "verification"
run_logged "broker socket and helper verified" verify_installation
ok "verification complete"

echo
ok "broker install complete"
note "Next in setup: store the broker GitHub credential with rotate-pat."
note "If socket access is stale, reconnect to the VPS so the agent user sees the $BROKER_SOCKET_GROUP group."
