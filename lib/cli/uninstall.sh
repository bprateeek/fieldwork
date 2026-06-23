#!/usr/bin/env bash
# Sourced by bin/fieldwork. Do not execute directly.
# Contains uninstall command handler only.

uninstall_fieldwork() {
  local dry_run=0
  local yes=0
  local scope_local=0
  local scope_remote=0
  local scope_broker=0
  local scope_bot=0
  local no_broker=0
  local purge=0
  local remove_system_users=0
  local quiet=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --yes) yes=1; shift ;;
      --quiet) quiet=1; shift ;;
      --local) scope_local=1; shift ;;
      --remote) scope_remote=1; shift ;;
      --broker) scope_broker=1; shift ;;
      --bot) scope_bot=1; shift ;;
      --no-broker) no_broker=1; shift ;;
      --purge) purge=1; shift ;;
      --remove-system-users) remove_system_users=1; shift ;;
      --help|-h)
        cat <<'EOF'
usage: fieldwork uninstall [--dry-run] [--yes] [--quiet] [--local] [--remote] [--broker] [--bot] [--no-broker] [--purge] [--remove-system-users]

Guided teardown for Fieldwork-managed local files, remote user services,
broker/system services, and approval-bot infrastructure.

Default scope removes discovered Fieldwork-owned local assets, remote user
services/scripts when SSH works, broker/system services when discovered, and
approval-bot infrastructure when discovered.

It never removes repositories, SSH keys, VPS user accounts, Docker, GitHub CLI,
Claude Code, non-Fieldwork SSH config, or user-authored Claude config.
EOF
        return 0
        ;;
      *) echo "unknown uninstall argument: $1" >&2; return 2 ;;
    esac
  done

  if [ "$scope_broker" = "1" ] && [ "$no_broker" = "1" ]; then
    echo "fieldwork uninstall: --broker and --no-broker cannot be used together" >&2
    return 2
  fi
  if [ "$remove_system_users" = "1" ] && [ "$purge" != "1" ]; then
    echo "fieldwork uninstall: --remove-system-users requires --purge" >&2
    return 2
  fi
  UNINSTALL_QUIET="$quiet"
  FIELDWORK_STATUS_QUIET="$quiet"
  UNINSTALL_CLEANUP_FAILED=0

  echo "Fieldwork uninstall"
  echo "Root: $(display_local_path "$FIELDWORK_ROOT")"
  if [ -t 1 ] && supports_utf8; then
    echo "Legend: $(green "✓ ready") | $(yellow "! needs action") | $(blue "→ manual step") | $(red "× blocked") | $(cyan "i") info"
  else
    echo "Legend: [ready] | [needs-action] | [manual] | [blocked] | [info]"
  fi
  echo "Safe to rerun: yes"
  echo

  local positive_scope=0
  if [ "$scope_local" = "1" ] || [ "$scope_remote" = "1" ] || [ "$scope_broker" = "1" ] || [ "$scope_bot" = "1" ]; then
    positive_scope=1
  fi

  local do_local=0
  local do_remote=0
  local do_broker=0
  local do_bot=0
  if [ "$positive_scope" = "0" ]; then
    do_local=1
    do_remote=1
    do_broker=1
    do_bot=1
  else
    do_local="$scope_local"
    do_remote="$scope_remote"
    do_broker="$scope_broker"
    do_bot="$scope_bot"
  fi
  [ "$no_broker" = "1" ] && do_broker=0

  if { [ "$do_remote" = "1" ] || [ "$do_broker" = "1" ] || [ "$do_bot" = "1" ]; } && [ -z "${FIELDWORK_SSH_HOST:-}" ]; then
    echo "fieldwork uninstall: FIELDWORK_SSH_HOST is required for remote uninstall scopes" >&2
    return 2
  fi

  local recorded_authorized_key_fingerprint=""
  local recorded_authorized_key_public_key=""
  local recorded_authorized_key_host=""
  local recorded_authorized_key_remote_user=""
  recorded_authorized_key_fingerprint="$(uninstall_recorded_authorized_key_field fingerprint 2>/dev/null || true)"
  recorded_authorized_key_public_key="$(uninstall_recorded_authorized_key_field public_key 2>/dev/null || true)"
  recorded_authorized_key_host="$(uninstall_recorded_authorized_key_field host 2>/dev/null || true)"
  recorded_authorized_key_remote_user="$(uninstall_recorded_authorized_key_field remote_user 2>/dev/null || true)"

  local local_ssh_alias_block=""
  local local_ssh_alias_present_at_start=0
  if local_ssh_alias_block="$(uninstall_capture_local_ssh_alias_block 2>/dev/null)"; then
    local_ssh_alias_present_at_start=1
  else
    local_ssh_alias_block=""
  fi

  local direct_ssh_target=""
  local direct_ssh_target_note=""
  if ! direct_ssh_target="$(uninstall_direct_ssh_target "$local_ssh_alias_block" "$recorded_authorized_key_host" "$recorded_authorized_key_remote_user" 2>/dev/null)"; then
    direct_ssh_target="${recorded_authorized_key_remote_user:-$FIELDWORK_REMOTE_USER}@<your-vps-host>"
    direct_ssh_target_note="(could not auto-detect VPS host, substitute the IP/hostname used during setup)"
  fi

  local remote_available=0
  local broker_discovered=0
  local bot_discovered=0
  if [ "$do_remote" = "1" ] || [ "$do_broker" = "1" ] || [ "$do_bot" = "1" ]; then
    if uninstall_status_check "checking SSH reachability for uninstall" ssh -o BatchMode=yes -o ConnectTimeout=5 "$FIELDWORK_SSH_HOST" "true"; then
      remote_available=1
    fi
  fi
  if [ "$remote_available" = "1" ] && [ "$do_broker" = "1" ]; then
    if uninstall_status_check "checking remote broker install state" ssh "$FIELDWORK_SSH_HOST" '
test -e /etc/systemd/system/fieldwork-pr-broker.service ||
test -e /etc/systemd/system/fieldwork-pr-broker.socket ||
test -e /etc/systemd/system/fieldwork-pr-approve.socket ||
test -L /etc/systemd/system/multi-user.target.wants/fieldwork-pr-broker.service ||
test -L /etc/systemd/system/sockets.target.wants/fieldwork-pr-broker.socket ||
test -L /etc/systemd/system/sockets.target.wants/fieldwork-pr-approve.socket ||
test -d /etc/fieldwork-pr-broker ||
test -f /etc/fieldwork-pr-broker/gh-token ||
test -d /usr/local/lib/fieldwork-pr-broker ||
test -f /usr/local/lib/fieldwork-pr-broker/server.py ||
test -f /usr/local/lib/fieldwork-pr-broker/git-askpass ||
test -f /usr/local/lib/fieldwork-pr-broker/pr-request.schema.json ||
test -f /usr/local/sbin/rotate-pat ||
test -d /var/lib/fieldwork-pr-broker ||
test -d /var/lib/fieldwork-pr-broker/requests ||
test -d /var/lib/fieldwork-pr-broker/pending ||
test -d /var/lib/fieldwork-pr-broker/notifications ||
test -f /var/log/fieldwork-pr-broker.log ||
test -d /var/log/fieldwork ||
test -d /run/fieldwork-pr-broker ||
test -S /run/fieldwork-pr-broker/fieldwork-pr.sock ||
test -S /run/fieldwork-pr-broker/fieldwork-pr-approve.sock ||
id fieldwork-pr-broker >/dev/null 2>&1 ||
getent group fieldwork-pr >/dev/null 2>&1
'; then
      broker_discovered=1
    fi
  fi
  if [ "$remote_available" = "1" ] && [ "$do_bot" = "1" ]; then
    if uninstall_status_check "checking approval bot install state" ssh "$FIELDWORK_SSH_HOST" '
test -e /etc/systemd/system/fieldwork-bot.service ||
test -L /etc/systemd/system/multi-user.target.wants/fieldwork-bot.service ||
test -f /usr/local/bin/fieldwork-bot ||
test -d /etc/fieldwork-bot ||
test -f /etc/fieldwork-bot/config.toml ||
test -f /etc/fieldwork-bot/secret ||
test -d /var/lib/fieldwork-bot ||
test -f /var/lib/fieldwork-bot/bot-health.json ||
test -f /var/log/fieldwork-bot.log ||
id fieldwork-bot >/dev/null 2>&1 ||
find /tmp -maxdepth 1 \( -name "fieldwork-install-bot-*.sh" -o -name "fieldwork-bot-config.toml" -o -name "fieldwork-bot-secret" \) -type f -print -quit 2>/dev/null | grep -q .
'; then
      bot_discovered=1
    fi
  fi

  local local_notify_state="absent"
  if [ -f "$HOME/.fieldwork/notify.env" ]; then
    if grep -Fq "Managed by Fieldwork" "$HOME/.fieldwork/notify.env" 2>/dev/null; then
      local_notify_state="marked"
    else
      local_notify_state="unmarked"
    fi
  fi

  local remote_notify_state="absent"
  if [ "$remote_available" = "1" ] && [ "$do_remote" = "1" ]; then
    if uninstall_status_check "checking remote notification config" ssh "$FIELDWORK_SSH_HOST" "test -f ~/.fieldwork/notify.env"; then
      if uninstall_status_check "checking remote notification config" ssh "$FIELDWORK_SSH_HOST" "grep -Fq 'Managed by Fieldwork' ~/.fieldwork/notify.env"; then
        remote_notify_state="marked"
      else
        remote_notify_state="unmarked"
      fi
    fi
  fi

  print_uninstall_plan "$dry_run" "$do_local" "$do_remote" "$do_broker" "$do_bot" "$remote_available" "$broker_discovered" "$bot_discovered" "$purge" "$remove_system_users" "$local_notify_state" "$remote_notify_state"

  if [ "$dry_run" = "1" ]; then
    return 0
  fi

  if ! confirm "Continue with Fieldwork uninstall?" "$yes"; then
    echo "[fieldwork uninstall] cancelled"
    return 0
  fi

  local remove_local_notify=0
  local remove_remote_notify=0
  if [ "$local_notify_state" = "marked" ]; then
    remove_local_notify=1
  elif [ "$local_notify_state" = "unmarked" ] && [ "$yes" != "1" ]; then
    if confirm "Remove notification config ~/.fieldwork/notify.env?" 0; then
      remove_local_notify=1
    fi
  fi
  if [ "$remote_notify_state" = "marked" ]; then
    remove_remote_notify=1
  elif [ "$remote_notify_state" = "unmarked" ] && [ "$yes" != "1" ]; then
    if confirm "Remove remote notification config ~/.fieldwork/notify.env?" 0; then
      remove_remote_notify=1
    fi
  fi

  local ufw_public_ssh_rule_state="not checked"
  if [ "$remote_available" = "1" ] && { [ "$do_remote" = "1" ] || [ "$do_broker" = "1" ] || [ "$do_bot" = "1" ]; }; then
    UNINSTALL_PUBLIC_SSH_RULE_STATE="unknown"
    uninstall_detect_public_ssh_rule
    ufw_public_ssh_rule_state="$UNINSTALL_PUBLIC_SSH_RULE_STATE"
  elif [ "$remote_available" != "1" ] && { [ "$do_remote" = "1" ] || [ "$do_broker" = "1" ] || [ "$do_bot" = "1" ]; }; then
    ufw_public_ssh_rule_state="SSH unavailable"
  fi

  local remove_users_confirmed=0
  if [ "$remove_system_users" = "1" ]; then
    if [ "$yes" = "1" ]; then
      remove_users_confirmed=1
    else
      echo
      echo "This will remove Fieldwork system users/groups:"
      echo "  - fieldwork-pr-broker"
      echo "  - fieldwork-bot"
      printf 'Type "remove fieldwork users" to continue: '
      local typed=""
      IFS= read -r typed || typed=""
      echo
      if [ "$typed" = "remove fieldwork users" ]; then
        remove_users_confirmed=1
      else
        echo "[fieldwork uninstall] keeping system users/groups"
      fi
    fi
  fi

  echo
  echo "Uninstalling"
  if [ "$do_local" = "1" ]; then
    uninstall_local_files "$purge" "$remove_local_notify"
  fi
  local defer_temporary_sudo=0
  local system_cleanup_failed=0
  if [ "$remote_available" = "1" ] && [ "$do_remote" = "1" ]; then
    if { [ "$do_broker" = "1" ] && [ "$broker_discovered" = "1" ]; } || { [ "$do_bot" = "1" ] && [ "$bot_discovered" = "1" ]; }; then
      defer_temporary_sudo=1
    fi
  fi

  if [ "$do_remote" = "1" ]; then
    if [ "$remote_available" = "1" ]; then
      if ! uninstall_run_captured "cleaning remote user services" "remote user cleanup complete" "remote user cleanup failed" uninstall_remote_user "$purge" "$remove_remote_notify" "$((1 - defer_temporary_sudo))"; then
        :
      fi
    else
      uninstall_skipped "remote user cleanup" "SSH unavailable"
    fi
  fi
  if [ "$do_broker" = "1" ]; then
    if [ "$remote_available" = "1" ] && [ "$broker_discovered" = "1" ]; then
      if ! uninstall_remote_broker "$purge" "$remove_users_confirmed"; then
        system_cleanup_failed=1
        uninstall_failed "broker/system cleanup" "sudo unavailable or command failed"
      fi
    elif [ "$remote_available" != "1" ]; then
      uninstall_skipped "broker/system cleanup" "SSH unavailable"
    else
      uninstall_skipped "broker/system cleanup" "not present"
    fi
  fi
  if [ "$do_bot" = "1" ]; then
    if [ "$remote_available" = "1" ] && [ "$bot_discovered" = "1" ]; then
      if ! uninstall_remote_bot "$purge" "$remove_users_confirmed"; then
        system_cleanup_failed=1
        uninstall_failed "approval bot cleanup" "sudo unavailable or command failed"
      fi
    elif [ "$remote_available" != "1" ]; then
      uninstall_skipped "approval bot cleanup" "SSH unavailable"
    else
      uninstall_skipped "approval bot cleanup" "not present"
    fi
  fi
  if [ "$defer_temporary_sudo" = "1" ]; then
    if [ "$system_cleanup_failed" = "1" ]; then
      uninstall_skipped "temporary sudoers rule" "kept for failed system cleanup retry"
    else
      uninstall_remote_temporary_sudo || true
    fi
  fi
  if [ "$do_local" = "1" ]; then
    uninstall_local_ssh_alias
  fi

  local local_ssh_alias_block_at_end=""
  local local_ssh_alias_present_at_end=0
  if local_ssh_alias_block_at_end="$(uninstall_capture_local_ssh_alias_block 2>/dev/null)"; then
    local_ssh_alias_present_at_end=1
  else
    local_ssh_alias_block_at_end=""
  fi
  local manual_ssh_target="$direct_ssh_target"
  local manual_ssh_target_note=""
  local manual_ssh_target_placeholder_note="$direct_ssh_target_note"
  local manual_local_ssh_alias_block="$local_ssh_alias_block_at_end"
  if [ "$local_ssh_alias_present_at_end" = "1" ]; then
    manual_ssh_target="$FIELDWORK_SSH_HOST"
    manual_ssh_target_note=""
    manual_ssh_target_placeholder_note=""
  elif [ "$local_ssh_alias_present_at_start" = "1" ]; then
    manual_ssh_target_note="Using direct target because the $FIELDWORK_SSH_HOST SSH alias was removed during uninstall."
    manual_local_ssh_alias_block="$local_ssh_alias_block"
  fi

  echo
  if [ "${UNINSTALL_CLEANUP_FAILED:-0}" = "1" ]; then
    echo "Uninstall finished with follow-up needed."
  else
    echo "Uninstall complete."
  fi
  phase_section "Kept"
  echo "  - Repositories and project checkouts"
  echo "  - SSH keys and non-Fieldwork SSH config"
  echo "  - VPS user account"
  echo "  - Docker"
  echo "  - GitHub CLI"
  echo "  - Claude Code"
  echo "  - User-authored Claude config"
  print_uninstall_manual_checklist \
    "$manual_ssh_target" \
    "$FIELDWORK_REMOTE_USER" \
    "$recorded_authorized_key_fingerprint" \
    "$recorded_authorized_key_public_key" \
    "$recorded_authorized_key_host" \
    "$recorded_authorized_key_remote_user" \
    "$manual_local_ssh_alias_block" \
    "$ufw_public_ssh_rule_state" \
    "$FIELDWORK_SSH_HOST" \
    "$manual_ssh_target_note" \
    "$manual_ssh_target_placeholder_note"
}

print_uninstall_plan() {
  local dry_run="$1"
  local do_local="$2"
  local do_remote="$3"
  local do_broker="$4"
  local do_bot="$5"
  local remote_available="$6"
  local broker_discovered="$7"
  local bot_discovered="$8"
  local purge="$9"
  local remove_system_users="${10}"
  local local_notify_state="${11}"
  local remote_notify_state="${12}"

  if [ "$dry_run" = "1" ]; then
    phase_section "Fieldwork uninstall dry run"
    echo "Would remove:"
  else
    phase_section "Fieldwork uninstall plan"
    echo "This will remove:"
  fi

  if [ "$do_local" = "1" ]; then
    phase_section "Local"
    echo "  - Fieldwork CLI symlinks"
    echo "  - Fieldwork Claude script/template/infra symlinks"
    echo "  - Local Fieldwork config and setup state"
    echo "  - Fieldwork-marked SSH config aliases"
    [ "$purge" = "1" ] && echo "  - Local Fieldwork cache/log state"
  fi

  if [ "$do_remote" = "1" ]; then
    phase_section "Remote user services"
    if [ "$remote_available" = "1" ]; then
      echo "  - fieldwork-agent@*.service sessions and unit"
      echo "  - fieldwork-verify-runner.socket/service"
      echo "  - fieldwork-pr-prepare-runner.socket/service"
      echo "  - fieldwork-event-poll.timer/service"
      echo "  - fieldwork-dashboard.service"
      echo "  - remote Fieldwork scripts and synced checkout"
      [ "$purge" = "1" ] && echo "  - remote Fieldwork cache/log state"
    else
      echo "  - skipped: SSH unavailable"
    fi
  fi

  if [ "$do_broker" = "1" ]; then
    phase_section "Remote broker/system services"
    if [ "$remote_available" != "1" ]; then
      echo "  - skipped: SSH unavailable"
    elif [ "$broker_discovered" = "1" ]; then
      echo "  - fieldwork-pr-broker.socket      requires sudo"
      echo "  - fieldwork-pr-approve.socket     requires sudo"
      echo "  - fieldwork-pr-broker.service     requires sudo"
      echo "  - /etc/fieldwork-pr-broker        requires sudo"
      echo "  - /usr/local/lib/fieldwork-pr-broker requires sudo"
      echo "  - /var/lib/fieldwork-pr-broker    requires sudo"
      echo "  - /usr/local/sbin/rotate-pat      requires sudo"
      [ "$purge" = "1" ] && echo "  - broker logs and runtime dirs     requires sudo"
      [ "$remove_system_users" = "1" ] && echo "  - broker system user/group         requires sudo"
    else
      echo "  - none discovered"
    fi
  fi

  if [ "$do_bot" = "1" ]; then
    phase_section "Approval bot"
    if [ "$remote_available" != "1" ]; then
      echo "  - skipped: SSH unavailable"
    elif [ "$bot_discovered" = "1" ]; then
      echo "  - fieldwork-bot.service           requires sudo"
      echo "  - /usr/local/bin/fieldwork-bot    requires sudo"
      echo "  - /etc/fieldwork-bot              requires sudo"
      echo "  - /var/lib/fieldwork-bot          requires sudo"
      [ "$purge" = "1" ] && echo "  - fieldwork-bot log               requires sudo"
      [ "$remove_system_users" = "1" ] && echo "  - bot system user/group           requires sudo"
    else
      echo "  - none discovered"
    fi
  fi

  phase_section "Notification config"
  case "$local_notify_state" in
    marked) echo "  - local ~/.fieldwork/notify.env (Fieldwork-marked)" ;;
    unmarked) echo "  - keep local ~/.fieldwork/notify.env unless explicitly confirmed" ;;
  esac
  case "$remote_notify_state" in
    marked) echo "  - remote ~/.fieldwork/notify.env (Fieldwork-marked)" ;;
    unmarked) echo "  - keep remote ~/.fieldwork/notify.env unless explicitly confirmed" ;;
  esac
  if [ "$local_notify_state" = "absent" ] && [ "$remote_notify_state" = "absent" ]; then
    echo "  - none discovered"
  fi

  echo
  echo "This will NOT remove:"
  echo "  - Your repositories or project checkouts"
  echo "  - GitHub pull requests"
  echo "  - Your SSH keys or non-Fieldwork SSH config"
  echo "  - Your VPS user account"
  echo "  - Docker"
  echo "  - GitHub CLI"
  echo "  - Claude Code"
  echo "  - User-authored Claude config"
}

uninstall_log_status() {
  local status="$1"
  local description="$2"
  local reason="${3:-}"
  local label="$description"
  [ -z "$reason" ] || label="$description ($reason)"
  case "$status" in
    ok)
      [ "${UNINSTALL_QUIET:-0}" = "1" ] && return 0
      if declare -F status_ok_line >/dev/null 2>&1; then
        status_ok_line "$description"
      else
        printf '  [ready] %s\n' "$description"
      fi
      ;;
    skipped)
      [ "${UNINSTALL_QUIET:-0}" = "1" ] && return 0
      if declare -F setup_status_line >/dev/null 2>&1; then
        setup_status_line info "$label"
      else
        printf '  [info] %s\n' "$label"
      fi
      ;;
    failed)
      UNINSTALL_CLEANUP_FAILED=1
      if declare -F setup_status_line >/dev/null 2>&1; then
        setup_status_line blocked "$label"
      else
        printf '  [blocked] %s\n' "$label"
      fi
      ;;
  esac
}

uninstall_ok() {
  uninstall_log_status ok "$1"
}

uninstall_skipped() {
  uninstall_log_status skipped "$1" "$2"
}

uninstall_failed() {
  uninstall_log_status failed "$1" "$2"
}

uninstall_status_start() {
  local message="$1"
  if declare -F fieldwork_status_start >/dev/null 2>&1; then
    fieldwork_status_start "$message"
  fi
}

uninstall_status_succeed() {
  local message="${1:-}"
  if declare -F fieldwork_status_succeed >/dev/null 2>&1; then
    fieldwork_status_succeed "$message"
  elif [ -n "$message" ] && [ "${FIELDWORK_STATUS_QUIET:-0}" != "1" ]; then
    printf '  [ready] %s\n' "$message"
  fi
}

uninstall_status_fail() {
  local message="${1:-}"
  if declare -F fieldwork_status_fail >/dev/null 2>&1; then
    fieldwork_status_fail "$message"
  elif [ -n "$message" ]; then
    printf '  [blocked] %s\n' "$message"
  fi
}

uninstall_status_note() {
  local message="$1"
  if declare -F fieldwork_status_note_line >/dev/null 2>&1; then
    fieldwork_status_note_line "$message"
  elif [ -n "$message" ] && [ "${FIELDWORK_STATUS_QUIET:-0}" != "1" ]; then
    printf '  [info] %s\n' "$message"
  fi
}

uninstall_status_cleanup() {
  if declare -F fieldwork_status_cleanup >/dev/null 2>&1; then
    fieldwork_status_cleanup
  fi
}

uninstall_status_register_cleanup_file() {
  local path="$1"
  if declare -F fieldwork_status_register_cleanup_file >/dev/null 2>&1; then
    fieldwork_status_register_cleanup_file "$path"
  fi
}

uninstall_status_forget_cleanup_file() {
  local path="$1"
  if declare -F fieldwork_status_forget_cleanup_file >/dev/null 2>&1; then
    fieldwork_status_forget_cleanup_file "$path"
  fi
}

uninstall_status_check() {
  local message="$1"
  shift
  if declare -F fieldwork_status_check >/dev/null 2>&1; then
    fieldwork_status_check "$message" "$@"
  else
    "$@" >/dev/null 2>&1
  fi
}

uninstall_replay_captured_log() {
  local log_file="$1"
  local line label
  [ -s "$log_file" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "  ok       "*)
        uninstall_ok "${line#  ok       }"
        ;;
      "  skipped  "*)
        label="${line#  skipped  }"
        [ "${UNINSTALL_QUIET:-0}" = "1" ] && continue
        if declare -F setup_status_line >/dev/null 2>&1; then
          setup_status_line info "$label"
        else
          printf '  [info] %s\n' "$label"
        fi
        ;;
      "  failed   "*)
        label="${line#  failed   }"
        UNINSTALL_CLEANUP_FAILED=1
        if declare -F setup_status_line >/dev/null 2>&1; then
          setup_status_line blocked "$label"
        else
          printf '  [blocked] %s\n' "$label"
        fi
        ;;
      *)
        printf '    %s\n' "$line"
        ;;
    esac
  done <"$log_file"
}

uninstall_run_captured() {
  local pending_message="$1"
  local success_message="$2"
  local failure_message="$3"
  shift 3
  local log_file status

  log_file="$(mktemp "${TMPDIR:-/tmp}/fieldwork-uninstall-status.XXXXXX")" || {
    uninstall_status_fail "$failure_message"
    return 1
  }
  uninstall_status_register_cleanup_file "$log_file"

  uninstall_status_start "$pending_message"
  set +e
  "$@" >"$log_file" 2>&1
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    uninstall_status_succeed ""
    uninstall_replay_captured_log "$log_file"
    uninstall_status_forget_cleanup_file "$log_file"
    rm -f -- "$log_file"
    uninstall_ok "$success_message"
    return 0
  fi

  uninstall_status_fail ""
  uninstall_replay_captured_log "$log_file"
  uninstall_status_forget_cleanup_file "$log_file"
  rm -f -- "$log_file"
  uninstall_failed "$failure_message" "command failed"
  return "$status"
}

uninstall_remove_file_path() {
  local description="$1"
  local path="$2"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    uninstall_skipped "$description" "not present"
    return 0
  fi
  if rm -f -- "$path"; then
    uninstall_ok "$description"
  else
    uninstall_failed "$description" "rm failed"
    return 1
  fi
}

uninstall_remove_tree_path() {
  local description="$1"
  local path="$2"
  local prefix="$3"
  if [ -z "$path" ] || [ -z "$prefix" ]; then
    uninstall_failed "$description" "empty path guard"
    return 1
  fi
  case "$path" in
    "$prefix"|"$prefix"/*) ;;
    *) uninstall_failed "$description" "outside expected prefix"; return 1 ;;
  esac
  if [ ! -e "$path" ]; then
    uninstall_skipped "$description" "not present"
    return 0
  fi
  if rm -rf -- "$path"; then
    uninstall_ok "$description"
  else
    uninstall_failed "$description" "rm failed"
    return 1
  fi
}

uninstall_symlink_target_abs() {
  local path="$1"
  local target
  target="$(readlink "$path" 2>/dev/null || true)"
  [ -n "$target" ] || return 1
  case "$target" in
    /*) printf '%s\n' "$target" ;;
    *) printf '%s/%s\n' "$(cd -P "$(dirname "$path")" && pwd)" "$target" ;;
  esac
}

uninstall_path_in_dir() {
  local path="$1"
  local dir="$2"
  case "$path" in
    "$dir"|"$dir"/*) return 0 ;;
    *) return 1 ;;
  esac
}

uninstall_is_fieldwork_symlink() {
  local path="$1"
  [ -L "$path" ] || return 1
  local target
  target="$(uninstall_symlink_target_abs "$path")" || return 1
  if uninstall_path_in_dir "$target" "$FIELDWORK_ROOT"; then
    return 0
  fi
  case "$target" in
    "$HOME/.fieldwork/scripts/"fieldwork-*|"$HOME/.fieldwork/scripts/notify.sh")
      [ -L "$target" ] || return 1
      local nested
      nested="$(uninstall_symlink_target_abs "$target")" || return 1
      uninstall_path_in_dir "$nested" "$FIELDWORK_ROOT"
      ;;
    *) return 1 ;;
  esac
}

uninstall_remove_fieldwork_symlink() {
  local path="$1"
  local description
  description="$(display_local_path "$path")"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    uninstall_skipped "$description" "not present"
    return 0
  fi
  if uninstall_is_fieldwork_symlink "$path"; then
    if rm -f -- "$path"; then
      uninstall_ok "$description"
    else
      uninstall_failed "$description" "rm failed"
      return 1
    fi
  else
    uninstall_skipped "$description" "not a Fieldwork-managed symlink"
  fi
}

uninstall_recorded_authorized_key_field() {
  local key="$1"
  local record="$HOME/.config/fieldwork/authorized-key.env"
  [ -f "$record" ] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "")
      print
      found = 1
      exit
    }
    END { exit found ? 0 : 1 }
  ' "$record"
}

uninstall_capture_marked_ssh_block() {
  local config="$1"
  local begin="$2"
  local end="$3"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { capture = 1 }
    capture { print }
    $0 == end && capture { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$config"
}

uninstall_capture_local_ssh_alias_block() {
  local config="$HOME/.ssh/config"
  local alias="${FIELDWORK_SSH_HOST:-}"
  local block_file status
  [ -n "$alias" ] || return 1
  [ -f "$config" ] || return 1
  [ ! -L "$config" ] || return 1

  if uninstall_capture_marked_ssh_block "$config" "# BEGIN FIELDWORK SSH CONFIG: $alias" "# END FIELDWORK SSH CONFIG: $alias"; then
    return 0
  fi
  if uninstall_capture_marked_ssh_block "$config" "# Fieldwork managed: $alias" "# End Fieldwork managed: $alias"; then
    return 0
  fi

  block_file="$(mktemp "${TMPDIR:-/tmp}/fieldwork-ssh-block.XXXXXX")" || return 1
  set +e
  uninstall_extract_ssh_host_block "$config" "$alias" >"$block_file"
  status=$?
  set -e
  if [ "$status" -eq 0 ] || [ "$status" -eq 2 ]; then
    cat "$block_file"
    rm -f "$block_file"
    return 0
  fi
  rm -f "$block_file"
  return 1
}

uninstall_ssh_block_value() {
  local key="$1"
  awk -v key="$key" '
    tolower($1) == tolower(key) && NF >= 2 {
      print $2
      found = 1
      exit
    }
    END { exit found ? 0 : 1 }
  '
}

uninstall_direct_ssh_target() {
  local alias_block="$1"
  local recorded_host="$2"
  local recorded_remote_user="$3"
  local host=""
  local remote_user=""

  if [ -n "$alias_block" ]; then
    host="$(printf '%s\n' "$alias_block" | uninstall_ssh_block_value HostName 2>/dev/null || true)"
    remote_user="$(printf '%s\n' "$alias_block" | uninstall_ssh_block_value User 2>/dev/null || true)"
    if [ -n "$host" ]; then
      printf '%s@%s\n' "${remote_user:-$FIELDWORK_REMOTE_USER}" "$host"
      return 0
    fi
  fi

  if [ -n "$recorded_host" ]; then
    printf '%s@%s\n' "${recorded_remote_user:-$FIELDWORK_REMOTE_USER}" "$recorded_host"
    return 0
  fi

  return 1
}

uninstall_detect_public_ssh_rule() {
  local ufw_status_file status
  UNINSTALL_PUBLIC_SSH_RULE_STATE="unknown"
  ufw_status_file="$(mktemp "${TMPDIR:-/tmp}/fieldwork-uninstall-ufw.XXXXXX")" || return 0
  uninstall_status_register_cleanup_file "$ufw_status_file"

  uninstall_status_start "checking public SSH firewall rules"
  set +e
  ssh "$FIELDWORK_SSH_HOST" "sudo -n ufw status 2>/dev/null" >"$ufw_status_file" 2>/dev/null
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    uninstall_status_succeed ""
  else
    uninstall_status_fail ""
  fi

  if [ "$status" -ne 0 ] || [ ! -s "$ufw_status_file" ]; then
    uninstall_status_forget_cleanup_file "$ufw_status_file"
    rm -f -- "$ufw_status_file"
    return 0
  fi
  if grep -Ei '^[[:space:]]*22/tcp[[:space:]]+ALLOW' "$ufw_status_file" |
    grep -Eiv '(on[[:space:]]+(tailscale|wg|tun)[0-9]*|(^|[^0-9.])(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.))' >/dev/null; then
    UNINSTALL_PUBLIC_SSH_RULE_STATE="present"
  else
    UNINSTALL_PUBLIC_SSH_RULE_STATE="absent"
  fi
  uninstall_status_forget_cleanup_file "$ufw_status_file"
  rm -f -- "$ufw_status_file"
  return 0
}

print_uninstall_manual_checklist() {
  local ssh_target="$1"
  local remote_user="$2"
  local authorized_key_fingerprint="$3"
  local authorized_key_public_key="$4"
  local authorized_key_host="$5"
  local authorized_key_remote_user="$6"
  local local_ssh_alias_block="$7"
  local ufw_public_ssh_rule_state="$8"
  local ssh_alias="${9}"
  local ssh_target_note="${10}"
  local ssh_target_placeholder_note="${11}"
  local public_key_remove_command=""

  phase_section "Manual cleanup still outside Fieldwork uninstall"
  if [ -n "$ssh_target_note" ]; then
    status_info_line "$ssh_target_note"
  fi
  if [ -n "$ssh_target_placeholder_note" ]; then
    status_info_line "$ssh_target_placeholder_note"
  fi
  setup_status_line manual "GitHub broker PAT"
  echo "      Open https://github.com/settings/personal-access-tokens"
  echo "      Revoke any Fieldwork broker token, usually named fieldwork-broker or fieldwork-*."
  setup_status_line manual "Telegram approval bot"
  echo "      Open https://t.me/BotFather"
  echo "      Send /deletebot and choose the Fieldwork approval bot."
  setup_status_line manual "VPS authorized_keys entry"
  if [ -n "$authorized_key_fingerprint" ]; then
    echo "      Recorded fingerprint: $authorized_key_fingerprint"
  else
    echo "      Recorded fingerprint: not recorded by this install."
  fi
  if [ -n "$authorized_key_host" ] || [ -n "$authorized_key_remote_user" ]; then
    echo "      Recorded target: ${authorized_key_remote_user:-$remote_user}@${authorized_key_host:-$ssh_alias}"
  fi
  echo "      Inspect: ssh $ssh_target 'ssh-keygen -lf ~/.ssh/authorized_keys'"
  if [ -n "$authorized_key_public_key" ]; then
    public_key_remove_command="key=$(shell_quote "$authorized_key_public_key"); tmp=\$(mktemp ~/.ssh/authorized_keys.fieldwork.XXXXXX) && grep -Fvx -- \"\$key\" ~/.ssh/authorized_keys > \"\$tmp\" && cat \"\$tmp\" > ~/.ssh/authorized_keys && rm -f \"\$tmp\""
    printf '      Remove recorded key: ssh %s %s\n' "$ssh_target" "$(shell_double_quote "$public_key_remove_command")"
  else
    echo "      Remove the Fieldwork setup key from ~/.ssh/authorized_keys manually."
  fi
  setup_status_line manual "Local SSH alias"
  if [ -n "$local_ssh_alias_block" ]; then
    echo "      If you kept or restored the alias for manual access, remove this block from ~/.ssh/config:"
    printf '%s\n' "$local_ssh_alias_block" | sed 's/^/        /'
  else
    echo "      No $ssh_alias block was found in ~/.ssh/config during uninstall."
  fi
  setup_status_line manual "VPS host firewall rule"
  case "$ufw_public_ssh_rule_state" in
    present) echo "      Detected: public 22/tcp ALLOW rule appears present in ufw." ;;
    absent) echo "      Detected: no obvious public 22/tcp ALLOW rule in ufw." ;;
    unknown) echo "      Detected: could not inspect ufw with non-interactive sudo." ;;
    *) echo "      Detected: $ufw_public_ssh_rule_state." ;;
  esac
  echo "      Inspect: ssh -t $ssh_target 'sudo ufw status numbered'"
  echo "      Remove public SSH allow if you no longer need it:"
  echo "        ssh -t $ssh_target 'sudo ufw delete allow 22/tcp'"
  setup_status_line manual "VPS provider firewall/security group"
  echo "      Remove any inbound TCP/22 rule for this VPS in your cloud provider console."
  echo "      No in-box command can remove provider-side firewall rules."
  setup_status_line manual "VPS Linux user account"
  echo "      Warning: Fieldwork bootstrap disables root SSH. If you remove this user,"
  echo "      future setup on this VPS needs root SSH, another sudo-capable account,"
  echo "      or provider console/rescue mode to recreate it."
  echo "      From root or another sudo-capable account on the VPS, run:"
  printf '        sudo userdel -r %s\n' "$remote_user"
  printf '        sudo groupdel %s 2>/dev/null || true\n' "$remote_user"
}

uninstall_extract_ssh_host_block() {
  local config="$1"
  local alias="$2"
  awk -v alias="$alias" '
    function is_host_line() {
      return tolower($1) == "host"
    }
    function host_matches(  i) {
      if (!is_host_line()) return 0
      for (i = 2; i <= NF; i++) {
        if ($i == alias) return 1
      }
      return 0
    }
    !found && host_matches() {
      found = 1
      in_block = 1
      print
      next
    }
    in_block {
      if ($0 ~ /^[[:space:]]*$/) {
        print
        in_block = 0
        exit
      }
      if (is_host_line()) {
        next_host = 1
        in_block = 0
        exit
      }
      print
    }
    END {
      if (!found) exit 1
      if (next_host) exit 2
      exit 0
    }
  ' "$config"
}

uninstall_ssh_block_is_exact_generated() {
  local block_file="$1"
  local alias="$2"
  local remote_user="$3"
  awk -v alias="$alias" -v remote_user="$remote_user" '
    BEGIN {
      ok = 1
      host = 0
      hostname = 0
      user = 0
      identity = 0
      identities = 0
    }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { ok = 0; next }
    NR == 1 {
      if (tolower($1) != "host" || NF != 2 || $2 != alias) ok = 0
      host = 1
      next
    }
    {
      key = tolower($1)
      if (NF != 2) ok = 0
      if (key == "hostname") hostname++
      else if (key == "user" && $2 == remote_user) user++
      else if (key == "identityfile") identity++
      else if (key == "identitiesonly" && tolower($2) == "yes") identities++
      else ok = 0
    }
    END {
      if (ok && host == 1 && hostname == 1 && user == 1 && identity == 1 && identities == 1) exit 0
      exit 1
    }
  ' "$block_file"
}

uninstall_remove_ssh_host_block() {
  local config="$1"
  local alias="$2"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/fieldwork-ssh-config.XXXXXX")" || return 1
  awk -v alias="$alias" '
    function is_host_line() {
      return tolower($1) == "host"
    }
    function host_matches(  i) {
      if (!is_host_line()) return 0
      for (i = 2; i <= NF; i++) {
        if ($i == alias) return 1
      }
      return 0
    }
    skip {
      if ($0 ~ /^[[:space:]]*$/) {
        skip = 0
      }
      next
    }
    host_matches() {
      skip = 1
      removed = 1
      next
    }
    { print }
    END { exit removed ? 0 : 1 }
  ' "$config" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$config"
}

uninstall_remove_marked_ssh_block() {
  local config="$1"
  local begin="$2"
  local end="$3"
  local tmp
  grep -Fxq "$begin" "$config" 2>/dev/null || return 1
  grep -Fxq "$end" "$config" 2>/dev/null || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/fieldwork-ssh-config.XXXXXX")" || return 1
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skip = 1; removed = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
    END { exit removed ? 0 : 1 }
  ' "$config" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$config"
}

uninstall_remove_marked_github_ssh_blocks() {
  local config="$1"
  local tmp
  local description="Fieldwork GitHub SSH aliases"
  [ -f "$config" ] || { uninstall_skipped "$description" "ssh config not present"; return 0; }
  [ ! -L "$config" ] || { uninstall_skipped "$description" "ssh config is a symlink"; return 0; }
  grep -Fq "# BEGIN FIELDWORK GITHUB SSH CONFIG:" "$config" 2>/dev/null || { uninstall_skipped "$description" "not present"; return 0; }
  grep -Fq "# END FIELDWORK GITHUB SSH CONFIG:" "$config" 2>/dev/null || { uninstall_skipped "$description" "incomplete marker"; return 0; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/fieldwork-ssh-config.XXXXXX")" || { uninstall_failed "$description" "mktemp failed"; return 1; }
  awk '
    in_block {
      block = block $0 ORS
      if ($0 ~ /^# END FIELDWORK GITHUB SSH CONFIG: /) {
        in_block = 0
        block = ""
        removed = 1
      }
      next
    }
    /^# BEGIN FIELDWORK GITHUB SSH CONFIG: / {
      in_block = 1
      block = $0 ORS
      next
    }
    { print }
    END {
      if (in_block) printf "%s", block
      exit removed ? 0 : 1
    }
  ' "$config" >"$tmp" || { rm -f "$tmp"; uninstall_failed "$description" "rewrite failed"; return 1; }
  if mv "$tmp" "$config"; then
    uninstall_ok "$description"
  else
    rm -f "$tmp"
    uninstall_failed "$description" "mv failed"
    return 1
  fi
}

uninstall_remove_local_ssh_alias() {
  local config="$HOME/.ssh/config"
  local alias="${FIELDWORK_SSH_HOST:-}"
  local block block_file status
  local description="local SSH alias ${alias:-FIELDWORK_SSH_HOST}"
  [ -n "$alias" ] || { uninstall_skipped "$description" "FIELDWORK_SSH_HOST unset"; return 0; }
  [ -f "$config" ] || { uninstall_skipped "$description" "ssh config not present"; return 0; }
  [ ! -L "$config" ] || {
    uninstall_skipped "$description" "ssh config is a symlink"
    echo "  manual local SSH config is a symlink; inspect $(display_local_path "$config") before editing"
    return 0
  }

  if uninstall_remove_marked_ssh_block "$config" "# BEGIN FIELDWORK SSH CONFIG: $alias" "# END FIELDWORK SSH CONFIG: $alias"; then
    uninstall_ok "$description"
    return 0
  fi
  if uninstall_remove_marked_ssh_block "$config" "# Fieldwork managed: $alias" "# End Fieldwork managed: $alias"; then
    uninstall_ok "$description"
    return 0
  fi

  block_file="$(mktemp "${TMPDIR:-/tmp}/fieldwork-ssh-block.XXXXXX")" || { uninstall_failed "$description" "mktemp failed"; return 1; }
  set +e
  uninstall_extract_ssh_host_block "$config" "$alias" >"$block_file"
  status=$?
  set -e
  if [ "$status" -eq 0 ] && uninstall_ssh_block_is_exact_generated "$block_file" "$alias" "$FIELDWORK_REMOTE_USER"; then
    if uninstall_remove_ssh_host_block "$config" "$alias"; then
      uninstall_ok "$description"
    else
      uninstall_failed "$description" "rewrite failed"
      rm -f "$block_file"
      return 1
    fi
    rm -f "$block_file"
    return 0
  fi
  if [ "$status" -eq 0 ] || [ "$status" -eq 2 ]; then
    block="$(cat "$block_file")"
    uninstall_skipped "$description" "custom block requires manual removal"
    echo "  manual local SSH alias kept; remove this block from ~/.ssh/config if you do not want it:"
    printf '%s\n' "$block" | sed 's/^/    /'
  else
    uninstall_skipped "$description" "not present"
  fi
  rm -f "$block_file"
}

uninstall_local_files() {
  local purge="$1"
  local remove_notify="$2"
  local script

  for script in \
    "$HOME/.local/bin/fieldwork" \
    "$HOME/.local/bin/fieldwork-verify" \
    "$HOME/.local/bin/fieldwork-verify-runner" \
    "$HOME/.local/bin/fieldwork-pr-prepare" \
    "$HOME/.local/bin/fieldwork-pr-prepare-runner" \
    "$HOME/.local/bin/fieldwork-setup-probe" \
    "$HOME/.local/bin/fieldwork-codex-sandbox" \
    "$HOME/.local/bin/fieldwork-pr-submit" \
    "$HOME/.fieldwork/scripts/fieldwork-status-snapshot" \
    "$HOME/.fieldwork/scripts/fieldwork-dashboard-server" \
    "$HOME/.fieldwork/scripts/fieldwork-clone" \
    "$HOME/.fieldwork/scripts/fieldwork-init" \
    "$HOME/.fieldwork/scripts/fieldwork-launch" \
    "$HOME/.fieldwork/scripts/fieldwork-pr-submit" \
    "$HOME/.fieldwork/scripts/fieldwork-agent-session" \
    "$HOME/.fieldwork/scripts/fieldwork-event-poll" \
    "$HOME/.fieldwork/scripts/fieldwork-setup-probe" \
    "$HOME/.fieldwork/scripts/fieldwork-codex-sandbox" \
    "$HOME/.fieldwork/scripts/fieldwork-verify" \
    "$HOME/.fieldwork/scripts/fieldwork-verify-runner" \
    "$HOME/.fieldwork/scripts/fieldwork-verify-pipeline" \
    "$HOME/.fieldwork/scripts/fieldwork-pr-prepare" \
    "$HOME/.fieldwork/scripts/fieldwork-pr-prepare-runner" \
    "$HOME/.fieldwork/scripts/fieldwork-pr-prepare-impl" \
    "$HOME/.fieldwork/scripts/notify.sh" \
    "$HOME/.claude/CLAUDE.md" \
    "$HOME/.claude/settings.json" \
    "$HOME/.fieldwork/templates/repo" \
    "$HOME/.fieldwork/infra/fieldwork-agent@.service" \
    "$HOME/.fieldwork/infra/fieldwork-dashboard.service" \
    "$HOME/.fieldwork/infra/fieldwork-verify-runner.socket" \
    "$HOME/.fieldwork/infra/fieldwork-verify-runner@.service" \
    "$HOME/.fieldwork/infra/fieldwork-event-poll.service" \
    "$HOME/.fieldwork/infra/fieldwork-event-poll.timer" \
    "$HOME/.fieldwork/infra/fieldwork-pr-prepare-runner.socket" \
    "$HOME/.fieldwork/infra/fieldwork-pr-prepare-runner@.service" \
    "$HOME/.fieldwork/infra/agents" \
    "$HOME/.fieldwork/infra/fieldwork-pr-broker"; do
    uninstall_remove_fieldwork_symlink "$script"
  done
  uninstall_remove_marked_github_ssh_blocks "$HOME/.ssh/config"

  uninstall_remove_tree_path "local Fieldwork config" "$HOME/.config/fieldwork" "$HOME"
  if [ "$remove_notify" = "1" ]; then
    uninstall_remove_file_path "local notify.env" "$HOME/.fieldwork/notify.env"
  else
    uninstall_skipped "local notify.env" "not Fieldwork-marked or not confirmed"
  fi
  uninstall_remove_file_path "local configured agents" "$HOME/.fieldwork/agents"
  uninstall_remove_file_path "local Claude login confirmation" "$HOME/.fieldwork/state/claude-login-confirmed"
  uninstall_remove_file_path "local Codex login confirmation" "$HOME/.fieldwork/state/codex-login-confirmed"
  uninstall_remove_file_path "local broker PAT confirmation" "$HOME/.fieldwork/state/broker-pat-confirmed"
  uninstall_remove_tree_path "local project journals" "$HOME/.fieldwork/project-journals" "$HOME"
  rmdir "$HOME/.fieldwork/state" "$HOME/.fieldwork/scripts" "$HOME/.fieldwork/infra" "$HOME/.fieldwork/templates" "$HOME/.fieldwork" 2>/dev/null || true
  if [ "$purge" = "1" ]; then
    uninstall_remove_tree_path "local Fieldwork cache" "$HOME/.cache/fieldwork" "$HOME"
    uninstall_remove_tree_path "local Fieldwork state" "$HOME/.local/state/fieldwork" "$HOME"
    uninstall_remove_tree_path "local PR prepare state" "$HOME/.local/state/fieldwork-pr-prepare" "$HOME"
  fi
}

uninstall_local_ssh_alias() {
  uninstall_remove_local_ssh_alias || true
}

uninstall_remote_user() {
  local purge="$1"
  local remove_notify="$2"
  local remove_temp_sudo="${3:-1}"
  ssh "$FIELDWORK_SSH_HOST" "FIELDWORK_UNINSTALL_PURGE=$purge FIELDWORK_UNINSTALL_REMOVE_NOTIFY=$remove_notify FIELDWORK_UNINSTALL_REMOVE_TEMP_SUDO=$remove_temp_sudo FIELDWORK_UNINSTALL_QUIET=${UNINSTALL_QUIET:-0} bash -s" <<'REMOTE'
set -eu
ROOT="$HOME/fieldwork"

log_status() {
  status="$1"
  description="$2"
  reason="${3:-}"
  case "$status" in
    ok)
      [ "${FIELDWORK_UNINSTALL_QUIET:-0}" = "1" ] && return 0
      printf '  %-8s %s\n' "ok" "$description"
      ;;
    skipped)
      [ "${FIELDWORK_UNINSTALL_QUIET:-0}" = "1" ] && return 0
      printf '  %-8s %s (%s)\n' "skipped" "$description" "$reason"
      ;;
    failed)
      printf '  %-8s %s (%s)\n' "failed" "$description" "$reason"
      ;;
  esac
}

ok() { log_status ok "$1"; }
skipped() { log_status skipped "$1" "$2"; }
failed() { log_status failed "$1" "$2"; }

target_abs() {
  path="$1"
  target="$(readlink "$path" 2>/dev/null || true)"
  [ -n "$target" ] || return 1
  case "$target" in
    /*) printf '%s\n' "$target" ;;
    *) printf '%s/%s\n' "$(cd -P "$(dirname "$path")" && pwd)" "$target" ;;
  esac
}

in_root() {
  case "$1" in
    "$ROOT"|"$ROOT"/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_fieldwork_symlink() {
  path="$1"
  [ -L "$path" ] || return 1
  target="$(target_abs "$path")" || return 1
  if in_root "$target"; then
    return 0
  fi
  case "$target" in
    "$HOME/.fieldwork/scripts/"fieldwork-*|"$HOME/.fieldwork/scripts/notify.sh")
      [ -L "$target" ] || return 1
      nested="$(target_abs "$target")" || return 1
      in_root "$nested"
      ;;
    *) return 1 ;;
  esac
}

remove_symlink() {
  path="$1"
  description="$2"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    skipped "$description" "not present"
    return 0
  fi
  if is_fieldwork_symlink "$path"; then
    if rm -f -- "$path"; then
      ok "$description"
    else
      failed "$description" "rm failed"
      return 1
    fi
  else
    skipped "$description" "not a Fieldwork-managed symlink"
  fi
}

remove_file() {
  description="$1"
  path="$2"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    skipped "$description" "not present"
    return 0
  fi
  if rm -f -- "$path"; then
    ok "$description"
  else
    failed "$description" "rm failed"
    return 1
  fi
}

remove_tree() {
  description="$1"
  path="$2"
  prefix="$3"
  if [ -z "$path" ] || [ -z "$prefix" ]; then
    failed "$description" "empty path guard"
    return 1
  fi
  case "$path" in
    "$prefix"|"$prefix"/*) ;;
    *) failed "$description" "outside expected prefix"; return 1 ;;
  esac
  if [ ! -e "$path" ]; then
    skipped "$description" "not present"
    return 0
  fi
  if rm -rf -- "$path"; then
    ok "$description"
  else
    failed "$description" "rm failed"
    return 1
  fi
}

remove_fieldwork_profile_path() {
  profile="$HOME/.profile"
  [ -f "$profile" ] || { skipped "remote ~/.profile PATH block" "not present"; return 0; }
  if ! grep -Fxq "# Fieldwork local bin" "$profile" 2>/dev/null; then
    skipped "remote ~/.profile PATH block" "not present"
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/fieldwork-profile.XXXXXX")" || { failed "remote ~/.profile PATH block" "mktemp failed"; return 1; }
  awk '
    skip == 1 {
      if ($0 == "export PATH=\"$HOME/.local/bin:$PATH\"") {
        skip = 0
        next
      }
      print "# Fieldwork local bin"
      skip = 0
    }
    $0 == "# Fieldwork local bin" {
      skip = 1
      next
    }
    { print }
    END {
      if (skip == 1) print "# Fieldwork local bin"
    }
  ' "$profile" >"$tmp" && mv "$tmp" "$profile" && ok "remote ~/.profile PATH block" || {
    rm -f "$tmp"
    failed "remote ~/.profile PATH block" "rewrite failed"
    return 1
  }
}

remove_user_systemd_links() {
  count=0
  for dir in "$HOME/.config/systemd/user/default.target.wants" "$HOME/.config/systemd/user/sockets.target.wants"; do
    [ -d "$dir" ] || continue
    while IFS= read -r link; do
      [ -n "$link" ] || continue
      if rm -f -- "$link"; then
        count=$((count + 1))
      else
        failed "remote user systemd wants links" "rm failed"
        return 1
      fi
    done <<EOF
$(find "$dir" -maxdepth 1 -type l \( -name 'fieldwork-*.service' -o -name 'fieldwork-*.socket' \) -print 2>/dev/null)
EOF
  done
  if [ "$count" -gt 0 ]; then
    ok "remote user systemd wants links"
  else
    skipped "remote user systemd wants links" "not present"
  fi
}

if systemctl --user disable --now fieldwork-verify-runner.socket fieldwork-pr-prepare-runner.socket fieldwork-event-poll.timer fieldwork-dashboard.service >/dev/null 2>&1; then
  ok "remote user runner sockets, event timer, and dashboard"
elif [ -f "$HOME/.config/systemd/user/fieldwork-verify-runner.socket" ] || [ -f "$HOME/.config/systemd/user/fieldwork-pr-prepare-runner.socket" ] || [ -f "$HOME/.config/systemd/user/fieldwork-event-poll.timer" ] || [ -f "$HOME/.config/systemd/user/fieldwork-dashboard.service" ]; then
  failed "remote user runner sockets, event timer, and dashboard" "systemctl failed"
else
  skipped "remote user runner sockets, event timer, and dashboard" "not present"
fi
agents_tmp="$(mktemp "${TMPDIR:-/tmp}/fieldwork-uninstall-agents.XXXXXX")" || agents_tmp=""
if [ -n "$agents_tmp" ] && systemctl --user list-units --all 'fieldwork-agent@*.service' --no-legend --no-pager >"$agents_tmp" 2>/dev/null; then
  if [ -s "$agents_tmp" ]; then
    while read -r unit _; do
      [ -n "$unit" ] || continue
      case "$unit" in
        fieldwork-agent@*.service)
          if systemctl --user disable --now "$unit" >/dev/null 2>&1; then
            ok "remote user $unit"
          else
            failed "remote user $unit" "systemctl failed"
          fi
          ;;
      esac
    done <"$agents_tmp"
  else
    skipped "remote user agent sessions" "not present"
  fi
else
  skipped "remote user agent sessions" "systemd user unavailable"
fi
[ -z "$agents_tmp" ] || rm -f "$agents_tmp"
remove_user_systemd_links
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
case "$runtime_dir" in
  /run/user/*)
    remove_file "remote verify runtime socket" "$runtime_dir/fieldwork-verify.sock"
    remove_file "remote PR prepare runtime socket" "$runtime_dir/fieldwork-pr-prepare.sock"
    ;;
  *) skipped "remote runtime sockets" "runtime dir outside /run/user" ;;
esac

for path in \
  "$HOME/.local/bin/fieldwork" \
  "$HOME/.local/bin/fieldwork-verify" \
  "$HOME/.local/bin/fieldwork-verify-runner" \
  "$HOME/.local/bin/fieldwork-pr-prepare" \
  "$HOME/.local/bin/fieldwork-pr-prepare-runner" \
  "$HOME/.local/bin/fieldwork-setup-probe" \
  "$HOME/.local/bin/fieldwork-codex-sandbox" \
  "$HOME/.local/bin/fieldwork-pr-submit" \
  "$HOME/.fieldwork/scripts/fieldwork-status-snapshot" \
  "$HOME/.fieldwork/scripts/fieldwork-dashboard-server" \
  "$HOME/.fieldwork/scripts/fieldwork-clone" \
  "$HOME/.fieldwork/scripts/fieldwork-init" \
  "$HOME/.fieldwork/scripts/fieldwork-launch" \
  "$HOME/.fieldwork/scripts/fieldwork-pr-submit" \
  "$HOME/.fieldwork/scripts/fieldwork-agent-session" \
  "$HOME/.fieldwork/scripts/fieldwork-event-poll" \
  "$HOME/.fieldwork/scripts/fieldwork-setup-probe" \
  "$HOME/.fieldwork/scripts/fieldwork-codex-sandbox" \
  "$HOME/.fieldwork/scripts/fieldwork-verify" \
  "$HOME/.fieldwork/scripts/fieldwork-verify-runner" \
  "$HOME/.fieldwork/scripts/fieldwork-verify-pipeline" \
  "$HOME/.fieldwork/scripts/fieldwork-pr-prepare" \
  "$HOME/.fieldwork/scripts/fieldwork-pr-prepare-runner" \
  "$HOME/.fieldwork/scripts/fieldwork-pr-prepare-impl" \
  "$HOME/.fieldwork/scripts/notify.sh" \
  "$HOME/.claude/CLAUDE.md" \
  "$HOME/.claude/settings.json" \
  "$HOME/.fieldwork/templates/repo" \
  "$HOME/.fieldwork/infra/fieldwork-agent@.service" \
  "$HOME/.fieldwork/infra/fieldwork-dashboard.service" \
  "$HOME/.fieldwork/infra/fieldwork-verify-runner.socket" \
  "$HOME/.fieldwork/infra/fieldwork-verify-runner@.service" \
  "$HOME/.fieldwork/infra/fieldwork-event-poll.service" \
  "$HOME/.fieldwork/infra/fieldwork-event-poll.timer" \
  "$HOME/.fieldwork/infra/fieldwork-pr-prepare-runner.socket" \
  "$HOME/.fieldwork/infra/fieldwork-pr-prepare-runner@.service" \
  "$HOME/.fieldwork/infra/agents" \
  "$HOME/.fieldwork/infra/fieldwork-pr-broker"; do
  remove_symlink "$path" "remote $path"
done

remove_file "remote fieldwork-agent unit" "$HOME/.config/systemd/user/fieldwork-agent@.service"
remove_file "remote dashboard unit" "$HOME/.config/systemd/user/fieldwork-dashboard.service"
remove_tree "remote dashboard unit drop-ins" "$HOME/.config/systemd/user/fieldwork-dashboard.service.d" "$HOME"
remove_file "remote verify socket unit" "$HOME/.config/systemd/user/fieldwork-verify-runner.socket"
remove_file "remote verify service unit" "$HOME/.config/systemd/user/fieldwork-verify-runner@.service"
remove_file "remote event poll service unit" "$HOME/.config/systemd/user/fieldwork-event-poll.service"
remove_file "remote event poll timer unit" "$HOME/.config/systemd/user/fieldwork-event-poll.timer"
remove_file "remote PR prepare socket unit" "$HOME/.config/systemd/user/fieldwork-pr-prepare-runner.socket"
remove_file "remote PR prepare service unit" "$HOME/.config/systemd/user/fieldwork-pr-prepare-runner@.service"
remove_file "remote Claude login confirmation" "$HOME/.fieldwork/state/claude-login-confirmed"
remove_file "remote Codex login confirmation" "$HOME/.fieldwork/state/codex-login-confirmed"
remove_file "remote broker PAT confirmation" "$HOME/.fieldwork/state/broker-pat-confirmed"
remove_file "remote configured agents" "$HOME/.fieldwork/agents"

remove_tree "remote Fieldwork config" "$HOME/.config/fieldwork" "$HOME"
remove_tree "remote project journals" "$HOME/.fieldwork/project-journals" "$HOME"
remove_tree "remote Fieldwork checkout" "$HOME/fieldwork" "$HOME"
if [ "${FIELDWORK_UNINSTALL_REMOVE_NOTIFY:-0}" = "1" ]; then
  remove_file "remote notify.env" "$HOME/.fieldwork/notify.env"
else
  skipped "remote notify.env" "not Fieldwork-marked or not confirmed"
fi
rmdir "$HOME/.fieldwork/state" "$HOME/.fieldwork/scripts" "$HOME/.fieldwork/infra" "$HOME/.fieldwork/templates" "$HOME/.fieldwork" 2>/dev/null || true
remove_fieldwork_profile_path
agent_user="$(id -un)"
have_sudo=0
if sudo -n true >/dev/null 2>&1; then
  have_sudo=1
fi
sudoers="/etc/sudoers.d/fieldwork-$agent_user"
case "$sudoers" in
  /etc/sudoers.d/fieldwork-?*)
    if [ "${FIELDWORK_UNINSTALL_REMOVE_TEMP_SUDO:-1}" != "1" ]; then
      skipped "temporary sudoers rule" "deferred until system cleanup"
    elif [ "$have_sudo" = "1" ]; then
      if sudo -n test -e "$sudoers" 2>/dev/null; then
        if sudo -n rm -f -- "$sudoers" 2>/dev/null; then
          ok "temporary sudoers rule"
        else
          failed "temporary sudoers rule" "rm failed"
        fi
      else
        skipped "temporary sudoers rule" "not present"
      fi
    else
      skipped "temporary sudoers rule" "sudo unavailable"
    fi
    ;;
esac
if [ "${FIELDWORK_UNINSTALL_PURGE:-0}" = "1" ]; then
  remove_tree "remote Fieldwork cache" "$HOME/.cache/fieldwork" "$HOME"
  remove_tree "remote Fieldwork state" "$HOME/.local/state/fieldwork" "$HOME"
  remove_tree "remote PR prepare state" "$HOME/.local/state/fieldwork-pr-prepare" "$HOME"
  if [ "$have_sudo" = "1" ]; then
    if sudo -n loginctl disable-linger "$agent_user" >/dev/null 2>&1; then
      ok "remote user linger"
    else
      failed "remote user linger" "loginctl failed"
    fi
    apparmor_reload_needed=0
    remove_apparmor_profile() {
      local label="$1" path="$2"
      if sudo -n test -f "$path" 2>/dev/null; then
        if sudo -n rm -f "$path" 2>/dev/null; then
          ok "$label"
          apparmor_reload_needed=1
        else
          failed "$label" "rm failed"
        fi
      else
        skipped "$label" "not present"
      fi
    }
    remove_apparmor_profile "Fieldwork rootlesskit AppArmor profile" /etc/apparmor.d/home.fieldwork.bin.rootlesskit
    remove_apparmor_profile "Fieldwork bwrap AppArmor profile" /etc/apparmor.d/fieldwork-bwrap
    if [ "$apparmor_reload_needed" = "1" ]; then
      if sudo -n systemctl restart apparmor.service >/dev/null 2>&1; then
        ok "AppArmor reload"
      else
        failed "AppArmor reload" "systemctl failed"
      fi
    fi
  else
    skipped "remote user linger" "sudo unavailable"
    skipped "Fieldwork rootlesskit AppArmor profile" "sudo unavailable"
    skipped "Fieldwork bwrap AppArmor profile" "sudo unavailable"
  fi
fi
if systemctl --user daemon-reload >/dev/null 2>&1; then
  ok "remote user systemd daemon-reload"
else
  skipped "remote user systemd daemon-reload" "systemd user unavailable"
fi
REMOTE
}

uninstall_remote_temporary_sudo() {
  local sudoers_q
  sudoers_q="$(shell_quote "$(fieldwork_sudoers_path)")"
  if ! ssh "$FIELDWORK_SSH_HOST" "test -f $sudoers_q" >/dev/null 2>&1; then
    uninstall_skipped "temporary sudoers rule" "not present"
    return 0
  fi
  uninstall_status_note "removing temporary sudoers rule"
  uninstall_status_cleanup
  if ssh -t "$FIELDWORK_SSH_HOST" "$(remote_sudo_command "rm -f $sudoers_q")"; then
    FIELDWORK_REMOTE_SUDO_PASSWORDLESS=""
    uninstall_ok "temporary sudoers rule"
    return 0
  fi
  FIELDWORK_REMOTE_SUDO_PASSWORDLESS=""
  uninstall_failed "temporary sudoers rule" "rm failed"
  return 1
}

uninstall_remote_broker() {
  local purge="$1"
  local remove_users="$2"
  local command='bash -lc '"$(shell_quote "set -eu
FIELDWORK_UNINSTALL_QUIET=${UNINSTALL_QUIET:-0}
log_status() {
  status=\"\$1\"; description=\"\$2\"; reason=\"\${3:-}\"
  case \"\$status\" in
    ok) [ \"\${FIELDWORK_UNINSTALL_QUIET:-0}\" = \"1\" ] && return 0; printf '  [ready] %s\n' \"\$description\" ;;
    skipped) [ \"\${FIELDWORK_UNINSTALL_QUIET:-0}\" = \"1\" ] && return 0; printf '  [info] %s (%s)\n' \"\$description\" \"\$reason\" ;;
    failed) printf '  [blocked] %s (%s)\n' \"\$description\" \"\$reason\" ;;
  esac
}
ok() { log_status ok \"\$1\"; }
skipped() { log_status skipped \"\$1\" \"\$2\"; }
failed() { log_status failed \"\$1\" \"\$2\"; }
remove_file() {
  description=\"\$1\"; path=\"\$2\"
  if [ ! -e \"\$path\" ] && [ ! -L \"\$path\" ]; then skipped \"\$description\" \"not present\"; return 0; fi
  if rm -f -- \"\$path\"; then ok \"\$description\"; else failed \"\$description\" \"rm failed\"; fi
}
remove_tree() {
  description=\"\$1\"; path=\"\$2\"; prefix=\"\$3\"
  if [ -z \"\$path\" ] || [ -z \"\$prefix\" ]; then failed \"\$description\" \"empty path guard\"; return 0; fi
  case \"\$path\" in \"\$prefix\"|\"\$prefix\"/*) ;; *) failed \"\$description\" \"outside expected prefix\"; return 0 ;; esac
  if [ ! -e \"\$path\" ]; then skipped \"\$description\" \"not present\"; return 0; fi
  if rm -rf -- \"\$path\"; then ok \"\$description\"; else failed \"\$description\" \"rm failed\"; fi
}
remove_user() {
  user=\"\$1\"
  if id \"\$user\" >/dev/null 2>&1; then
    if userdel \"\$user\" >/dev/null 2>&1; then ok \"system user \$user\"; else failed \"system user \$user\" \"userdel failed\"; fi
  else
    skipped \"system user \$user\" \"not present\"
  fi
}
remove_group() {
  group=\"\$1\"
  if getent group \"\$group\" >/dev/null 2>&1; then
    if groupdel \"\$group\" >/dev/null 2>&1; then ok \"system group \$group\"; else failed \"system group \$group\" \"groupdel failed\"; fi
  else
    skipped \"system group \$group\" \"not present\"
  fi
}
units_present=0
for path in /etc/systemd/system/fieldwork-pr-broker.socket /etc/systemd/system/fieldwork-pr-approve.socket /etc/systemd/system/fieldwork-pr-broker.service /etc/systemd/system/sockets.target.wants/fieldwork-pr-broker.socket /etc/systemd/system/sockets.target.wants/fieldwork-pr-approve.socket /etc/systemd/system/multi-user.target.wants/fieldwork-pr-broker.service; do
  [ -e \"\$path\" ] || [ -L \"\$path\" ] || continue
  units_present=1
done
if systemctl disable --now fieldwork-pr-broker.socket fieldwork-pr-approve.socket fieldwork-pr-broker.service >/dev/null 2>&1; then
  ok \"broker systemd units\"
elif [ \"\$units_present\" = \"1\" ]; then
  failed \"broker systemd units\" \"systemctl failed\"
else
  skipped \"broker systemd units\" \"not present\"
fi
remove_file \"broker submit socket unit\" /etc/systemd/system/fieldwork-pr-broker.socket
remove_file \"broker approve socket unit\" /etc/systemd/system/fieldwork-pr-approve.socket
remove_file \"broker service unit\" /etc/systemd/system/fieldwork-pr-broker.service
remove_file \"broker submit socket enable link\" /etc/systemd/system/sockets.target.wants/fieldwork-pr-broker.socket
remove_file \"broker approve socket enable link\" /etc/systemd/system/sockets.target.wants/fieldwork-pr-approve.socket
remove_file \"broker service enable link\" /etc/systemd/system/multi-user.target.wants/fieldwork-pr-broker.service
if systemctl daemon-reload >/dev/null 2>&1; then ok \"systemd daemon-reload\"; else failed \"systemd daemon-reload\" \"systemctl failed\"; fi
remove_tree \"broker config\" /etc/fieldwork-pr-broker /etc
remove_tree \"broker library\" /usr/local/lib/fieldwork-pr-broker /usr/local/lib
remove_tree \"broker state\" /var/lib/fieldwork-pr-broker /var/lib
remove_tree \"broker runtime\" /run/fieldwork-pr-broker /run
remove_file \"broker rotate-pat helper\" /usr/local/sbin/rotate-pat
if [ '$purge' = '1' ]; then
  remove_file \"broker log\" /var/log/fieldwork-pr-broker.log
  remove_tree \"Fieldwork install logs\" /var/log/fieldwork /var/log
fi
if [ '$remove_users' = '1' ]; then
  remove_user fieldwork-pr-broker
  remove_group fieldwork-pr-broker
  remove_group fieldwork-pr
  remove_group fieldwork-bot
else
  skipped \"broker system users/groups\" \"not requested\"
fi")"
  uninstall_status_note "cleaning broker services (sudo), entering interactive SSH"
  uninstall_status_cleanup
  ssh -t "$FIELDWORK_SSH_HOST" "$(remote_sudo_command "$command")"
}

uninstall_remote_bot() {
  local purge="$1"
  local remove_users="$2"
  local command='bash -lc '"$(shell_quote "set -eu
FIELDWORK_UNINSTALL_QUIET=${UNINSTALL_QUIET:-0}
log_status() {
  status=\"\$1\"; description=\"\$2\"; reason=\"\${3:-}\"
  case \"\$status\" in
    ok) [ \"\${FIELDWORK_UNINSTALL_QUIET:-0}\" = \"1\" ] && return 0; printf '  [ready] %s\n' \"\$description\" ;;
    skipped) [ \"\${FIELDWORK_UNINSTALL_QUIET:-0}\" = \"1\" ] && return 0; printf '  [info] %s (%s)\n' \"\$description\" \"\$reason\" ;;
    failed) printf '  [blocked] %s (%s)\n' \"\$description\" \"\$reason\" ;;
  esac
}
ok() { log_status ok \"\$1\"; }
skipped() { log_status skipped \"\$1\" \"\$2\"; }
failed() { log_status failed \"\$1\" \"\$2\"; }
remove_file() {
  description=\"\$1\"; path=\"\$2\"
  if [ ! -e \"\$path\" ] && [ ! -L \"\$path\" ]; then skipped \"\$description\" \"not present\"; return 0; fi
  if rm -f -- \"\$path\"; then ok \"\$description\"; else failed \"\$description\" \"rm failed\"; fi
}
remove_tree() {
  description=\"\$1\"; path=\"\$2\"; prefix=\"\$3\"
  if [ -z \"\$path\" ] || [ -z \"\$prefix\" ]; then failed \"\$description\" \"empty path guard\"; return 0; fi
  case \"\$path\" in \"\$prefix\"|\"\$prefix\"/*) ;; *) failed \"\$description\" \"outside expected prefix\"; return 0 ;; esac
  if [ ! -e \"\$path\" ]; then skipped \"\$description\" \"not present\"; return 0; fi
  if rm -rf -- \"\$path\"; then ok \"\$description\"; else failed \"\$description\" \"rm failed\"; fi
}
remove_user() {
  user=\"\$1\"
  if id \"\$user\" >/dev/null 2>&1; then
    if userdel \"\$user\" >/dev/null 2>&1; then ok \"system user \$user\"; else failed \"system user \$user\" \"userdel failed\"; fi
  else
    skipped \"system user \$user\" \"not present\"
  fi
}
remove_group() {
  group=\"\$1\"
  if getent group \"\$group\" >/dev/null 2>&1; then
    if groupdel \"\$group\" >/dev/null 2>&1; then ok \"system group \$group\"; else failed \"system group \$group\" \"groupdel failed\"; fi
  else
    skipped \"system group \$group\" \"not present\"
  fi
}
units_present=0
for path in /etc/systemd/system/fieldwork-bot.service /etc/systemd/system/multi-user.target.wants/fieldwork-bot.service; do
  [ -e \"\$path\" ] || [ -L \"\$path\" ] || continue
  units_present=1
done
if systemctl disable --now fieldwork-bot.service >/dev/null 2>&1; then
  ok \"approval bot systemd unit\"
elif [ \"\$units_present\" = \"1\" ]; then
  failed \"approval bot systemd unit\" \"systemctl failed\"
else
  skipped \"approval bot systemd unit\" \"not present\"
fi
remove_file \"approval bot service unit\" /etc/systemd/system/fieldwork-bot.service
remove_file \"approval bot enable link\" /etc/systemd/system/multi-user.target.wants/fieldwork-bot.service
remove_file \"approval bot binary\" /usr/local/bin/fieldwork-bot
if systemctl daemon-reload >/dev/null 2>&1; then ok \"systemd daemon-reload\"; else failed \"systemd daemon-reload\" \"systemctl failed\"; fi
remove_tree \"approval bot config\" /etc/fieldwork-bot /etc
remove_tree \"approval bot state\" /var/lib/fieldwork-bot /var/lib
agent_user=$(shell_quote "$FIELDWORK_REMOTE_USER")
tmp_removed=0
tmp_seen=0
for tmp in /tmp/fieldwork-install-bot-*.sh /tmp/fieldwork-bot-config.toml /tmp/fieldwork-bot-secret; do
  # Guard temp cleanup tightly: require the expected /tmp name, a regular
  # non-symlink file, and ownership by the agent user before removing it.
  case \"\$tmp\" in
    /tmp/fieldwork-install-bot-*.sh|/tmp/fieldwork-bot-config.toml|/tmp/fieldwork-bot-secret) ;;
    *) continue ;;
  esac
  [ -e \"\$tmp\" ] || continue
  tmp_seen=1
  [ -f \"\$tmp\" ] || { skipped \"approval bot temp \$tmp\" \"not a regular file\"; continue; }
  [ ! -L \"\$tmp\" ] || { skipped \"approval bot temp \$tmp\" \"symlink\"; continue; }
  [ \"\$(stat -c '%U' \"\$tmp\" 2>/dev/null || true)\" = \"\$agent_user\" ] || { skipped \"approval bot temp \$tmp\" \"owner mismatch\"; continue; }
  if rm -f -- \"\$tmp\"; then tmp_removed=1; else failed \"approval bot temp \$tmp\" \"rm failed\"; fi
done
if [ \"\$tmp_removed\" = \"1\" ]; then ok \"approval bot temp files\"; elif [ \"\$tmp_seen\" = \"0\" ]; then skipped \"approval bot temp files\" \"not present\"; fi
if [ '$purge' = '1' ]; then
  remove_file \"approval bot log\" /var/log/fieldwork-bot.log
fi
if [ '$remove_users' = '1' ]; then
  remove_user fieldwork-bot
  remove_group fieldwork-bot
else
  skipped \"approval bot system user/group\" \"not requested\"
fi")"
  uninstall_status_note "cleaning approval bot (sudo), entering interactive SSH"
  uninstall_status_cleanup
  ssh -t "$FIELDWORK_SSH_HOST" "$(remote_sudo_command "$command")"
}
