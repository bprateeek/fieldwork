#!/usr/bin/env bash
# Sourced by bin/fieldwork. Do not execute directly.
# Contains setup command handler only.

setup_fieldwork() {
  local yes=0
  local skip_sync=0
  local force_install=0
  local setup_status=0
  local next_action=""
  local after_action="fieldwork setup"
  local current_phase=""
  local current_phase_pending_count=0
  local -a current_phase_pending_labels=()
  local -a setup_remaining_phases=()
  local -a setup_remaining_labels=()
  local -a setup_remaining_actions=()
  local STAGE_TOTAL=5
  local setup_hard_blocked=0
  local setup_summary_ready=0
  local manual_block_printed=0
  local hard_block_reason=""
  local hard_block_action=""
  local setup_total_start=""
  local setup_entry_time=""
  local connect_stage_start=""
  local prepare_stage_start=""
  local github_stage_start=""
  local services_stage_start=""
  local verify_stage_start=""
  local setup_vps_reachable=0
  local setup_agents="${FIELDWORK_SETUP_AGENTS:-claude}"
  local setup_agents_explicit=0
  local codex_install_package="${FIELDWORK_CODEX_NPM_PACKAGE:-@openai/codex@$(codex_min_version)}"
  normalize_setup_agents() {
    case "$1" in
      claude|codex|both) printf '%s\n' "$1" ;;
      claude,codex|codex,claude) printf 'both\n' ;;
      *) return 1 ;;
    esac
  }
  setup_agent_enabled() {
    case "$setup_agents:$1" in
      both:claude|both:codex|claude:claude|codex:codex) return 0 ;;
      *) return 1 ;;
    esac
  }
  setup_agents_file_value() {
    case "$setup_agents" in
      both) printf 'claude,codex\n' ;;
      *) printf '%s\n' "$setup_agents" ;;
    esac
  }
  setup_codex_permissions_profile() {
    printf 'fieldwork\n'
  }
  if ! setup_agents="$(normalize_setup_agents "$setup_agents")"; then
    echo "invalid FIELDWORK_SETUP_AGENTS: ${FIELDWORK_SETUP_AGENTS:-}" >&2
    return 2
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      --skip-sync) skip_sync=1; shift ;;
      --force-install) force_install=1; shift ;;
      --agent)
        [ -n "${2:-}" ] || { echo "--agent requires claude, codex, or both" >&2; return 2; }
        if ! setup_agents="$(normalize_setup_agents "$2")"; then
          echo "invalid --agent value: $2 (expected claude, codex, or both)" >&2
          return 2
        fi
        setup_agents_explicit=1
        shift 2
        ;;
      --agent=*)
        if ! setup_agents="$(normalize_setup_agents "${1#--agent=}")"; then
          echo "invalid --agent value: ${1#--agent=} (expected claude, codex, or both)" >&2
          return 2
        fi
        setup_agents_explicit=1
        shift
        ;;
      --help)
        cat <<'EOF'
usage: fieldwork setup [--agent claude|codex|both] [--yes] [--skip-sync] [--force-install]

Guided developer preview setup for the local CLI, SSH alias, VPS reachability,
notification config, VPS sync/install, and remote readiness checks. It does
not edit ~/.ssh/config or automate account logins/secrets.

If --agent is omitted, setup prompts in an interactive terminal and defaults to
claude. Non-interactive setup keeps the developer-preview default of claude.
Use --agent codex for the Codex Desktop + SSH path, or --agent both to prepare both
agent surfaces on the same VPS.

This is the main first-run entrypoint. When infrastructure does not exist yet,
it prints the next manual action and points to docs/first-time-infrastructure.md
as the detailed reference.
EOF
        return 0
        ;;
      *) echo "unknown setup argument: $1" >&2; return 2 ;;
    esac
  done
  if [ "$setup_agents_explicit" = "0" ] && [ "$yes" != "1" ] && [ -t 0 ]; then
    local setup_agents_answer=""
    printf '[fieldwork setup] Agent support [claude/codex/both] (claude): '
    if IFS= read -r setup_agents_answer; then
      case "$setup_agents_answer" in
        "") setup_agents=claude ;;
        *)
          if ! setup_agents="$(normalize_setup_agents "$setup_agents_answer")"; then
            echo "invalid agent selection: $setup_agents_answer (expected claude, codex, or both)" >&2
            return 2
          fi
          ;;
      esac
    else
      echo
    fi
    echo
  fi
  FIELDWORK_SETUP_AGENTS="$setup_agents"
  export FIELDWORK_SETUP_AGENTS

  setup_entry_time="$(fieldwork_timing_start)"
  fieldwork_timing_since "cli init" "${FIELDWORK_CLI_ENTRY_TIME:-}" "$setup_entry_time"
  setup_total_start="$setup_entry_time"

  setup_timing_total() {
    fieldwork_timing_since "setup total" "$setup_total_start"
  }
  set_setup_next() {
    [ -n "$next_action" ] && return 0
    next_action="$1"
    after_action="${2:-fieldwork setup}"
    if [ "${#setup_remaining_actions[@]}" -gt 0 ]; then
      local last_index=$(( ${#setup_remaining_actions[@]} - 1 ))
      if [ -z "${setup_remaining_actions[$last_index]}" ]; then
        setup_remaining_actions[$last_index]="$1"
      fi
    fi
  }
  setup_pending_summary_label() {
    local label="$1"
    case "$label" in
      *" missing or not writable") label="${label% missing or not writable}" ;;
      *" confirmation needed") label="${label% needed}" ;;
      *" needed") label="${label% needed}" ;;
      *" not configured") label="${label% not configured}" ;;
      *" not stored") label="${label% not stored}" ;;
      *" missing") label="${label% missing}" ;;
      *" still present") label="${label% still present} cleanup" ;;
    esac
    printf '%s\n' "$label"
  }
  record_setup_pending() {
    local label="$1"
    local action="${2:-}"
    local phase="${current_phase:-Setup}"
    local summary_label
    summary_label="$(setup_pending_summary_label "$label")"
    setup_remaining_phases+=("$phase")
    setup_remaining_labels+=("$summary_label")
    setup_remaining_actions+=("$action")
    current_phase_pending_labels+=("$summary_label")
    current_phase_pending_count=$((current_phase_pending_count + 1))
  }
  finish_setup_phase() {
    local mode="${1:-continue}"
    local label
    [ -n "$current_phase" ] || return 0
    if [ "$current_phase_pending_count" -gt 0 ]; then
      echo
      label_line "$current_phase pending"
      for label in "${current_phase_pending_labels[@]}"; do
        echo "  - $label"
      done
      case "$mode" in
        stop)
          echo
          echo "Complete the next action, then rerun setup."
          ;;
      esac
    fi
    current_phase=""
    current_phase_pending_count=0
    current_phase_pending_labels=()
  }
  print_remaining_after_next() {
    local i
    local printed=0
    local phase label action last_phase step
    last_phase=""
    step=0
    for i in "${!setup_remaining_labels[@]}"; do
      phase="${setup_remaining_phases[$i]}"
      label="${setup_remaining_labels[$i]}"
      action="${setup_remaining_actions[$i]}"
      if [ -n "$action" ] && [ "$action" = "$next_action" ]; then
        continue
      fi
      if [ "$printed" = "0" ]; then
        echo
        label_line "Remaining after that"
        printed=1
      fi
      if [ "$phase" != "$last_phase" ]; then
        label_line "$phase" "  "
        last_phase="$phase"
        step=1
      else
        step=$((step + 1))
      fi
      if [ -n "$action" ]; then
        echo "    $step. $label -> $action"
      else
        echo "    $step. $label"
      fi
    done
  }
  print_setup_next() {
    local fallback="$1"
    finish_setup_phase stop
    echo
    label_line "Next action"
    echo "  ${next_action:-$fallback}"
    echo
    label_line "After completing it"
    echo "  $after_action"
    print_remaining_after_next
  }
  setup_section() {
    finish_setup_phase continue
    phase_section "$1"
    current_phase="$1"
    current_phase_pending_count=0
    current_phase_pending_labels=()
  }
  setup_row() {
    local status="$1"
    local label="$2"
    local action="${3:-}"
    local after="${4:-fieldwork setup}"
    local hard="${5:-}"
    case "$status" in
      ok) setup_status_line ok "$label" ;;
      needs)
        setup_status_line needs "$label"
        record_setup_pending "$label" "$action"
        [ -z "$action" ] || set_setup_next "$action" "$after"
        setup_status=1
        [ "$hard" = "hard" ] && mark_hard_blocker "$label" "$action"
        ;;
      manual)
        setup_status_line manual "$label"
        record_setup_pending "$label" "$action"
        [ -z "$action" ] || set_setup_next "$action" "$after"
        [ "$hard" = "hard" ] && mark_hard_blocker "$label" "$action"
        ;;
      blocked)
        setup_status_line blocked "$label"
        record_setup_pending "$label" "$action"
        [ -z "$action" ] || set_setup_next "$action" "$after"
        setup_status=1
        [ "$hard" = "hard" ] && mark_hard_blocker "$label" "$action"
        ;;
      *) setup_status_line "$status" "$label" ;;
    esac
    return 0
  }
  mark_hard_blocker() {
    [ "$setup_hard_blocked" = "1" ] && return 0
    setup_hard_blocked=1
    hard_block_reason="$1"
    hard_block_action="${2:-}"
  }
  stage_banner() {
    phase_section "$(printf '[%s/%s] %s' "$1" "$STAGE_TOTAL" "$2")"
  }
  setup_map_field() {
    local label="$1"
    local status="$2"
    local value="$3"
    setup_status_line "$status" "$label: $value"
  }
  print_manual_action_needed() {
    [ "$manual_block_printed" = "1" ] && return 0
    manual_block_printed=1
    local reason="${hard_block_reason:-Setup cannot continue.}"
    local action="${hard_block_action:-fieldwork setup}"
    echo
    label_line "Manual action needed"
    echo "  $reason"
    echo
    label_line "Run"
    echo "  $action"
    echo
    label_line "Then rerun"
    echo "  fieldwork setup"
  }
  local_setup_prereqs_ready() {
    local cmd
    for cmd in bash git jq ssh scp sed grep rsync; do
      command -v "$cmd" >/dev/null 2>&1 || return 1
    done
    [ -x "$HOME/.local/bin/fieldwork" ] || return 1
    path_contains "$HOME/.local/bin" || return 1
    return 0
  }
  print_setup_map_initial() {
    echo
    label_line "Setup map"
    setup_map_field "Agents" ok "$(setup_agents_file_value)"
    if local_setup_prereqs_ready; then
      setup_map_field "Local tools" ok "ready"
    else
      setup_map_field "Local tools" needs "checking now"
    fi
    if ssh_alias_looks_configured; then
      setup_map_field "SSH alias" ok "$FIELDWORK_SSH_HOST"
      setup_map_field "SSH" needs "pending reachability check"
    else
      setup_map_field "SSH alias" needs "pending"
      setup_map_field "SSH" needs "pending"
    fi
    setup_map_field "Remote Fieldwork" needs "pending"
    setup_map_field "VPS runtime" needs "pending"
    if setup_agent_enabled claude; then
      setup_map_field "Claude Code login" needs "pending"
    fi
    if setup_agent_enabled codex; then
      setup_map_field "Codex login" needs "pending"
    fi
    setup_map_field "GitHub auth" needs "pending"
    setup_map_field "Broker" needs "pending"
    setup_map_field "Broker token" needs "pending"
    setup_map_field "Verify runner" needs "pending"
    setup_map_field "PR prepare runner" needs "pending"
  }
  print_setup_summary() {
    local setup_summary_timing_start
    setup_summary_timing_start="$(fieldwork_timing_start)"
    echo
    label_line "Setup map"
    setup_summary_ready=1
    setup_map_field "Server" ok "${FIELDWORK_SSH_HOST:-unset}"
    local ssh_ok=0
    if [ "$setup_vps_reachable" = "1" ]; then
      ssh_ok=1
      setup_map_field "SSH" ok "working"
    elif progress_wait "checking VPS reachability" check_vps_reachable; then
      ssh_ok=1
      setup_vps_reachable=1
      setup_map_field "SSH" ok "working"
    else
      setup_map_field "SSH" blocked "not reachable"
      setup_summary_ready=0
    fi
    if [ "$ssh_ok" != "1" ]; then
      setup_summary_ready=0
      setup_map_field "Agents" ok "$(setup_agents_file_value)"
      setup_map_field "GitHub auth" needs "pending"
      setup_map_field "Broker" needs "pending"
      setup_map_field "Broker token" needs "pending"
      setup_map_field "Verify runner" needs "pending"
      setup_map_field "PR prepare runner" needs "pending"
      fieldwork_timing_since "print setup summary" "$setup_summary_timing_start"
      return
    fi
    setup_map_field "Agents" ok "$(setup_agents_file_value)"
    if github_authenticated >/dev/null 2>&1; then
      setup_map_field "GitHub auth" ok "ready"
    else
      setup_map_field "GitHub auth" needs "needs action"
      setup_summary_ready=0
    fi
    if broker_socket_writable >/dev/null 2>&1; then
      setup_map_field "Broker" ok "running"
    else
      setup_map_field "Broker" needs "pending"
      setup_summary_ready=0
    fi
    if broker_pat_stored >/dev/null 2>&1; then
      setup_map_field "Broker token" ok "stored"
    else
      setup_map_field "Broker token" needs "pending"
      setup_summary_ready=0
    fi
    if remote_verify_runner_ready >/dev/null 2>&1; then
      setup_map_field "Verify runner" ok "ready"
    else
      setup_map_field "Verify runner" needs "pending"
      setup_summary_ready=0
    fi
    if remote_prepare_runner_ready >/dev/null 2>&1; then
      setup_map_field "PR prepare runner" ok "ready"
    else
      setup_map_field "PR prepare runner" needs "pending"
      setup_summary_ready=0
    fi
    fieldwork_timing_since "print setup summary" "$setup_summary_timing_start"
  }
  setup_block_and_exit() {
    finish_setup_phase stop
    stage_banner 5 "Verify setup"
    print_setup_summary
    print_manual_action_needed
    return "$setup_status"
  }
  run_setup_sync() {
    if [ "$yes" = "1" ] && [ "$force_install" = "1" ]; then
      sync_vps --yes --force-install || true
    elif [ "$yes" = "1" ]; then
      sync_vps --yes || true
    elif [ "$force_install" = "1" ]; then
      sync_vps --force-install || true
    else
      sync_vps || true
    fi
  }
  persist_configured_agents_local() {
    local value
    value="$(setup_agents_file_value)"
    mkdir -p "$HOME/.fieldwork"
    umask 077
    printf '%s\n' "$value" > "$HOME/.fieldwork/agents"
    chmod 600 "$HOME/.fieldwork/agents"
  }
  persist_configured_agents_remote() {
    local value_q
    value_q="$(shell_quote "$(setup_agents_file_value)")"
    ssh "$FIELDWORK_SSH_HOST" "mkdir -p ~/.fieldwork/state && chmod 700 ~/.fieldwork && printf '%s\n' $value_q > ~/.fieldwork/agents && chmod 600 ~/.fieldwork/agents" >/dev/null 2>&1
  }
  remote_codex_cli_ready() {
    ssh "$FIELDWORK_SSH_HOST" 'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"; command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1' >/dev/null 2>&1
  }
  remote_codex_cli_version() {
    ssh "$FIELDWORK_SSH_HOST" 'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"; codex --version 2>/dev/null' 2>/dev/null | head -n 1 | tr -d "\r"
  }
  remote_codex_cli_version_ready() {
    local text version
    text="$(remote_codex_cli_version)"
    version="$(codex_version_from_text "$text")"
    [ -n "$version" ] && codex_version_ge "$version" "$(codex_min_version)"
  }
  remote_codex_login_state() {
    codex_remote_login_snapshot | sed -n 's/^CODEX_LOGIN_STATE=//p' | head -n 1
  }
  remote_codex_logged_in() {
    [ "$(remote_codex_login_state)" = "logged_in" ]
  }
  codex_login_confirmed() {
    local state
    state="$(remote_codex_login_state)"
    if [ "$state" = "logged_in" ]; then
      mark_codex_login_confirmed || true
      return 0
    fi
    [ "$state" = "marker_only" ]
  }
  mark_codex_login_confirmed() {
    local rc
    ssh "$FIELDWORK_SSH_HOST" "mkdir -p ~/.fieldwork/state && chmod 700 ~/.fieldwork && touch ~/.fieldwork/state/codex-login-confirmed && chmod 600 ~/.fieldwork/state/codex-login-confirmed" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && fieldwork_setup_snapshot_mark_dirty
    return "$rc"
  }
  confirm_codex_login_status() {
    mark_codex_login_confirmed
    codex_login_confirmed
  }
  codex_login_timeout_seconds() {
    local timeout="${FIELDWORK_SETUP_CODEX_LOGIN_TIMEOUT_SECONDS:-120}"
    case "$timeout" in
      ''|*[!0-9]*) timeout=120 ;;
    esac
    [ "$timeout" -gt 0 ] 2>/dev/null || timeout=120
    printf '%s\n' "$timeout"
  }
  run_codex_login_device_auth() {
    local timeout status
    timeout="$(codex_login_timeout_seconds)"
    echo "  Device-code login may keep the SSH prompt open after browser auth."
    echo "  Fieldwork will stop waiting after ${timeout}s, then verify login."
    set +e
    if command -v perl >/dev/null 2>&1; then
      perl -e 'my $timeout = shift @ARGV; alarm $timeout; exec @ARGV or die "exec failed: $!\n";' \
        "$timeout" ssh -t "$FIELDWORK_SSH_HOST" 'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"; codex login --device-auth'
      status=$?
    else
      ssh -t "$FIELDWORK_SSH_HOST" 'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"; codex login --device-auth'
      status=$?
    fi
    set -e
    case "$status" in
      0) ;;
      142) status_info_line "Codex login prompt timed out; checking login status" ;;
      *) status_info_line "Codex login prompt exited with status $status; checking login status" ;;
    esac
    return 0
  }
  remote_codex_identity_ready() {
    local expected_q
    expected_q="$(shell_quote "$FIELDWORK_REMOTE_USER")"
    ssh "$FIELDWORK_SSH_HOST" "test \"\$(id -un)\" = $expected_q" >/dev/null 2>&1
  }
  codex_sandbox_ready_cmd() {
    printf '%s\n' 'fieldwork-codex-sandbox run -c default_permissions=\":workspace\" -- true'
  }
  remote_codex_sandbox_helper_ready() {
    ssh "$FIELDWORK_SSH_HOST" 'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"; command -v fieldwork-codex-sandbox >/dev/null 2>&1' >/dev/null 2>&1
  }
  remote_codex_sandbox_ready() {
    local cmd
    cmd="$(codex_sandbox_ready_cmd)"
    ssh "$FIELDWORK_SSH_HOST" "export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"; $cmd" >/dev/null 2>&1
  }
  remote_linger_ready() {
    ssh "$FIELDWORK_SSH_HOST" 'test "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes' >/dev/null 2>&1
  }
  ensure_remote_linger() {
    ssh "$FIELDWORK_SSH_HOST" "loginctl enable-linger \"\$(id -un)\" 2>/dev/null || sudo -n loginctl enable-linger \"\$(id -un)\"" >/dev/null 2>&1
  }
  remote_xdg_runtime_ready() {
    ssh "$FIELDWORK_SSH_HOST" 'uid="$(id -u)"; runtime="${XDG_RUNTIME_DIR:-/run/user/$uid}"; test "$runtime" = "/run/user/$uid" && test -d "$runtime"' >/dev/null 2>&1
  }
  remote_delivery_clients_ready() {
    ssh "$FIELDWORK_SSH_HOST" 'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"; command -v fieldwork-verify >/dev/null 2>&1 && command -v fieldwork-pr-prepare >/dev/null 2>&1 && command -v fieldwork-pr-submit >/dev/null 2>&1' >/dev/null 2>&1
  }
  ensure_remote_runner_sockets() {
    ssh "$FIELDWORK_SSH_HOST" 'set -eu
mkdir -p "$HOME/.config/systemd/user"
cp "$HOME/.fieldwork/infra/fieldwork-verify-runner.socket" "$HOME/.fieldwork/infra/fieldwork-verify-runner@.service" "$HOME/.fieldwork/infra/fieldwork-pr-prepare-runner.socket" "$HOME/.fieldwork/infra/fieldwork-pr-prepare-runner@.service" "$HOME/.fieldwork/infra/fieldwork-event-poll.service" "$HOME/.fieldwork/infra/fieldwork-event-poll.timer" "$HOME/.fieldwork/infra/fieldwork-dashboard.service" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now fieldwork-verify-runner.socket fieldwork-pr-prepare-runner.socket fieldwork-event-poll.timer
' >/dev/null 2>&1
  }
  write_remote_codex_socket_allowlist() {
    local profile
    profile="$(setup_codex_permissions_profile)"
    ssh "$FIELDWORK_SSH_HOST" "FIELDWORK_CODEX_PROFILE=$(shell_quote "$profile") bash -s" <<'REMOTE_CODEX_CONFIG' >/dev/null 2>&1
set -euo pipefail
uid="$(id -u)"
broker_sock="/run/fieldwork-pr-broker/fieldwork-pr.sock"
verify_sock="/run/user/$uid/fieldwork-verify.sock"
prepare_sock="/run/user/$uid/fieldwork-pr-prepare.sock"
mkdir -p "$HOME/.codex"
cfg="$HOME/.codex/config.toml"
tmp="$(mktemp)"
	if [ -f "$cfg" ]; then
	  awk '
	    /^# BEGIN FIELDWORK CODEX SOCKETS$/ { skip = 1; next }
	    /^# END FIELDWORK CODEX SOCKETS$/ { skip = 0; next }
	    skip == 1 { next }
	    section == "" && /^[[:space:]]*default_permissions[[:space:]]*=/ { next }
	    /^\[/ { section = $0 }
	    skip != 1 { print }
	  ' "$cfg" > "$tmp"
	else
	  : > "$tmp"
	fi
	{
	  printf '\n# BEGIN FIELDWORK CODEX SOCKETS\n'
	  printf 'default_permissions = "%s"\n\n' "$FIELDWORK_CODEX_PROFILE"
	  printf '[permissions.%s]\n' "$FIELDWORK_CODEX_PROFILE"
	  printf 'extends = ":workspace"\n\n'
	  printf '[permissions.%s.network]\n' "$FIELDWORK_CODEX_PROFILE"
	  printf 'enabled = true\n'
	  printf 'mode = "limited"\n\n'
	  printf '[permissions.%s.network.unix_sockets]\n' "$FIELDWORK_CODEX_PROFILE"
	  printf '"%s" = "allow"\n' "$broker_sock"
	  printf '"%s" = "allow"\n' "$verify_sock"
	  printf '"%s" = "allow"\n' "$prepare_sock"
	  printf '# END FIELDWORK CODEX SOCKETS\n'
	} >> "$tmp"
mv "$tmp" "$cfg"
chmod 600 "$cfg"
REMOTE_CODEX_CONFIG
  }
  remote_codex_socket_allowlist_ready() {
    local profile
    profile="$(setup_codex_permissions_profile)"
    ssh "$FIELDWORK_SSH_HOST" "FIELDWORK_CODEX_PROFILE=$(shell_quote "$profile") bash -s" <<'REMOTE_CODEX_CHECK' >/dev/null 2>&1
set -euo pipefail
	uid="$(id -u)"
	cfg="$HOME/.codex/config.toml"
	grep -Fq "default_permissions = \"$FIELDWORK_CODEX_PROFILE\"" "$cfg"
	grep -Fq "[permissions.$FIELDWORK_CODEX_PROFILE]" "$cfg"
	grep -Fq 'extends = ":workspace"' "$cfg"
	grep -Fq "[permissions.$FIELDWORK_CODEX_PROFILE.network]" "$cfg"
	grep -Fq "enabled = true" "$cfg"
	grep -Fq 'mode = "limited"' "$cfg"
	grep -Fq "[permissions.$FIELDWORK_CODEX_PROFILE.network.unix_sockets]" "$cfg"
	grep -Fq '"/run/fieldwork-pr-broker/fieldwork-pr.sock" = "allow"' "$cfg"
	grep -Fq "\"/run/user/$uid/fieldwork-verify.sock\" = \"allow\"" "$cfg"
	grep -Fq "\"/run/user/$uid/fieldwork-pr-prepare.sock\" = \"allow\"" "$cfg"
REMOTE_CODEX_CHECK
  }
  remote_codex_sandbox_socket_probe() {
    local profile
    profile="$(setup_codex_permissions_profile)"
    ssh "$FIELDWORK_SSH_HOST" "FIELDWORK_CODEX_PROFILE=$(shell_quote "$profile") bash -s" <<'REMOTE_CODEX_PROBE' >/dev/null 2>&1
set -euo pipefail
uid="$(id -u)"
broker_sock="/run/fieldwork-pr-broker/fieldwork-pr.sock"
verify_sock="/run/user/$uid/fieldwork-verify.sock"
prepare_sock="/run/user/$uid/fieldwork-pr-prepare.sock"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
	fieldwork-codex-sandbox run -- python3 - "$broker_sock" "$verify_sock" "$prepare_sock" <<'PY'
import socket
import sys

for path in sys.argv[1:]:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(2)
    try:
        sock.connect(path)
    finally:
        sock.close()
PY
REMOTE_CODEX_PROBE
  }
  guide_missing_ssh_alias() {
    echo
    echo "No SSH alias named $FIELDWORK_SSH_HOST found."
    echo
    echo "Fieldwork needs one VPS where Claude Code can work and the broker can open PRs."
    echo
    echo "We'll connect it as:"
    echo
    echo "  ssh $FIELDWORK_SSH_HOST"
    echo
    echo "Let's set that up now."
    echo

    if [ "$yes" = "1" ]; then
      info_heading "SSH config snippet"
      info_row "Use when" "you have the VPS host ready."
      echo
      print_ssh_config_snippet "<vps-host-or-ip>"
      echo
      info_row "Guide if you still need a VPS" "$(first_time_reference)"
      set_setup_next "create the VPS if needed, then add the SSH config block above to ~/.ssh/config and rerun fieldwork setup"
      return 0
    fi

    local vps_host
    if ! read_vps_host "VPS hostname or IP: "; then
      info_heading "Create the VPS"
      info_row "Next" "create a small Ubuntu 24.04 VPS and add your local SSH public key."
      info_row "Verify" "confirm you can run: ssh root@<vps-public-ip> or ssh <sudo-user>@<vps-public-ip>"
      info_row "Stop there" "rerun fieldwork setup after admin SSH works; setup will connect the VPS."
      info_row "Reference only" "$(first_time_reference)"
      set_setup_next "create an Ubuntu 24.04 VPS, add your local SSH key, verify root SSH or sudo-user SSH works, then rerun fieldwork setup"
      return 0
    fi
    vps_host="$REPLY_VPS_HOST"

    if ssh_config_has_host "$FIELDWORK_SSH_HOST"; then
      # A single Fieldwork-managed block can be refreshed in place; a hand-authored
      # block (or duplicate managed blocks) is left for the user to reconcile.
      if [ "$(ssh_config_managed_block_count "$FIELDWORK_SSH_HOST")" = "1" ]; then
        if append_managed_ssh_alias "$vps_host" "~/.ssh/id_ed25519"; then
          status_ok_line "Refreshed managed SSH alias: $FIELDWORK_SSH_HOST -> $vps_host"
          if progress_wait "testing SSH alias $FIELDWORK_SSH_HOST" test_managed_ssh_alias; then
            status_ok_line "Tested: ssh $FIELDWORK_SSH_HOST true"
          else
            set_setup_next "fix SSH reachability for Host $FIELDWORK_SSH_HOST, then rerun fieldwork setup"
          fi
          return 0
        fi
        # append_managed_ssh_alias already warned; fall through to manual guidance.
      fi
      diagnose_existing_ssh_alias "$vps_host" "~/.ssh/id_ed25519"
      set_setup_next "edit ~/.ssh/config and replace Host $FIELDWORK_SSH_HOST with the block shown above, then rerun fieldwork setup"
      return 0
    fi

    if confirm "[fieldwork setup] Does this VPS already have the '$FIELDWORK_REMOTE_USER' Linux user that you can SSH into?" 0; then
      offer_append_ssh_alias "$vps_host" "~/.ssh/id_ed25519"
    else
      guide_claude_user_bootstrap "$vps_host"
    fi
  }
  confirm_yes() {
    local prompt="$1"
    printf '%s [Y/n] ' "$prompt"
    local answer=""
    if ! IFS= read -r answer; then
      echo
      return 1
    fi
    echo
    case "$answer" in
      n|N|no|NO) return 1 ;;
      *) return 0 ;;
    esac
  }
  print_handoff_block() {
    echo
    echo "You are about to leave Fieldwork briefly."
    echo "Complete the remote prompt, then return here."
    echo "Safe to cancel: rerun 'fieldwork setup' to resume."
  }
  read_vps_host() {
    local prompt="$1"
    local vps_host=""
    REPLY_VPS_HOST=""
    printf '%s' "$prompt"
    if IFS= read -r vps_host; then
      echo
    else
      echo
    fi
    if [ -n "$vps_host" ]; then
      case "$vps_host" in
        *[!A-Za-z0-9._:-]*)
          echo "[fieldwork setup] That host contains unusual characters."
          return 1
          ;;
      esac
      REPLY_VPS_HOST="$vps_host"
      return 0
    fi
    return 1
  }
  append_managed_ssh_alias() {
    local vps_host="$1"
    local identity_file="$2"
    local rc=0
    ssh_config_write_managed_block "$FIELDWORK_SSH_HOST" "$vps_host" "$identity_file" || rc=$?
    case "$rc" in
      0) return 0 ;;
      10) fieldwork_warn "~/.ssh/config is a symlink; not modifying it." \
            "edit it by hand using the block above" "docs/setup.md#ssh-config" ;;
      11) fieldwork_warn "Host $FIELDWORK_SSH_HOST already exists in ~/.ssh/config (not Fieldwork-managed); not modifying it." \
            "update that Host block to match the block above, or remove it and rerun" "docs/setup.md#ssh-config" ;;
      12) fieldwork_warn "multiple Fieldwork-managed blocks for $FIELDWORK_SSH_HOST in ~/.ssh/config; not modifying it." \
            "remove the duplicates, leaving one, then rerun fieldwork setup" "docs/setup.md#ssh-config" ;;
      *) fieldwork_warn "could not write the SSH alias to ~/.ssh/config." \
            "add the block above by hand" "docs/setup.md#ssh-config" ;;
    esac
    return 1
  }
  test_managed_ssh_alias() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$FIELDWORK_SSH_HOST" "true" >/dev/null 2>&1
  }
  resolved_ssh_hostname() {
    local ssh_config current_host
    ssh_config="$(ssh -G "$FIELDWORK_SSH_HOST" 2>/dev/null || true)"
    current_host="$(printf '%s\n' "$ssh_config" | awk '$1 == "hostname" { print $2; exit }')"
    [ -n "$current_host" ] || current_host="$FIELDWORK_SSH_HOST"
    printf '%s\n' "$current_host"
  }
  offer_append_ssh_alias() {
    local vps_host="$1"
    local identity_file="$2"
    echo "We can add this SSH alias for you:"
    echo
    print_ssh_config_snippet "$vps_host" "$identity_file"
    echo
    if ! confirm "[fieldwork setup] Append this managed block to ~/.ssh/config?" 0; then
      set_setup_next "add the SSH config block above to ~/.ssh/config, then rerun fieldwork setup"
      return 0
    fi
    if append_managed_ssh_alias "$vps_host" "$identity_file"; then
      status_ok_line "Added SSH alias: $FIELDWORK_SSH_HOST"
      if progress_wait "testing SSH alias $FIELDWORK_SSH_HOST" test_managed_ssh_alias; then
        status_ok_line "Tested: ssh $FIELDWORK_SSH_HOST true"
      else
        set_setup_next "fix SSH reachability for Host $FIELDWORK_SSH_HOST, then rerun fieldwork setup"
      fi
    else
      set_setup_next "edit ~/.ssh/config manually, then rerun fieldwork setup"
    fi
  }
  diagnose_existing_ssh_alias() {
    local expected_host="$1"
    local identity_file="$2"
    local ssh_config current_host current_user
    ssh_config="$(ssh -G "$FIELDWORK_SSH_HOST" 2>/dev/null || true)"
    current_host="$(printf '%s\n' "$ssh_config" | awk '$1 == "hostname" { print $2; exit }')"
    current_user="$(printf '%s\n' "$ssh_config" | awk '$1 == "user" { print $2; exit }')"
    [ -n "$current_host" ] || current_host="unknown"
    [ -n "$current_user" ] || current_user="unknown"
    echo "Host $FIELDWORK_SSH_HOST already exists, but it does not appear to match this VPS."
    echo
    echo "Current:"
    echo "  HostName $current_host"
    echo "  User $current_user"
    echo
    echo "Expected:"
    echo "  HostName $expected_host"
    echo "  User $FIELDWORK_REMOTE_USER"
    echo
    echo "Fieldwork will not overwrite your SSH config automatically."
    echo
    echo "To fix it, edit ~/.ssh/config and replace that Host block with:"
    echo
    print_ssh_config_snippet "$expected_host" "$identity_file"
  }
  normalize_local_path() {
    local path="$1"
    case "$path" in
      "~") printf '%s\n' "$HOME" ;;
      "~/"*) printf '%s/%s\n' "$HOME" "${path#~/}" ;;
      *) printf '%s\n' "$path" ;;
    esac
  }
  display_local_path() {
    local path="$1"
    case "$path" in
      "$HOME") printf '~\n' ;;
      "$HOME"/*) printf '~/%s\n' "${path#"$HOME"/}" ;;
      *) printf '%s\n' "$path" ;;
    esac
  }
  read_admin_login() {
    local admin_login=""
    REPLY_ADMIN_LOGIN=""
    printf "[fieldwork setup] Existing VPS admin login that can create/update '%s' [root]: " "$FIELDWORK_REMOTE_USER"
    if IFS= read -r admin_login; then
      echo
    else
      echo
    fi
    [ -n "$admin_login" ] || admin_login=root
    if ! valid_remote_user "$admin_login"; then
      echo "[fieldwork setup] Admin login must be a Linux username, such as root or prateek."
      return 1
    fi
    REPLY_ADMIN_LOGIN="$admin_login"
    return 0
  }
  guide_claude_user_bootstrap() {
    local vps_host="$1"
    echo "No problem. Fieldwork can create/update the '$FIELDWORK_REMOTE_USER' user using root SSH or another sudo-capable VPS account."
    echo
    info_list_heading "This will:"
    info_bullet "connect to an existing VPS admin login at $vps_host"
    info_bullet "create/update the '$FIELDWORK_REMOTE_USER' Linux user"
    info_bullet "install your local public key"
    info_bullet "add the $FIELDWORK_SSH_HOST SSH alias"
    info_bullet "test the connection"
    echo
    info_list_heading "It will not:"
    info_bullet "store your admin access"
    info_bullet "install GitHub or Claude secrets"
    info_bullet "modify any existing Host block"
    info_bullet "re-enable root SSH if this VPS was already hardened"
    echo
    echo "Use root for a fresh VPS. Use an existing sudo-capable user on a reused or bootstrap-hardened VPS."
    echo

    local admin_user=""
    if ! read_admin_login; then
      set_setup_next "rerun fieldwork setup and enter root or another sudo-capable VPS user; if none remains, use provider console/rescue mode to recreate '$FIELDWORK_REMOTE_USER'"
      return 0
    fi
    admin_user="$REPLY_ADMIN_LOGIN"

    local default_public_key="$HOME/.ssh/id_ed25519.pub"
    local public_key_path=""
    if [ -s "$default_public_key" ]; then
      public_key_path="$default_public_key"
    else
      echo "Press Enter to use the default key, or type another public key path."
      printf '[fieldwork setup] Local public key to install [%s]: ' "$(display_local_path "$default_public_key")"
      IFS= read -r public_key_path || public_key_path=""
      if [ -z "$public_key_path" ]; then
        public_key_path="$default_public_key"
      else
        public_key_path="$(normalize_local_path "$public_key_path")"
      fi
    fi

    if [ ! -s "$public_key_path" ]; then
      echo "[fieldwork setup] Public key not found or empty: $(display_local_path "$public_key_path")"
      echo "Create one with: ssh-keygen -t ed25519 -C \"fieldwork\""
      set_setup_next "create a local SSH key, then rerun fieldwork setup"
      return 0
    fi

    local identity_file="$public_key_path"
    case "$identity_file" in
      *.pub) identity_file="${identity_file%.pub}" ;;
    esac
    local identity_display
    identity_display="$(display_local_path "$identity_file")"

    info_heading "VPS user setup confirmation"
    info_row "Target" "$admin_user@$vps_host"
    info_row "User to create/update" "'$FIELDWORK_REMOTE_USER'"
    info_row "Public key" "$(display_local_path "$public_key_path")"
    if [ "$admin_user" = root ]; then
      info_row "Privilege path" "root SSH"
    else
      info_row "Privilege path" "sudo on the VPS as '$admin_user'"
      info_note "Fieldwork will ask locally for the VPS Linux password for '$admin_user' and send it only to remote sudo over SSH."
    fi
    info_row "Will not" "store admin access, install secrets, modify existing Host blocks, or restore root SSH."
    if [ ! -f "$identity_file" ]; then
      info_note "private key not found at $identity_display; the SSH config snippet will still use that path."
    fi
    echo
    if ! confirm "[fieldwork setup] Proceed with user setup on $vps_host as $admin_user?" 0; then
      echo "[fieldwork setup] VPS user setup cancelled."
      set_setup_next "create the '$FIELDWORK_REMOTE_USER' user manually with root or another sudo-capable account. Reference: $(first_time_reference)"
      return 0
    fi

    print_handoff_block
    if setup_claude_user_over_admin_ssh "$vps_host" "$public_key_path" "$identity_file" "$admin_user"; then
      status_ok_line "Created/updated $FIELDWORK_REMOTE_USER user"
      status_ok_line "Installed SSH key"
      if ssh_config_has_host "$FIELDWORK_SSH_HOST"; then
        status_ok_line "SSH alias already exists: $FIELDWORK_SSH_HOST"
        if progress_wait "testing SSH alias $FIELDWORK_SSH_HOST" test_managed_ssh_alias; then
          status_ok_line "Tested: ssh $FIELDWORK_SSH_HOST true"
        else
          set_setup_next "fix SSH reachability for Host $FIELDWORK_SSH_HOST, then rerun fieldwork setup"
        fi
      else
        if append_managed_ssh_alias "$vps_host" "$identity_display"; then
          status_ok_line "Added SSH alias: $FIELDWORK_SSH_HOST"
          if progress_wait "testing SSH alias $FIELDWORK_SSH_HOST" test_managed_ssh_alias; then
            status_ok_line "Tested: ssh $FIELDWORK_SSH_HOST true"
          else
            set_setup_next "fix SSH reachability for Host $FIELDWORK_SSH_HOST, then rerun fieldwork setup"
          fi
        else
          set_setup_next "edit ~/.ssh/config manually, then rerun fieldwork setup"
        fi
      fi
    else
      [ -n "$next_action" ] || set_setup_next "fix admin SSH/sudo access or create the '$FIELDWORK_REMOTE_USER' user manually. Reference: $(first_time_reference)"
    fi
  }
  record_authorized_key_install() {
    local vps_host="$1"
    local public_key_path="$2"
    local public_key="$3"
    local state_dir record fingerprint
    state_dir="$HOME/.config/fieldwork"
    record="$state_dir/authorized-key.env"
    fingerprint="$(ssh-keygen -lf "$public_key_path" 2>/dev/null | awk '{ print $2; exit }' || true)"
    mkdir -p "$state_dir"
    chmod 700 "$state_dir"
    umask 077
    {
      printf 'host=%s\n' "$vps_host"
      printf 'remote_user=%s\n' "$FIELDWORK_REMOTE_USER"
      printf 'fingerprint=%s\n' "$fingerprint"
      printf 'public_key=%s\n' "$public_key"
    } >"$record"
    chmod 600 "$record"
  }
  write_admin_user_setup_script() {
    local setup_script="$1"
    local remote_user="$2"
    local public_key="$3"
    local quoted_remote_user quoted_public_key
    quoted_remote_user="$(printf '%q' "$remote_user")"
    quoted_public_key="$(printf '%q' "$public_key")"
    cat >"$setup_script" <<EOF
set -euo pipefail
remote_user=$quoted_remote_user
public_key=$quoted_public_key
if ! id "\$remote_user" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "\$remote_user"
fi
usermod -aG sudo "\$remote_user"
sudoers="/etc/sudoers.d/fieldwork-\$remote_user"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "\$remote_user" > "\$sudoers"
chmod 440 "\$sudoers"
visudo -cf "\$sudoers" >/dev/null
install -d -m 700 -o "\$remote_user" -g "\$remote_user" "/home/\$remote_user/.ssh"
auth="/home/\$remote_user/.ssh/authorized_keys"
touch "\$auth"
chown "\$remote_user:\$remote_user" "\$auth"
chmod 600 "\$auth"
if ! grep -qxF "\$public_key" "\$auth"; then
  printf '%s\n' "\$public_key" >> "\$auth"
fi
chown "\$remote_user:\$remote_user" "\$auth"
EOF
    chmod 600 "$setup_script"
  }
  admin_setup_ssh_options() {
    printf '%s\n' -o ConnectTimeout=10 -o ServerAliveInterval=20 -o ServerAliveCountMax=3
  }
  cleanup_remote_admin_setup_script() {
    local admin_target="$1"
    local remote_tmp="$2"
    local remote_tmp_q
    [ -n "$remote_tmp" ] || return 0
    case "$remote_tmp" in
      /tmp/fieldwork-user-setup.*) ;;
      *) return 0 ;;
    esac
    remote_tmp_q="$(shell_quote "$remote_tmp")"
    ssh $(admin_setup_ssh_options) "$admin_target" "rm -rf -- $remote_tmp_q" >/dev/null 2>&1 || true
  }
  read_admin_sudo_password() {
    local admin_user="$1"
    local setup_log="$2"
    local password="" tty_state=""
    REPLY_ADMIN_SUDO_PASSWORD=""
    if declare -F fieldwork_status_stop_renderer >/dev/null 2>&1; then
      fieldwork_status_stop_renderer
    fi
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
      printf '\n[sudo] VPS Linux password for %s: ' "$admin_user" >/dev/tty
      tty_state="$(stty -g </dev/tty 2>/dev/null || true)"
      stty -echo </dev/tty 2>/dev/null || true
      IFS= read -r password </dev/tty || password=""
      if [ -n "$tty_state" ]; then
        stty "$tty_state" </dev/tty 2>/dev/null || true
      else
        stty echo </dev/tty 2>/dev/null || true
      fi
      printf '\n' >/dev/tty
    else
      printf 'local terminal /dev/tty unavailable; sudo prompt may not receive password input\n' >>"$setup_log"
      printf '\n'
    fi
    REPLY_ADMIN_SUDO_PASSWORD="$password"
    return 0
  }
  run_admin_sudo_script_with_password() {
    local admin_target="$1"
    local remote_script_q="$2"
    local setup_log="$3"
    local sudo_password="$4"
    local status

    if { printf '%s\n' "$sudo_password"; } | ssh $(admin_setup_ssh_options) "$admin_target" "sudo -S -p '' bash $remote_script_q" >>"$setup_log" 2>&1; then
      status=0
    else
      status=${PIPESTATUS[1]}
    fi
    unset sudo_password
    return "$status"
  }
  run_admin_user_setup_script() {
    local vps_host="$1"
    local admin_user="$2"
    local setup_script="$3"
    local setup_log="$4"
    local admin_target="$admin_user@$vps_host"
    local remote_tmp="" remote_script="" remote_tmp_q="" remote_script_q=""
    local status

    if [ "$admin_user" = root ]; then
      ssh $(admin_setup_ssh_options) "root@$vps_host" "bash -s" <"$setup_script" >"$setup_log" 2>&1
      return $?
    fi

    if ! remote_tmp="$(ssh $(admin_setup_ssh_options) "$admin_target" "umask 077 && mktemp -d /tmp/fieldwork-user-setup.XXXXXX" 2>>"$setup_log")"; then
      return 1
    fi
    case "$remote_tmp" in
      /tmp/fieldwork-user-setup.*) ;;
      *)
        printf 'unexpected remote temp dir: %s\n' "$remote_tmp" >>"$setup_log"
        cleanup_remote_admin_setup_script "$admin_target" "$remote_tmp"
        return 1
        ;;
    esac
    remote_script="$remote_tmp/setup.sh"
    remote_tmp_q="$(shell_quote "$remote_tmp")"
    remote_script_q="$(shell_quote "$remote_script")"
    if ! scp $(admin_setup_ssh_options) "$setup_script" "$admin_target:$remote_script" >>"$setup_log" 2>&1; then
      cleanup_remote_admin_setup_script "$admin_target" "$remote_tmp"
      return 1
    fi
    if ! ssh $(admin_setup_ssh_options) "$admin_target" "chmod 600 $remote_script_q" >>"$setup_log" 2>&1; then
      cleanup_remote_admin_setup_script "$admin_target" "$remote_tmp"
      return 1
    fi
    read_admin_sudo_password "$admin_user" "$setup_log"
    if run_admin_sudo_script_with_password "$admin_target" "$remote_script_q" "$setup_log" "$REPLY_ADMIN_SUDO_PASSWORD"; then
      status=0
    else
      status=$?
    fi
    unset REPLY_ADMIN_SUDO_PASSWORD
    ssh $(admin_setup_ssh_options) "$admin_target" "rm -rf -- $remote_tmp_q" >>"$setup_log" 2>&1 || true
    return "$status"
  }
  print_admin_setup_failure() {
    local setup_log="$1"
    local admin_user="$2"
    local vps_host="$3"
    echo "  Log: $setup_log"
    if [ -s "$setup_log" ]; then
      echo "  Last output:"
      tail -20 "$setup_log" | sed 's/^/    /'
    fi
    echo
    if [ "$admin_user" = root ] && grep -Eiq 'Permission denied' "$setup_log"; then
      setup_status_line needs "root SSH was rejected; this VPS may already have root login disabled"
      echo "Rerun setup and enter an existing sudo-capable VPS user when asked for the admin login."
      echo "If no sudo-capable account remains and root SSH is disabled, recovery requires your VPS provider console or rescue mode."
      set_setup_next "rerun fieldwork setup with a sudo-capable VPS user; if none remains, use provider console/rescue mode to recreate '$FIELDWORK_REMOTE_USER'"
    elif grep -Eiq 'not in the sudoers file|not allowed to run sudo|may not run sudo|is not allowed to execute' "$setup_log"; then
      setup_status_line needs "admin user '$admin_user' is not sudo-capable"
      echo "Choose another sudo-capable account, or use provider console/rescue mode to create one."
      set_setup_next "rerun fieldwork setup with a sudo-capable VPS user, or use provider console/rescue mode to recreate '$FIELDWORK_REMOTE_USER'"
    elif grep -Eiq 'Sorry, try again|incorrect password|authentication failure|[0-9]+ incorrect password attempts' "$setup_log"; then
      setup_status_line needs "sudo authentication failed for '$admin_user'"
      echo "Rerun setup and enter the VPS Linux password for '$admin_user', or choose another sudo-capable account."
      set_setup_next "rerun fieldwork setup with the correct VPS sudo password for '$admin_user', or choose another sudo-capable user"
    elif grep -Eiq 'a terminal is required|no tty present|a password is required|no password was provided|local terminal /dev/tty unavailable' "$setup_log"; then
      setup_status_line needs "sudo password prompt could not read from your terminal"
      echo "Rerun setup from an interactive terminal and enter the VPS Linux password for '$admin_user'."
      echo "If this keeps happening, choose another sudo-capable account or use provider console/rescue mode."
      set_setup_next "rerun fieldwork setup from an interactive terminal with sudo password input for '$admin_user'"
    else
      setup_status_line needs "admin setup failed on $vps_host"
      echo "Fix admin SSH/sudo access, then rerun:"
      echo "  fieldwork setup"
      echo "If no sudo-capable account remains and root SSH is disabled, recovery requires your VPS provider console or rescue mode."
      set_setup_next "fix admin SSH/sudo access or use provider console/rescue mode to recreate '$FIELDWORK_REMOTE_USER'"
    fi
  }
  setup_claude_user_over_admin_ssh() {
    local vps_host="$1"
    local public_key_path="$2"
    local identity_file="$3"
    local admin_user="$4"
    local public_key
    public_key="$(sed -n '1p' "$public_key_path")"
    if [ -z "$public_key" ]; then
      echo "[fieldwork setup] Public key is empty: $(display_local_path "$public_key_path")"
      return 1
    fi

    local setup_log setup_script
    setup_log="$(mktemp "${TMPDIR:-/tmp}/fieldwork-user-setup-log.XXXXXX")"
    setup_script="$(mktemp "${TMPDIR:-/tmp}/fieldwork-user-setup-script.XXXXXX")"
    status_info_line "VPS user setup log: $setup_log"
    write_admin_user_setup_script "$setup_script" "$FIELDWORK_REMOTE_USER" "$public_key"
    fieldwork_status_start "creating/updating $FIELDWORK_REMOTE_USER user on VPS"
    if ! run_admin_user_setup_script "$vps_host" "$admin_user" "$setup_script" "$setup_log"
    then
      fieldwork_status_fail "admin setup failed on $vps_host"
      rm -f "$setup_script"
      print_admin_setup_failure "$setup_log" "$admin_user" "$vps_host"
      return 1
    fi
    rm -f "$setup_script"
    fieldwork_status_succeed "user setup script completed"
    record_authorized_key_install "$vps_host" "$public_key_path" "$public_key" || true

    local test_ssh=(ssh -o BatchMode=yes -o ConnectTimeout=5)
    [ -f "$identity_file" ] && test_ssh+=(-i "$identity_file")
    if progress_wait "verifying SSH as '$FIELDWORK_REMOTE_USER'" "${test_ssh[@]}" "$FIELDWORK_REMOTE_USER@$vps_host" "id -un | grep -qx $(shell_quote "$FIELDWORK_REMOTE_USER")"; then
      status_ok_line "verified SSH as '$FIELDWORK_REMOTE_USER'"
      if progress_wait "verifying passwordless sudo for setup" "${test_ssh[@]}" "$FIELDWORK_REMOTE_USER@$vps_host" "sudo -n true"; then
        status_ok_line "verified passwordless sudo for setup"
      else
        setup_status_line needs "'$FIELDWORK_REMOTE_USER' can SSH in, but passwordless sudo is not working yet"
        echo "Try manually as root: visudo -cf $(fieldwork_sudoers_path)"
        return 1
      fi
    else
      setup_status_line needs "created '$FIELDWORK_REMOTE_USER', but SSH verification did not succeed yet"
      echo "Try manually: ssh $FIELDWORK_REMOTE_USER@$vps_host"
      set_setup_next "fix SSH key access for '$FIELDWORK_REMOTE_USER@$vps_host', then rerun fieldwork setup"
      return 1
    fi
    return 0
  }
  VPS_REACHABILITY_ERROR=""
  check_vps_reachable() {
    local err_file status
    err_file="$(mktemp "${TMPDIR:-/tmp}/fieldwork-ssh-check.XXXXXX")"
    if [ "$FIELDWORK_SSH_MUX_READY" = "1" ] && fieldwork_ssh_mux_configured; then
      set +e
      ssh -o BatchMode=yes -o ConnectTimeout=5 "$FIELDWORK_SSH_HOST" "true" >/dev/null 2>"$err_file"
      status=$?
      set -e
      VPS_REACHABILITY_ERROR="$(sed -n '1,4p' "$err_file")"
      rm -f "$err_file"
      return "$status"
    fi
    if fieldwork_ssh_try_mux_true "$err_file"; then
      VPS_REACHABILITY_ERROR=""
      rm -f "$err_file"
      return 0
    fi
    : >"$err_file"
    set +e
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$FIELDWORK_SSH_HOST" "true" >/dev/null 2>"$err_file"
    status=$?
    set -e
    VPS_REACHABILITY_ERROR="$(sed -n '1,4p' "$err_file")"
    rm -f "$err_file"
    return "$status"
  }
  unreachable_vps_next_action() {
    case "$VPS_REACHABILITY_ERROR" in
      *"Operation not permitted"*)
        printf 'run fieldwork setup from a terminal with outbound SSH access, or allow SSH if your execution environment asks for permission'
        ;;
      *"Operation timed out"*|*"Connection timed out"*)
        printf 'make port 22 reachable on the VPS public IP, then verify ssh %s and rerun fieldwork setup' "$FIELDWORK_SSH_HOST"
        ;;
      *"Connection refused"*)
        printf 'start or fix SSH on the VPS, then verify ssh %s and rerun fieldwork setup' "$FIELDWORK_SSH_HOST"
        ;;
      *"Could not resolve hostname"*)
        printf 'fix HostName for Host %s in ~/.ssh/config, then rerun fieldwork setup' "$FIELDWORK_SSH_HOST"
        ;;
      *"Permission denied"*)
        printf 'fix the SSH user/key for Host %s, then verify ssh %s and rerun fieldwork setup' "$FIELDWORK_SSH_HOST" "$FIELDWORK_SSH_HOST"
        ;;
      *)
        printf 'fix SSH reachability for Host %s, then verify ssh %s and rerun fieldwork setup' "$FIELDWORK_SSH_HOST" "$FIELDWORK_SSH_HOST"
        ;;
    esac
  }
  guide_unreachable_vps() {
    echo
    echo "Fieldwork found the SSH alias, but could not connect to it."
    if [ -n "$VPS_REACHABILITY_ERROR" ]; then
      echo "SSH reported:"
      printf '%s\n' "$VPS_REACHABILITY_ERROR" | sed 's/^/  /'
    else
      echo "Try this in your terminal to see the underlying SSH error:"
      echo "  ssh $FIELDWORK_SSH_HOST"
    fi
    case "$VPS_REACHABILITY_ERROR" in
      *"Operation not permitted"*)
        cat <<EOF

This usually means the local execution environment blocked outbound SSH.
Run setup from a normal terminal, or allow the SSH command if your agent runner asks for permission.
EOF
        ;;
      *"Operation timed out"*|*"Connection timed out"*)
        cat <<EOF

This usually means the VPS public IP is not accepting SSH on port 22.
Check that the VPS is powered on, HostName points at the current public IP, and provider firewall/security-group rules allow inbound TCP 22.
Then verify this from your terminal:
  ssh $FIELDWORK_SSH_HOST
EOF
        ;;
      *"Connection refused"*)
        cat <<EOF

The VPS answered, but nothing accepted SSH on port 22.
Check that sshd is installed and running on the VPS, then verify:
  ssh $FIELDWORK_SSH_HOST
EOF
        ;;
      *"Permission denied"*)
        cat <<EOF

The VPS is reachable, but SSH rejected the configured user or key.
Check that Host $FIELDWORK_SSH_HOST points at the literal '$FIELDWORK_REMOTE_USER' user and the right key, then verify:
  ssh $FIELDWORK_SSH_HOST
EOF
        echo
        echo "If this is a fresh or reset VPS, the '$FIELDWORK_REMOTE_USER' user may not exist yet."
        echo "Fieldwork can create/update that user using root SSH or another sudo-capable VPS account."
        echo
        guide_claude_user_bootstrap "$(resolved_ssh_hostname)"
        ;;
    esac
    echo
    echo "For first boot, HostName usually points at the VPS public IP."
    echo "If you use a private network, point HostName at that name once it works."
    echo "Reference only: $(first_time_reference)"
  }
  remote_bootstrap_ready() {
    local projects_dir_q
    local agents_q
    if fieldwork_setup_snapshot_is_ok bootstrap_ready; then
      return 0
    elif [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
      return 1
    fi
    projects_dir_q="$(shell_quote "$FIELDWORK_PROJECTS_DIR")"
    agents_q="$(shell_quote "$setup_agents")"
    ssh "$FIELDWORK_SSH_HOST" "agents=$agents_q; export PATH=\"\$HOME/.local/bin:\$PATH\"; command -v gh >/dev/null 2>&1 && test -d $projects_dir_q && test -f ~/.config/systemd/user/fieldwork-verify-runner.socket && test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner.socket && case \"\$agents\" in claude|both) command -v claude >/dev/null 2>&1 && test -f ~/.config/systemd/user/fieldwork-agent@.service ;; *) true ;; esac" >/dev/null 2>&1
  }
  run_remote_bootstrap() {
    local agents_q
    local rc
    agents_q="$(shell_quote "$setup_agents")"
    ssh -t "$FIELDWORK_SSH_HOST" "cd ~/fieldwork && FIELDWORK_SETUP_CONTEXT=guided FIELDWORK_SETUP_AGENTS=$agents_q ./bin/fieldwork bootstrap-vps"
    rc=$?
    [ "$rc" -eq 0 ] && fieldwork_setup_snapshot_mark_dirty
    return "$rc"
  }
  claude_login_confirmed() {
    if fieldwork_setup_snapshot_is_ok claude_login; then
      return 0
    elif [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
      return 1
    fi
    ssh "$FIELDWORK_SSH_HOST" "test -f ~/.fieldwork/state/claude-login-confirmed" >/dev/null 2>&1
  }
  mark_claude_login_confirmed() {
    local rc
    ssh "$FIELDWORK_SSH_HOST" "mkdir -p ~/.fieldwork/state && chmod 700 ~/.fieldwork && touch ~/.fieldwork/state/claude-login-confirmed && chmod 600 ~/.fieldwork/state/claude-login-confirmed" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && fieldwork_setup_snapshot_mark_dirty
    return "$rc"
  }
  confirm_claude_login_status() {
    mark_claude_login_confirmed
    claude_login_confirmed
  }
  github_authenticated() {
    local gh_live gh_hosts
    FIELDWORK_SETUP_GH_AUTH_TIMEOUT_HINT=0
    if fieldwork_setup_snapshot_ensure; then
      gh_live="$(fieldwork_setup_snapshot_value_raw gh_live 2>/dev/null || true)"
      if [ "$gh_live" = "ok" ]; then
        return 0
      fi
      if [ "$gh_live" = "timeout" ]; then
        gh_hosts="$(fieldwork_setup_snapshot_value_raw gh_hosts 2>/dev/null || true)"
        if [ "$gh_hosts" = "ok" ]; then
          FIELDWORK_SETUP_GH_AUTH_TIMEOUT_HINT=1
          return 0
        fi
        return 1
      fi
    fi
    if [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
      return 1
    fi
    ssh "$FIELDWORK_SSH_HOST" "export PATH=\"\$HOME/.local/bin:\$PATH\"; command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1" >/dev/null 2>&1
  }
  remote_verify_runner_ready() {
    if fieldwork_setup_snapshot_is_ok verify_runner; then
      return 0
    elif [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
      return 1
    fi
    ssh "$FIELDWORK_SSH_HOST" 'export PATH="$HOME/.local/bin:$PATH"; test -x "$HOME/.local/bin/fieldwork-verify" && test -x "$HOME/.local/bin/fieldwork-verify-runner" && test -x "$HOME/.fieldwork/scripts/fieldwork-verify-pipeline" && test -f "$HOME/.config/systemd/user/fieldwork-verify-runner.socket" && test -f "$HOME/.config/systemd/user/fieldwork-verify-runner@.service" && systemctl --user is-active --quiet fieldwork-verify-runner.socket && runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" && test -S "$runtime_dir/fieldwork-verify.sock" && command -v bwrap >/dev/null 2>&1 && bwrap --unshare-user --unshare-net --unshare-pid --unshare-uts --unshare-ipc --ro-bind / / --tmpfs /tmp --dev /dev --proc /proc -- /bin/true >/dev/null 2>&1' >/dev/null 2>&1
  }
  remote_prepare_runner_ready() {
    if fieldwork_setup_snapshot_is_ok prepare_runner; then
      return 0
    elif [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
      return 1
    fi
    ssh "$FIELDWORK_SSH_HOST" 'runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"; test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner.socket && systemctl --user is-active --quiet fieldwork-pr-prepare-runner.socket && test -S "$runtime_dir/fieldwork-pr-prepare.sock"' >/dev/null 2>&1
  }
  remote_claude_service_installed() {
    if fieldwork_setup_snapshot_is_ok claude_service; then
      return 0
    elif [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
      return 1
    fi
    ssh "$FIELDWORK_SSH_HOST" "test -f ~/.config/systemd/user/fieldwork-agent@.service" >/dev/null 2>&1
  }
  broker_socket_writable() {
    if fieldwork_setup_snapshot_is_ok broker_socket; then
      return 0
    elif [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
      return 1
    fi
    ssh "$FIELDWORK_SSH_HOST" "test -S /run/fieldwork-pr-broker/fieldwork-pr.sock && test -w /run/fieldwork-pr-broker/fieldwork-pr.sock" >/dev/null 2>&1
  }
  broker_pat_tool_installed() {
    if fieldwork_setup_snapshot_is_ok broker_pat_tool; then
      return 0
    elif [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
      return 1
    fi
    ssh "$FIELDWORK_SSH_HOST" "test -f /usr/local/sbin/rotate-pat" >/dev/null 2>&1
  }
  broker_thin_client_installed() {
    # install_thin_client links ~/.local/bin/fieldwork-pr-submit to the
    # Fieldwork scripts dir. Use -e (not -L) so a regular file copy is also
    # accepted; -e on a broken symlink returns false, which is what we want.
    if fieldwork_setup_snapshot_is_ok broker_thin_client; then
      return 0
    elif [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
      return 1
    fi
    ssh "$FIELDWORK_SSH_HOST" "test -e ~/.local/bin/fieldwork-pr-submit" >/dev/null 2>&1
  }
  broker_install_complete() {
    broker_pat_tool_installed && broker_thin_client_installed
  }
  broker_pat_marker_present() {
    if fieldwork_setup_snapshot_is_ok broker_pat_marker; then
      return 0
    elif [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
      return 1
    fi
    ssh "$FIELDWORK_SSH_HOST" "test -f ~/.fieldwork/state/broker-pat-confirmed" >/dev/null 2>&1
  }
  mark_broker_pat_confirmed() {
    local rc
    ssh "$FIELDWORK_SSH_HOST" "mkdir -p ~/.fieldwork/state && chmod 700 ~/.fieldwork && touch ~/.fieldwork/state/broker-pat-confirmed && chmod 600 ~/.fieldwork/state/broker-pat-confirmed" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && fieldwork_setup_snapshot_mark_dirty
    return "$rc"
  }
  broker_pat_sudo_confirmed() {
    if fieldwork_setup_snapshot_is_ok broker_pat_sudo; then
      return 0
    elif [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
      return 1
    fi
    ssh "$FIELDWORK_SSH_HOST" "sudo -n stat -c '%U:%G %a' /etc/fieldwork-pr-broker/gh-token 2>/dev/null | grep -qx 'fieldwork-pr-broker:fieldwork-pr-broker 600'" >/dev/null 2>&1
  }
  broker_pat_stored() {
    if broker_pat_marker_present; then
      return 0
    fi
    if broker_pat_sudo_confirmed; then
      mark_broker_pat_confirmed || true
      return 0
    fi
    return 1
  }
  install_pr_broker() {
    local rc
    ssh -t "$FIELDWORK_SSH_HOST" "$(remote_sudo_command "env FIELDWORK_SETUP_CONTEXT=guided bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh")"
    rc=$?
    [ "$rc" -eq 0 ] && fieldwork_setup_snapshot_mark_dirty
    return "$rc"
  }
  store_broker_pat() {
    local probe_repo="${1:-}"
    local password_line token_line remote_cmd sudo_prefix
    sudo_prefix="$(remote_sudo_prefix)"
    password_line="  If sudo asks for a password, enter the VPS Linux password for '$FIELDWORK_REMOTE_USER'."
    token_line="  After sudo succeeds, rotate-pat will ask for the GitHub PAT with hidden input."
    remote_cmd="printf '%s\n' '' 'VPS sudo authentication' $(shell_quote "$password_line") '  This is not your Claude account password and not the GitHub PAT.' '' 'Broker token paste' $(shell_quote "$token_line") ''; $sudo_prefix env FIELDWORK_ROTATE_PAT_TTY=1 FIELDWORK_PAT_PROBE_REPO=$(shell_quote "$probe_repo") FIELDWORK_FORGE=$(shell_quote "$FIELDWORK_FORGE") /usr/local/sbin/rotate-pat"
    ssh -t "$FIELDWORK_SSH_HOST" "$remote_cmd" || return 1
    fieldwork_setup_snapshot_mark_dirty
    mark_broker_pat_confirmed
  }
  prompt_yes_no_help() {
    local prompt="$1"
    BROKER_PROMPT_REPLY=""
    if [ "$yes" = "1" ]; then
      echo "[fieldwork] $prompt yes"
      BROKER_PROMPT_REPLY="y"
      return 0
    fi
    printf '%s [y/N/?] ' "$prompt"
    local answer=""
    if ! IFS= read -r answer; then
      echo
      BROKER_PROMPT_REPLY="n"
      return 1
    fi
    echo
    case "$answer" in
      y|Y|yes|YES)
        BROKER_PROMPT_REPLY="y"
        return 0
        ;;
      "?"|h|H|help|HELP)
        BROKER_PROMPT_REPLY="?"
        return 0
        ;;
      *)
        BROKER_PROMPT_REPLY="n"
        return 1
        ;;
    esac
  }
  broker_progress_dots() {
    local current="$1"
    local total="${2:-3}"
    local dot_done="*"
    local dot_todo="."
    if [ -t 1 ] && supports_utf8; then
      dot_done="●"
      dot_todo="○"
    fi
    local i
    i=1
    while [ "$i" -le "$total" ]; do
      if [ "$i" -le "$current" ]; then
        green "$dot_done"
      else
        printf '%s' "$dot_todo"
      fi
      i=$((i + 1))
    done
  }
  print_broker_token_progress() {
    info_heading "PR broker progress"
    if [ -t 1 ]; then
      printf 'Step %02d/%02d  %s\n' 2 3 "Add GitHub token"
    else
      printf '[%02d/%02d] %s\n' 2 3 "Add GitHub token"
    fi
  }
  print_broker_pat_help() {
    echo "  A GitHub PAT lets the broker push branches and open PRs without using"
    echo "  your personal GitHub login."
    echo
    label_line "Recommended token"
    info_row "Type" "Fine-grained personal access token"
    info_row "Repository access" "selected repositories only"
    echo
    label_line "Required permissions"
    info_bullet "Contents: Read and write"
    info_bullet "Pull requests: Read and write"
    info_bullet "Metadata: Read-only"
    info_bullet "Workflows: Read and write (normal onboarding)"
    echo
    label_line "About the Workflows permission"
    echo "  Normal 'fieldwork onboard' adds template files under .github/workflows/"
    echo "  (CI smoke checks, CodeQL, dependabot bumps). Without the Workflows"
    echo "  permission the broker cannot push those files, so onboarding will fail."
    echo "  Use 'fieldwork onboard --no-workflows <owner>/<repo>' if you intentionally"
    echo "  want to skip the workflow templates and keep the PAT narrower."
  }
  print_broker_pat_create_instructions() {
    info_heading "Create a fine-grained GitHub PAT now"
    label_line "Where to create it"
    info_row "URL"     "https://github.com/settings/personal-access-tokens/new"
    info_row "Or path" "GitHub -> Settings -> Developer settings -> Personal access tokens -> Fine-grained tokens -> Generate new token"
    echo
    label_line "Token settings"
    info_bullet "Token name: anything (e.g. fieldwork-broker)"
    info_bullet "Expiration: as long as your policy allows"
    info_bullet "Repository access: Only select repositories -> pick the repos Fieldwork will manage"
    echo
    label_line "Permissions (Repository permissions)"
    info_bullet "Contents: Read and write"
    info_bullet "Pull requests: Read and write"
    info_bullet "Metadata: Read-only (auto-selected)"
    info_bullet "Workflows: Read and write, required for normal onboarding; skip only if you will use 'fieldwork onboard --no-workflows'"
  }
  wait_for_broker_pat_ready() {
    if [ "$yes" = "1" ]; then
      echo "  Skipping broker PAT handoff because --yes was supplied."
      return 1
    fi
    label_line "Before continuing, confirm the token has"
    info_bullet "Selected repositories Fieldwork should manage"
    info_bullet "Contents: Read and write"
    info_bullet "Pull requests: Read and write"
    info_bullet "Workflows: Read and write, unless using 'fieldwork onboard --no-workflows'"
    info_bullet "Token string created and copied"
    echo
    printf "[fieldwork setup] Type 'ready' to continue, or 'skip' to do this later: "
    local answer=""
    IFS= read -r answer || true
    echo
    case "$answer" in
      ready|READY)
        return 0
        ;;
      skip|SKIP|s|S|n|N|no|NO)
        echo "  Skipped for now; setup will keep the broker token pending."
        return 1
        ;;
      *)
        echo "  Not starting the token handoff yet; type 'ready' when the token is created and copied."
        return 1
        ;;
    esac
  }
  prompt_pat_probe_repo() {
    BROKER_PAT_PROBE_REPO=""
    [ "$yes" = "1" ] && return 0
    echo
    echo "  Optionally validate the token against one repo it should manage."
    echo "  rotate-pat checks the token is live and, if you name a repo, that it"
    echo "  can reach that repo with write access before storing it."
    printf "[fieldwork setup] Repo to validate (owner/name), or Enter to skip: "
    local reply=""
    IFS= read -r reply || true
    echo
    [ -n "$reply" ] || return 0
    if valid_owner_repo "$reply"; then
      BROKER_PAT_PROBE_REPO="$reply"
    else
      echo "  '$reply' is not a valid owner/name; skipping the repo check."
    fi
  }
  print_broker_secure_handoff() {
    info_heading "Secure handoff"
    if remote_sudo_passwordless; then
      cat <<EOF
Fieldwork will connect to the VPS and ask for one secret:
  1. GitHub PAT at a hidden token prompt

Sudo on the VPS is currently passwordless (temporary setup rule), so no
sudo password is required for this step. The GitHub token paste is hidden.
rotate-pat stores it directly in the broker secret store on the VPS.
EOF
    else
      cat <<EOF
Fieldwork will connect to the VPS and ask for two secrets in order:
  1. Linux sudo password for user '$FIELDWORK_REMOTE_USER'
  2. GitHub PAT at a hidden token prompt

The sudo password is the VPS Linux password, not your Claude password
and not the GitHub token. The token paste is requested only after sudo
succeeds, and the input is hidden. rotate-pat stores it directly in the
broker secret store on the VPS.
EOF
    fi
  }
  broker_pat_guided_flow() {
    local socket_state="$1"
    info_heading "Broker GitHub token"
    label_line "The broker needs a GitHub token to"
    info_bullet "push setup branches"
    info_bullet "open pull requests"
    info_bullet "update .github/workflows/** during normal onboarding"
    echo
    label_line "Workflow permission"
    echo "  Normal 'fieldwork onboard' adds workflow templates, so the PAT needs"
    echo "  Workflows: Read and write. Leave it off only if you will run"
    echo "  'fieldwork onboard --no-workflows <owner>/<repo>'."
    print_broker_token_progress "$socket_state"

    local pat_ready=0
    while [ "$pat_ready" != "1" ]; do
      prompt_yes_no_help "[fieldwork setup] Do you already have a fine-grained GitHub PAT?" || true
      case "$BROKER_PROMPT_REPLY" in
        y)
          wait_for_broker_pat_ready || return 1
          pat_ready=1
          ;;
        "?")
          print_broker_pat_help
          print_broker_pat_create_instructions
          wait_for_broker_pat_ready || return 1
          pat_ready=1
          ;;
        *)
          print_broker_pat_create_instructions
          wait_for_broker_pat_ready || return 1
          pat_ready=1
          ;;
      esac
    done

    prompt_pat_probe_repo
    print_broker_secure_handoff
    prompt_yes_no_help "[fieldwork setup] Start broker PAT handoff?" || return 1
    case "$BROKER_PROMPT_REPLY" in
      y)
        print_handoff_block
        store_broker_pat "$BROKER_PAT_PROBE_REPO"
        ;;
      "?")
        print_broker_secure_handoff
        if confirm "[fieldwork setup] Start broker PAT handoff now?" 0; then
          print_handoff_block
          store_broker_pat "$BROKER_PAT_PROBE_REPO"
        else
          return 1
        fi
        ;;
      *)
        return 1
        ;;
    esac
  }
  print_manual_step() {
    local title="$1"
    local purpose="$2"
    local command="$3"
    info_heading "$title"
    info_row "Purpose" "$purpose"
    info_row "Command" "$command"
    case "$command" in
      *"sudo -p"*)
        info_row "Password" "enter the VPS Linux password for '$FIELDWORK_REMOTE_USER', not your Claude account password or a GitHub token."
        ;;
    esac
    print_handoff_block
  }
  maybe_run_manual_step() {
    local prompt="$1"
    if [ "$yes" = "1" ]; then
      echo "  Skipping interactive launch because --yes was supplied."
      return 1
    fi
    if confirm "$prompt" 0; then
      return 0
    fi
    echo "  Skipped for now; setup will keep this as a manual action."
    return 1
  }

  echo "Fieldwork setup"
  echo "Root: $(display_local_path "$FIELDWORK_ROOT")"
  persist_configured_agents_local || true
  if [ -t 1 ] && supports_utf8; then
    echo "Legend: $(green "✓ ready") | $(yellow "! needs action") | $(blue "→ manual step") | $(red "× blocked") | $(cyan "i") info"
  else
    echo "Legend: [ready] | [needs-action] | [manual] | [blocked] | [info]"
  fi
  echo "Safe to rerun: completed checks are detected, and pending steps are rechecked before continuing."
  print_setup_map_initial
  echo

  finish_setup_phase continue
  stage_banner 1 "Connect to VPS"
  connect_stage_start="$(fieldwork_timing_start)"
  current_phase="Connect to VPS"
  current_phase_pending_count=0
  current_phase_pending_labels=()
  local cmd
  for cmd in bash git jq ssh scp sed grep rsync; do
    if command -v "$cmd" >/dev/null 2>&1; then
      setup_row ok "$cmd found"
    else
      setup_row needs "$cmd missing" "install $cmd, then rerun fieldwork setup"
    fi
  done

  if [ -x "$HOME/.local/bin/fieldwork" ]; then
    setup_row ok "fieldwork CLI installed"
  else
    setup_row needs "fieldwork CLI symlink missing" "cd $(display_local_path "$FIELDWORK_ROOT") && bash install.sh"
  fi
  if path_contains "$HOME/.local/bin"; then
    setup_row ok "~/.local/bin is on PATH"
  else
    setup_row needs "~/.local/bin is not on PATH" "add this to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi

  local ssh_alias_configured=0
  local ssh_alias_timing_start
  ssh_alias_timing_start="$(fieldwork_timing_start)"
  if ssh_alias_looks_configured; then
    fieldwork_timing_since "ssh alias resolution" "$ssh_alias_timing_start"
    ssh_alias_configured=1
    setup_row ok "SSH alias '$FIELDWORK_SSH_HOST' resolves"
  else
    fieldwork_timing_since "ssh alias resolution" "$ssh_alias_timing_start"
    guide_missing_ssh_alias
    ssh_alias_timing_start="$(fieldwork_timing_start)"
    if ssh_alias_looks_configured; then
      fieldwork_timing_since "ssh alias resolution" "$ssh_alias_timing_start"
      ssh_alias_configured=1
      setup_row ok "SSH alias '$FIELDWORK_SSH_HOST' resolves"
    fi
  fi

  if [ "$ssh_alias_configured" != "1" ]; then
    print_setup_next "add Host $FIELDWORK_SSH_HOST to ~/.ssh/config"
    fieldwork_timing_since "connect" "$connect_stage_start"
    setup_timing_total
    return "$setup_status"
  fi

  local vps_reachable=0
  local vps_reachability_timing_start
  vps_reachability_timing_start="$(fieldwork_timing_start)"
  if progress_wait "checking VPS reachability" fieldwork_setup_snapshot_probe_connect; then
    fieldwork_timing_since "vps reachability" "$vps_reachability_timing_start"
    vps_reachable=1
    setup_vps_reachable=1
    setup_row ok "VPS reachable over SSH"
  else
    fieldwork_timing_since "vps reachability" "$vps_reachability_timing_start"
    guide_unreachable_vps
    vps_reachability_timing_start="$(fieldwork_timing_start)"
    if progress_wait "checking VPS reachability" fieldwork_setup_snapshot_probe_connect; then
      fieldwork_timing_since "vps reachability" "$vps_reachability_timing_start"
      vps_reachable=1
      setup_vps_reachable=1
      setup_row ok "VPS reachable over SSH"
    else
      local vps_next_action
      vps_next_action="$(unreachable_vps_next_action)"
      setup_row blocked "VPS is not reachable as '$FIELDWORK_SSH_HOST'" "$vps_next_action" "fieldwork setup" hard
    fi
  fi

  if [ "$vps_reachable" != "1" ]; then
    setup_block_and_exit
    fieldwork_timing_since "connect" "$connect_stage_start"
    setup_timing_total
    return "$setup_status"
  fi

  local ssh_mux_preflight_timing_start
  ssh_mux_preflight_timing_start="$(fieldwork_timing_start)"
  if fieldwork_ssh_prepare_mux; then
    :
  elif [ -n "$FIELDWORK_SSH_MUX_DISABLE_REASON" ] && [ "${FIELDWORK_SSH_MULTIPLEX:-1}" != "0" ]; then
    setup_status_line info "SSH multiplexing unavailable; using normal SSH"
  fi
  fieldwork_timing_since "ssh mux preflight" "$ssh_mux_preflight_timing_start"
  fieldwork_ssh_mux_timing_diagnostics
  if [ "$FIELDWORK_SETUP_SNAPSHOT_READY" = "1" ] && [ "$FIELDWORK_SETUP_SNAPSHOT_DIRTY" != "1" ]; then
    setup_status_line info "Remote state verified"
  elif [ "$FIELDWORK_SETUP_SNAPSHOT_PROBE_RESULT" = "reached_untrusted" ]; then
    setup_status_line info "Remote snapshot unavailable; using fallback checks"
  fi

  local remote_user
  if fieldwork_setup_snapshot_ensure; then
    remote_user="$(fieldwork_setup_snapshot_value_raw remote_user 2>/dev/null || true)"
  else
    remote_user="$(ssh "$FIELDWORK_SSH_HOST" "id -un" 2>/dev/null || true)"
  fi
  if [ "$remote_user" = "$FIELDWORK_REMOTE_USER" ]; then
    setup_row ok "remote user is $FIELDWORK_REMOTE_USER"
  else
    setup_row needs "remote user is ${remote_user:-unknown}, expected $FIELDWORK_REMOTE_USER" "fix Host $FIELDWORK_SSH_HOST User in ~/.ssh/config"
  fi
  fieldwork_timing_since "connect" "$connect_stage_start"

  finish_setup_phase continue
  stage_banner 2 "Prepare server"
  prepare_stage_start="$(fieldwork_timing_start)"
  current_phase="Prepare server"
  current_phase_pending_count=0
  current_phase_pending_labels=()
  local remote_fieldwork_ready=0
  local sync_attempted=0
  if progress_wait "checking remote Fieldwork CLI" remote_fieldwork_cli_installed; then
    setup_row ok "remote Fieldwork CLI installed"
    if progress_wait "checking remote Fieldwork checkout" remote_fieldwork_checkout_current; then
      setup_row ok "remote Fieldwork checkout matches this copy"
    elif [ "$skip_sync" = "1" ]; then
      setup_row needs "remote Fieldwork checkout differs from this copy" "fieldwork sync-vps"
      print_setup_next "fieldwork sync-vps"
      fieldwork_timing_since "prepare server" "$prepare_stage_start"
      setup_timing_total
      return "$setup_status"
    else
      setup_status_line needs "remote Fieldwork checkout differs from this copy"
      echo
      sync_attempted=1
      run_setup_sync
      fieldwork_setup_snapshot_mark_dirty
      if progress_wait "checking remote Fieldwork checkout" remote_fieldwork_checkout_current; then
        setup_row ok "remote Fieldwork checkout matches this copy"
      else
        setup_row needs "remote Fieldwork checkout still differs after sync" "fieldwork sync-vps --force-install"
        print_setup_next "fieldwork sync-vps --force-install"
        fieldwork_timing_since "prepare server" "$prepare_stage_start"
        setup_timing_total
        return "$setup_status"
      fi
    fi
  elif [ "$skip_sync" = "1" ]; then
    setup_row manual "remote Fieldwork is not installed" "fieldwork sync-vps"
  else
    setup_status_line needs "remote Fieldwork is not installed"
    echo
    sync_attempted=1
    run_setup_sync
    fieldwork_setup_snapshot_mark_dirty
    if progress_wait "checking remote Fieldwork CLI" remote_fieldwork_cli_installed; then
      setup_row ok "remote Fieldwork CLI installed"
    else
      setup_row needs "remote Fieldwork CLI missing after sync" "fieldwork sync-vps"
    fi
  fi

  if progress_wait "checking remote Fieldwork CLI" remote_fieldwork_cli_installed; then
    if progress_wait "checking VPS shell profile" remote_fieldwork_path_configured || progress_wait "updating VPS shell profile" ensure_remote_fieldwork_path; then
      [ "$sync_attempted" = "1" ] || setup_row ok "VPS shell profile can find ~/.local/bin"
      remote_fieldwork_ready=1
    else
      setup_row needs "VPS shell profile cannot find ~/.local/bin" "fieldwork sync-vps"
    fi
  fi

  if [ "$remote_fieldwork_ready" != "1" ]; then
    print_setup_next "fieldwork sync-vps"
    fieldwork_timing_since "prepare server" "$prepare_stage_start"
    setup_timing_total
    return "$setup_status"
  fi

  if progress_wait "recording configured agent support" persist_configured_agents_remote; then
    setup_row ok "configured agents recorded: $(setup_agents_file_value)"
  else
    setup_row needs "configured agents file missing" "fieldwork setup --agent $(setup_agents_file_value)"
  fi

  if progress_wait "checking VPS runtime" remote_bootstrap_ready; then
    setup_row ok "VPS runtime installed"
  else
    setup_status_line needs "VPS runtime is not installed"
    info_heading "VPS bootstrap"
    echo "  VPS bootstrap will prepare the server runtime."
    echo
    info_list_heading "This will:"
    info_bullet "install required system packages"
    if setup_agent_enabled claude; then
      info_bullet "install GitHub CLI, Docker support, and Claude Code"
    else
      info_bullet "install GitHub CLI, Docker support, and Fieldwork runner sockets"
    fi
    info_bullet "create the projects directory"
    if setup_agent_enabled claude; then
      info_bullet "install the Fieldwork agent systemd unit"
    else
      info_bullet "install Fieldwork user services used by delivery clients"
    fi
    echo
    echo "  Some steps after this require your approval in a browser or terminal."
    echo "  Fieldwork will guide those separately."
    echo "  Bootstrap shows concise progress and saves the full command log on the VPS."
    echo "  Use 'fieldwork bootstrap-vps --verbose' if you want raw installer output."
    if confirm "[fieldwork setup] Run VPS bootstrap now?" "$yes"; then
      print_handoff_block
      run_remote_bootstrap || true
    else
      set_setup_next "ssh -t $FIELDWORK_SSH_HOST 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'"
      setup_status=1
      print_setup_next "ssh -t $FIELDWORK_SSH_HOST 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'"
      fieldwork_timing_since "prepare server" "$prepare_stage_start"
      setup_timing_total
      return "$setup_status"
    fi

    if progress_wait "checking VPS runtime" remote_bootstrap_ready; then
      setup_row ok "VPS runtime installed"
    else
      setup_row needs "VPS runtime still incomplete" "ssh -t $FIELDWORK_SSH_HOST 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'"
      print_setup_next "ssh -t $FIELDWORK_SSH_HOST 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'"
      fieldwork_timing_since "prepare server" "$prepare_stage_start"
      setup_timing_total
      return "$setup_status"
    fi
  fi

  if setup_agent_enabled claude; then
    if progress_wait "checking Claude Code login status" claude_login_confirmed; then
      setup_row ok "Claude Code login previously confirmed"
    else
      print_manual_step \
        "Claude Code login" \
        "Authenticate Claude Code on the VPS so long-running remote-control sessions can start." \
        "ssh -t $FIELDWORK_SSH_HOST '~/.local/bin/claude login'"
      label_line "Expected" "  "
      info_bullet "If Claude opens an auth or device-code flow, complete it."
      info_bullet "If Claude already shows 'Welcome back', login is already done."
      info_bullet "Claude may show its own welcome screen and tips; you can ignore those for setup."
      echo
      info_row "When finished" "type exit to return to Fieldwork."
      local claude_login_status_printed=0
      if maybe_run_manual_step "[fieldwork setup] Run Claude Code login now?"; then
        ssh -t "$FIELDWORK_SSH_HOST" "~/.local/bin/claude login" || true
        fieldwork_setup_snapshot_mark_dirty
        if confirm_yes "[fieldwork setup] Was Claude Code already logged in or did login complete successfully?"; then
          if progress_run "checking Claude Code login status" "Claude Code login confirmed" confirm_claude_login_status; then
            claude_login_status_printed=1
          fi
        fi
      fi
      if [ "$claude_login_status_printed" = "1" ]; then
        :
      elif progress_wait "checking Claude Code login status" claude_login_confirmed; then
        setup_row ok "Claude Code login confirmed"
      else
        setup_row manual "Claude Code login confirmation needed" "ssh -t $FIELDWORK_SSH_HOST '~/.local/bin/claude login'" "fieldwork setup --agent $(setup_agents_file_value)" hard
      fi
    fi
  else
    setup_row ok "Claude Code login skipped for Codex-only setup"
  fi

	if setup_agent_enabled codex; then
	  local codex_install_package_q
	  codex_install_package_q="$(shell_quote "$codex_install_package")"
	  local codex_cli_ready=0
	  if progress_wait "checking Codex CLI on SSH PATH" remote_codex_cli_ready; then
	    codex_cli_ready=1
	    setup_row ok "Codex CLI available on SSH PATH"
	  else
	    print_manual_step \
	      "Codex CLI install" \
	      "Install the official Codex CLI on the VPS so the Codex Desktop SSH session can start the real codex binary." \
	      "ssh -t $FIELDWORK_SSH_HOST 'npm install -g --prefix \"\$HOME/.local\" $codex_install_package'"
	    if maybe_run_manual_step "[fieldwork setup] Install Codex CLI with npm now?"; then
	      ssh -t "$FIELDWORK_SSH_HOST" "npm install -g --prefix \"\$HOME/.local\" $codex_install_package_q" || true
	      fieldwork_setup_snapshot_mark_dirty
	    fi
	    if progress_wait "checking Codex CLI on SSH PATH" remote_codex_cli_ready; then
	      codex_cli_ready=1
	      setup_row ok "Codex CLI available on SSH PATH"
	    else
	      setup_row manual "Codex CLI not found on SSH PATH" "ssh -t $FIELDWORK_SSH_HOST 'npm install -g --prefix \"\$HOME/.local\" $codex_install_package'" "fieldwork setup --agent $(setup_agents_file_value)" hard
	    fi
	  fi
	  if [ "$codex_cli_ready" = "1" ]; then
	    if progress_wait "checking Codex CLI version" remote_codex_cli_version_ready; then
	      setup_row ok "Codex CLI version is at least $(codex_min_version)"
	    else
	      local remote_codex_version
	      remote_codex_version="$(codex_version_from_text "$(remote_codex_cli_version)")"
	      [ -n "$remote_codex_version" ] || remote_codex_version="unknown"
	      setup_row manual "Codex CLI $remote_codex_version is older than $(codex_min_version)" "$(codex_upgrade_command)" "fieldwork setup --agent $(setup_agents_file_value)" hard
	    fi
	  fi

    local codex_sandbox_helper_ready=0
    if progress_wait "checking Codex sandbox helper" remote_codex_sandbox_helper_ready; then
      codex_sandbox_helper_ready=1
      setup_row ok "Codex sandbox helper present"
    else
      setup_row needs "Codex sandbox helper missing" "fieldwork sync-vps --force-install" "fieldwork setup --agent $(setup_agents_file_value)" hard
    fi

    if [ "$codex_sandbox_helper_ready" = "1" ]; then
      local sandbox_ready_cmd
      sandbox_ready_cmd="$(codex_sandbox_ready_cmd)"
      if progress_wait "checking Codex sandbox command" remote_codex_sandbox_ready; then
        setup_row ok "Codex sandbox command works"
      else
        setup_row manual "Codex sandbox command not ready" "ssh -t $FIELDWORK_SSH_HOST 'export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"; $sandbox_ready_cmd'" "fieldwork setup --agent $(setup_agents_file_value)" hard
      fi
    fi

    if progress_wait "checking Codex login status" codex_login_confirmed; then
      setup_row ok "Codex login previously confirmed"
    else
      print_manual_step \
        "Codex login" \
        "Authenticate Codex on the VPS for the SSH app-server path. Fieldwork does not handle OpenAI credentials." \
        "ssh -t $FIELDWORK_SSH_HOST 'export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"; codex login --device-auth'"
      info_bullet "Complete the browser device-code flow."
      info_bullet "If the SSH prompt stays open, Fieldwork will stop waiting and verify login."
      if maybe_run_manual_step "[fieldwork setup] Run Codex login now?"; then
        run_codex_login_device_auth
        fieldwork_setup_snapshot_mark_dirty
        if progress_run "checking Codex login status" "Codex login confirmed" codex_login_confirmed; then
          :
        elif confirm_yes "[fieldwork setup] Did browser sign-in complete successfully?"; then
          progress_run "recording Codex login confirmation" "Codex login confirmed" confirm_codex_login_status || true
        fi
      fi
      if progress_wait "checking Codex login status" codex_login_confirmed; then
        setup_row ok "Codex login confirmed"
      else
        setup_row manual "Codex login confirmation needed" "ssh -t $FIELDWORK_SSH_HOST 'export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"; codex login --device-auth'" "fieldwork setup --agent $(setup_agents_file_value)" hard
      fi
    fi
  fi

  if [ "$setup_hard_blocked" = "1" ]; then
    setup_block_and_exit
    fieldwork_timing_since "prepare server" "$prepare_stage_start"
    setup_timing_total
    return "$setup_status"
  fi

  fieldwork_timing_since "prepare server" "$prepare_stage_start"
  finish_setup_phase continue
  stage_banner 3 "Connect GitHub"
  github_stage_start="$(fieldwork_timing_start)"
  current_phase="Connect GitHub"
  current_phase_pending_count=0
  current_phase_pending_labels=()

  if progress_wait "checking GitHub CLI authentication" github_authenticated; then
    setup_row ok "GitHub CLI authenticated"
    if [ "${FIELDWORK_SETUP_GH_AUTH_TIMEOUT_HINT:-0}" = "1" ]; then
      setup_status_line info "GitHub auth live check timed out; using saved gh config for setup"
    fi
  else
    print_manual_step \
      "GitHub CLI login" \
      "Authenticate gh for repo-resolution preflights on the VPS. Pull request pushes still use the separate broker token." \
      "ssh -t $FIELDWORK_SSH_HOST 'gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key'"
    label_line "When gh prompts" "  "
    info_bullet "Account: GitHub.com"
    info_bullet "Git protocol: SSH"
    info_bullet "Upload SSH key: skip"
    info_bullet "Auth method: Login with a web browser (preselected by Fieldwork)"
    info_bullet "Do not paste the broker token here"
    echo
    info_row "Browser hint" "the VPS has no desktop browser, so gh prints a one-time code and a 'Failed opening a web browser' line. That is expected."
    info_row "What to do" "copy the device code, open https://github.com/login/device on this workstation, paste the code there."
    info_row "Credential note" "gh may warn that credentials were saved in plain text because a headless VPS usually has no OS keychain."
    info_note "That credential is GitHub CLI's browser-login token under the fieldwork user's gh config, not the broker PAT, and Fieldwork never prints it."
    info_note "This SSH session may disconnect while you complete browser auth. Fieldwork will recheck GitHub auth afterward."
    local gh_login_status=0
    if maybe_run_manual_step "[fieldwork setup] Run GitHub CLI login now?"; then
      ssh -t "$FIELDWORK_SSH_HOST" "gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key" || gh_login_status=$?
      fieldwork_setup_snapshot_mark_dirty
    fi
    if progress_wait "checking GitHub CLI authentication" github_authenticated; then
      setup_row ok "GitHub CLI authenticated"
      if [ "${FIELDWORK_SETUP_GH_AUTH_TIMEOUT_HINT:-0}" = "1" ]; then
        setup_status_line info "GitHub auth live check timed out; using saved gh config for setup"
      fi
      if [ "$gh_login_status" != "0" ]; then
        status_info_line "The SSH session disconnected after browser auth. That is okay."
      fi
    else
      setup_row manual "GitHub CLI login needed" "ssh -t $FIELDWORK_SSH_HOST 'gh auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key'" "fieldwork setup" hard
    fi
  fi

  if [ "$setup_hard_blocked" = "1" ]; then
    setup_block_and_exit
    fieldwork_timing_since "connect github" "$github_stage_start"
    setup_timing_total
    return "$setup_status"
  fi

  if progress_wait "checking broker GitHub PAT" broker_pat_stored; then
    setup_status_line ok "Broker token stored"
  else
    setup_status_line manual "Broker token required in step 4"
  fi

  fieldwork_timing_since "connect github" "$github_stage_start"
  finish_setup_phase continue
  stage_banner 4 "Install PR services"
  services_stage_start="$(fieldwork_timing_start)"
  current_phase="Install PR services"
  current_phase_pending_count=0
  current_phase_pending_labels=()

  info_heading "Remote services"
  if setup_agent_enabled claude; then
    info_row "Purpose" "Verify the VPS service template that runs Claude sessions and the delivery runner sockets."
    if progress_wait "checking remote Claude session systemd unit" remote_claude_service_installed; then
      setup_row ok "remote Claude session systemd unit installed"
    else
      setup_row needs "remote Claude session systemd unit missing" "ssh -t $FIELDWORK_SSH_HOST 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'"
    fi
  else
    info_row "Purpose" "Verify the delivery runner sockets used from Codex SSH sessions."
    setup_row ok "Claude session systemd unit skipped for Codex-only setup"
  fi
  if ! remote_verify_runner_ready >/dev/null 2>&1 || ! remote_prepare_runner_ready >/dev/null 2>&1; then
    progress_wait "enabling runner sockets" ensure_remote_runner_sockets || true
  fi
  if progress_wait "checking verify runner sandbox" remote_verify_runner_ready; then
    setup_row ok "verify runner sandbox ready"
  else
    setup_row needs "verify runner sandbox not ready" "ssh -t $FIELDWORK_SSH_HOST 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'; fieldwork doctor --remote --explain"
  fi
  if progress_wait "checking PR prepare runner socket" remote_prepare_runner_ready; then
    setup_row ok "PR prepare runner socket installed"
  else
    setup_row needs "PR prepare runner socket missing" "ssh -t $FIELDWORK_SSH_HOST 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'"
  fi

  info_heading "PR broker"
  info_row "Purpose" "Install the separate PR broker and keep the GitHub write token outside Claude sessions."
  local broker_ready=0
  local broker_manual_flow=0
  local broker_pat_done=0
  local broker_helper_ready=0
  if progress_wait "checking PR broker helper" broker_install_complete; then
    broker_helper_ready=1
    setup_row ok "PR broker installer already ran"
  fi
  if [ "$broker_helper_ready" != "1" ]; then
    broker_manual_flow=1
    info_heading "PR broker setup"
    label_line "Fieldwork will walk through three steps"
    info_bullet "1. Install the broker daemon, socket, and rotate-pat helper."
    info_bullet "2. Store the GitHub PAT with rotate-pat (the token paste is hidden)."
    info_bullet "3. Recheck socket access; if Linux group membership is stale, reconnect and rerun setup."
    local broker_install_done=0
    if maybe_run_manual_step "[fieldwork setup] Install PR broker now?"; then
      print_handoff_block
      if install_pr_broker; then
        broker_install_done=1
        broker_helper_ready=1
        setup_row ok "PR broker installer completed"
      else
        setup_row manual "PR broker install did not complete" "$(remote_sudo_ssh_command "bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh")"
      fi
    else
      setup_row manual "PR broker install needed" "$(remote_sudo_ssh_command "bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh")"
    fi
    if [ "$broker_install_done" = "1" ] && ! progress_wait "checking PR broker install state" broker_install_complete; then
      broker_helper_ready=0
      setup_row manual "PR broker install incomplete" "$(remote_sudo_ssh_command "bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh")"
    fi
  fi

  if progress_wait "checking PR broker socket" broker_socket_writable; then
    broker_ready=1
    setup_row ok "broker socket writable"
  fi

  if [ "$broker_helper_ready" = "1" ]; then
    if progress_wait "checking broker GitHub PAT" broker_pat_stored; then
      broker_pat_done=1
      setup_row ok "Broker token stored"
    else
      broker_manual_flow=1
      local broker_socket_state="waiting"
      [ "$broker_ready" = "1" ] && broker_socket_state="done"
      if broker_pat_guided_flow "$broker_socket_state"; then
        broker_pat_done=1
        setup_row ok "Broker token stored"
      else
        setup_row manual "Broker token not installed" "$(remote_sudo_ssh_command "env FIELDWORK_ROTATE_PAT_TTY=1 /usr/local/sbin/rotate-pat")" "fieldwork setup" hard
      fi
    fi

    if [ "$broker_ready" != "1" ]; then
      if progress_wait "checking PR broker socket" broker_socket_writable; then
        broker_ready=1
        setup_row ok "broker socket writable"
      else
        setup_row manual "broker socket refresh needed" "reconnect to the VPS, then rerun fieldwork setup"
      fi
    fi
  fi

  if setup_agent_enabled codex; then
    info_heading "Codex SSH runtime"
    info_row "Purpose" "Make the Codex Desktop SSH session see Fieldwork clients and the Unix sockets allowed by Codex's sandbox."
    if progress_wait "checking Codex SSH identity" remote_codex_identity_ready; then
      setup_row ok "Codex SSH identity is $FIELDWORK_REMOTE_USER"
    else
      setup_row needs "Codex SSH identity is not $FIELDWORK_REMOTE_USER" "fix Host $FIELDWORK_SSH_HOST User in ~/.ssh/config" "fieldwork setup --agent $(setup_agents_file_value)" hard
    fi
    if progress_wait "checking delivery clients on SSH PATH" remote_delivery_clients_ready; then
      setup_row ok "delivery clients available on SSH PATH"
    else
      setup_row needs "delivery clients missing from SSH PATH" "fieldwork sync-vps --force-install" "fieldwork setup --agent $(setup_agents_file_value)" hard
    fi
    if progress_wait "checking systemd user lingering" remote_linger_ready || progress_wait "enabling systemd user lingering" ensure_remote_linger; then
      setup_row ok "systemd user lingering enabled"
    else
      setup_row manual "systemd user lingering not enabled" "$(remote_sudo_ssh_command "loginctl enable-linger $FIELDWORK_REMOTE_USER")" "fieldwork setup --agent $(setup_agents_file_value)" hard
    fi
    if progress_wait "checking XDG runtime dir" remote_xdg_runtime_ready; then
      setup_row ok "XDG runtime dir ready"
    else
      setup_row needs "XDG runtime dir missing" "reconnect to the VPS, then rerun fieldwork setup --agent $(setup_agents_file_value)" "fieldwork setup --agent $(setup_agents_file_value)" hard
    fi
    if progress_wait "writing Codex socket allowlist" write_remote_codex_socket_allowlist && progress_wait "checking Codex socket allowlist" remote_codex_socket_allowlist_ready; then
      setup_row ok "Codex socket allowlist configured"
    else
      setup_row needs "Codex socket allowlist missing" "fieldwork setup --agent $(setup_agents_file_value)" "fieldwork setup --agent $(setup_agents_file_value)" hard
    fi
    if progress_wait "probing sockets inside Codex sandbox" remote_codex_sandbox_socket_probe; then
      setup_row ok "Codex sandbox can reach Fieldwork sockets"
    else
      setup_row needs "Codex sandbox cannot reach Fieldwork sockets" "fieldwork doctor --remote --explain" "fieldwork setup --agent $(setup_agents_file_value)" hard
    fi
  fi

  if [ "$setup_hard_blocked" = "1" ]; then
    setup_block_and_exit
    fieldwork_timing_since "install pr services" "$services_stage_start"
    setup_timing_total
    return "$setup_status"
  fi

  if [ "$broker_ready" = "1" ] && { [ "$broker_manual_flow" != "1" ] || [ "$broker_pat_done" = "1" ]; } && progress_wait "checking temporary setup sudo rule" temporary_passwordless_sudo_present; then
    info_heading "Temporary sudo cleanup"
    echo "  Fieldwork can now remove the temporary passwordless sudo rule created during assisted VPS user setup."
    echo "  This restores the broker token boundary: Claude sessions should not have passwordless root after the broker is installed."
    if confirm "[fieldwork setup] Remove temporary passwordless sudo now?" "$yes"; then
      status_info_line "removing temporary setup sudo rule"
      if remove_temporary_passwordless_sudo; then
        setup_row ok "temporary passwordless sudo removed"
      else
        setup_row manual "temporary passwordless sudo still present" "$(remote_sudo_ssh_command "rm -f $(shell_quote "$(fieldwork_sudoers_path)")")"
        print_setup_next "$(remote_sudo_ssh_command "rm -f $(shell_quote "$(fieldwork_sudoers_path)")")"
        fieldwork_timing_since "install pr services" "$services_stage_start"
        setup_timing_total
        return "$setup_status"
      fi
    else
      setup_row manual "temporary passwordless sudo still present" "$(remote_sudo_ssh_command "rm -f $(shell_quote "$(fieldwork_sudoers_path)")")"
      print_setup_next "$(remote_sudo_ssh_command "rm -f $(shell_quote "$(fieldwork_sudoers_path)")")"
      fieldwork_timing_since "install pr services" "$services_stage_start"
      setup_timing_total
      return "$setup_status"
    fi
  fi

  fieldwork_timing_since "install pr services" "$services_stage_start"
  finish_setup_phase continue
  stage_banner 5 "Verify setup"
  verify_stage_start="$(fieldwork_timing_start)"
  print_setup_summary
  finish_setup_phase final
  echo
  if [ -z "$next_action" ]; then
    next_action="fieldwork onboard <owner>/<repo>"
    after_action="fieldwork smoke <owner>/<repo>"
  fi
  if [ "${#setup_remaining_labels[@]}" -gt 0 ]; then
    local remaining_word="actions"
    [ "${#setup_remaining_labels[@]}" -eq 1 ] && remaining_word="action"
    echo "Setup has ${#setup_remaining_labels[@]} remaining $remaining_word."
    echo
  fi

  if [ "$setup_status" = "0" ] && [ "$setup_summary_ready" = "1" ] && [ "${#setup_remaining_labels[@]}" -eq 0 ]; then
    echo "Setup complete."
    echo
    label_line "Next"
    echo "  $next_action"
    echo
    label_line "Then test"
    echo "  $after_action"
  else
    label_line "Next action"
    echo "  $next_action"
    echo
    label_line "After completing it"
    echo "  $after_action"
  fi
  print_remaining_after_next
  echo
  label_line "Optional"
  echo "  Notifications          fieldwork setup-notify"
  echo "  Telegram approval bot  fieldwork setup-notify --telegram-bot"
  echo "  Add/change agents      fieldwork setup --agent claude|codex|both"
  local public_ssh_rule_timing_start
  local public_ssh_rule_present=0
  public_ssh_rule_timing_start="$(fieldwork_timing_start)"
  if progress_wait "checking public SSH firewall rule" remote_public_ssh_rule_present; then
    public_ssh_rule_present=1
  fi
  fieldwork_timing_since "public ssh rule check" "$public_ssh_rule_timing_start"
  if [ "$public_ssh_rule_present" = "1" ]; then
    echo "  Harden public SSH      $(remote_sudo_ssh_command "ufw delete allow 22/tcp")"
  fi
  echo
  echo "Useful if something feels off: fieldwork doctor --remote --explain"
  fieldwork_timing_since "verify setup" "$verify_stage_start"
  setup_timing_total
  return "$setup_status"
}

random_topic() {
  if command -v openssl >/dev/null 2>&1; then
    printf 'fieldwork-%s\n' "$(openssl rand -hex 16)"
  else
    printf 'fieldwork-%s\n' "$(date +%s)-$RANDOM"
  fi
}

write_local_notify_env() {
  local topic="$1"
  mkdir -p "$HOME/.fieldwork"
  umask 077
  cat > "$HOME/.fieldwork/notify.env" <<EOF
# Managed by Fieldwork
# Fieldwork notification config. Keep this private.
NTFY_TOPIC=$topic
EOF
  chmod 600 "$HOME/.fieldwork/notify.env"
}

prompt_for_ntfy_subscription() {
  local topic="$1"
  local yes="${2:-0}"
  if [ "$yes" = "1" ]; then
    status_info_line "subscribe in the ntfy mobile app to topic $topic if this is a new topic"
    return 0
  fi

  info_heading "Ntfy mobile subscription"
  info_row "Purpose" "subscribe your phone before Fieldwork sends the test notification."
  info_row "Command" "ntfy mobile app -> Subscribe to topic -> $topic"
  echo "  Fieldwork will wait here, then send a test push when you press Enter."
  printf '[fieldwork notify] Press Enter after subscribing, or press Enter now if this phone already has the topic: '
  local ignored=""
  IFS= read -r ignored || true
  echo
}

send_local_ntfy_test() {
  local topic="$1"
  # Setup needs a real provider acknowledgment; runtime hooks stay best-effort.
  curl -fsS --connect-timeout 5 --max-time 20 \
    -d "Fieldwork ntfy test from $(hostname)" "https://ntfy.sh/$topic" >/dev/null
}

install_remote_notify_env() {
  ssh "$FIELDWORK_SSH_HOST" "mkdir -p ~/.fieldwork && chmod 700 ~/.fieldwork"
  scp -q "$HOME/.fieldwork/notify.env" "$FIELDWORK_SSH_HOST:~/.fieldwork/notify.env"
  ssh "$FIELDWORK_SSH_HOST" "chmod 600 ~/.fieldwork/notify.env"
}

send_remote_ntfy_test() {
  ssh "$FIELDWORK_SSH_HOST" 'set -eu
test -s "$HOME/.fieldwork/notify.env"
set -a
. "$HOME/.fieldwork/notify.env"
set +a
test -n "${NTFY_TOPIC:-}"
curl -fsS --connect-timeout 5 --max-time 20 \
  -d "Fieldwork ntfy test from $(hostname)" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null'
}

valid_telegram_bot_token() {
  # BotFather tokens are <numeric bot id>:<35-char alphanumeric + - _>.
  [[ "$1" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}$ ]]
}

valid_telegram_chat_id() {
  # Personal chat IDs are positive ints; group/channel IDs are negative (e.g.
  # -1001234567890). Accept either sign with 1–20 digits.
  [[ "$1" =~ ^-?[0-9]{1,20}$ ]]
}

install_remote_bot_files() {
  local remote_script="/tmp/fieldwork-install-bot-$$.sh"
  fieldwork_status_start "staging approval bot install script on VPS"
  if ! ssh "$FIELDWORK_SSH_HOST" "cat > $remote_script && chmod 600 $remote_script" <<'REMOTE'
set -e
agent_user="${1:?usage: install-bot <agent-user>}"
agent_home="$(getent passwd "$agent_user" | cut -d: -f6)"
[ -n "$agent_home" ] || { echo "cannot resolve home for '$agent_user'" >&2; exit 1; }
src_dir="$agent_home/fieldwork"
bot_src="$src_dir/lib/scripts/fieldwork-bot"
bot_unit="$src_dir/lib/systemd/fieldwork-bot.service"
[ -x "$bot_src" ] || { echo "fieldwork-bot missing at $bot_src; run 'fieldwork sync-vps --force-install'" >&2; exit 1; }
[ -f "$bot_unit" ] || { echo "fieldwork-bot.service missing at $bot_unit; run 'fieldwork sync-vps --force-install'" >&2; exit 1; }
getent group fieldwork-bot >/dev/null || groupadd --system fieldwork-bot
id fieldwork-bot >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin -g fieldwork-bot fieldwork-bot
usermod -a -G fieldwork-bot fieldwork-bot
submit_socket_group="$(stat -c '%G' /run/fieldwork-pr-broker/fieldwork-pr.sock 2>/dev/null || true)"
if [ -z "$submit_socket_group" ]; then
  submit_socket_group="$(sed -n 's/^SocketGroup=//p' /etc/systemd/system/fieldwork-pr-broker.socket 2>/dev/null | tail -1 || true)"
fi
if [ -n "$submit_socket_group" ] && id -nG fieldwork-bot | tr ' ' '\n' | grep -Fxq "$submit_socket_group"; then
  echo "bot user 'fieldwork-bot' must NOT be in submit socket group '$submit_socket_group' (would let it forge /pr requests)" >&2
  exit 1
fi
install -o root -g fieldwork-bot -m 750 -d /etc/fieldwork-bot
install -o root -g root -m 755 "$bot_src" /usr/local/bin/fieldwork-bot
install -o root -g root -m 644 "$bot_unit" /etc/systemd/system/fieldwork-bot.service
install -o fieldwork-bot -g fieldwork-bot -m 755 -d /var/lib/fieldwork-bot
[ -f /var/log/fieldwork-bot.log ] || install -o fieldwork-bot -g fieldwork-bot -m 640 /dev/null /var/log/fieldwork-bot.log

# Repair broker state created before the bot shared-dir permissions landed.
# Without this, the bot daemon crash-loops before it can poll Telegram.
broker_state="/var/lib/fieldwork-pr-broker"
if [ -d "$broker_state" ]; then
  broker_user="$(stat -c '%U' "$broker_state" 2>/dev/null || true)"
  [ -n "$broker_user" ] || { echo "cannot resolve owner for $broker_state" >&2; exit 1; }
  id "$broker_user" >/dev/null 2>&1 || { echo "broker state owner '$broker_user' is not a user" >&2; exit 1; }
  install -o "$broker_user" -g fieldwork-bot -m 2770 -d "$broker_state/pending"
  install -o "$agent_user" -g fieldwork-bot -m 2770 -d "$broker_state/notifications"
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m "u:$broker_user:rwx" "$broker_state/notifications"
    setfacl -d -m "u:$broker_user:rwx" "$broker_state/notifications"
  else
    echo "setfacl unavailable; broker lifecycle notifications need manual ACL setup for $broker_state/notifications" >&2
  fi
fi

systemctl daemon-reload
REMOTE
  then
    fieldwork_status_fail "approval bot install script staging failed"
    echo "[fieldwork notify] failed to stage the bot install script on the VPS" >&2
    return 1
  fi
  fieldwork_status_succeed "approval bot install script staged"
  local rc=0
  status_info_line "installing approval bot daemon on VPS"
  ssh -t "$FIELDWORK_SSH_HOST" "$(remote_sudo_command "bash $remote_script $(shell_quote "$FIELDWORK_REMOTE_USER")")" || rc=$?
  ssh "$FIELDWORK_SSH_HOST" "rm -f $remote_script" >/dev/null 2>&1 || true
  return $rc
}

setup_notify_telegram_bot() {
  local yes="$1"

  # Precompute glyphs ONCE in the parent shell. bot_progress_dots is
  # always called via $(...), and inside that subshell fd1 is a pipe,
  # so [ -t 1 ] there returns false and the UTF-8 branch never wins.
  # bootstrap-vps.sh handles this the same way (DOT_DONE at file scope).
  local BOT_DOT_DONE="*"
  local BOT_DOT_TODO="."
  local BOT_BULLET="-"
  local BOT_ARROW=">"
  if [ -t 1 ] && supports_utf8; then
    BOT_DOT_DONE="●"
    BOT_DOT_TODO="○"
    BOT_BULLET="•"
    BOT_ARROW="→"
  fi
  bot_progress_dots() {
    local current="$1"
    local total="$2"
    local i=1
    while [ "$i" -le "$total" ]; do
      if [ "$i" -le "$current" ]; then
        green "$BOT_DOT_DONE"
      else
        printf '%s' "$BOT_DOT_TODO"
      fi
      i=$((i + 1))
    done
  }
  print_bot_step_header() {
    local current="$1"
    local total="$2"
    local title="$3"
    echo
    if [ -t 1 ]; then
      printf 'Step %02d of %02d  %s  %s\n' "$current" "$total" "$(bot_progress_dots "$current" "$total")" "$title"
    else
      printf '[%02d/%02d] %s\n' "$current" "$total" "$title"
    fi
  }

  phase_section "Telegram Approval-Gate Bot"
  echo "  Human-in-the-loop approval for broker PR pushes, from your phone."
  echo "  The bot queues each PR in Telegram and signs approve calls to the"
  echo "  broker with an HMAC secret."
  echo
  info_row "Isolation" "the agent user never sees the Telegram token or the HMAC secret."
  echo "             Both live in /etc/fieldwork-bot/ on the VPS, readable"
  echo "             only by the fieldwork-bot user."
  echo

  if ! progress_wait "checking VPS reachability" ssh -o BatchMode=yes -o ConnectTimeout=5 "$FIELDWORK_SSH_HOST" "true"; then
    echo "[fieldwork notify] cannot reach VPS over SSH ($FIELDWORK_SSH_HOST)"
    echo "  Fix the SSH alias or your network path to the VPS, then rerun: fieldwork setup-notify --telegram-bot"
    return 1
  fi

  if ! install_remote_bot_files; then
    echo "[fieldwork notify] failed to install the bot daemon on the VPS." >&2
    echo "  If sync looks stale, run: fieldwork sync-vps --force-install" >&2
    return 1
  fi
  status_ok_line "fieldwork-bot user, binary, and systemd unit installed"

  local existing_config=0
  if progress_wait "checking existing approval bot config" ssh "$FIELDWORK_SSH_HOST" "sudo -n test -f /etc/fieldwork-bot/config.toml"; then
    existing_config=1
    echo "[fieldwork notify] /etc/fieldwork-bot/config.toml already exists on the VPS."
    if [ "$yes" != "1" ]; then
      printf '[fieldwork notify] Overwrite it? [y/N]: '
      local answer=""
      IFS= read -r answer
      case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "[fieldwork notify] keeping existing config; only the bot service will be (re)started"; existing_config=2 ;;
      esac
    fi
  fi

  local bot_token=""
  local chat_ids=()
  local hmac_secret=""

  if [ "$existing_config" != "2" ]; then
    print_bot_step_header 1 2 "Create the Telegram bot"
    echo "  1. Open Telegram and message @BotFather"
    echo "  2. Send:  /newbot"
    echo "  3. Choose a display name, then a username ending in \"bot\""
    echo "  4. BotFather replies with a token like  123456789:AAH<random>"
    echo
    while [ -z "$bot_token" ]; do
      printf '  %s Bot token (123456789:AAH...): ' "$BOT_ARROW"
      IFS= read -r bot_token
      if ! valid_telegram_bot_token "$bot_token"; then
        echo "    invalid token shape; expected <numeric>:<alphanumeric/_/-> (>= 30 chars after the colon)"
        bot_token=""
      fi
    done

    print_bot_step_header 2 2 "Add allowed chat IDs"
    echo "  A chat ID is the access list: only these accounts (or groups)"
    echo "  can approve PRs. Messages from anyone else are ignored, so add"
    echo "  only people you trust to push code on your behalf."
    echo
    echo "  To find your chat ID:"
    echo "    1. Send any message to the bot you just created"
    echo "    2. Open  https://api.telegram.org/bot<your-token>/getUpdates"
    echo "    3. Find  \"chat\":{\"id\":<number>}"
    echo "         $BOT_BULLET Personal IDs are positive          e.g.  12345678"
    echo "         $BOT_BULLET Group/channel IDs start with \"-\"   e.g.  -1001234567890"
    echo
    echo "  Enter one chat ID per line. Leave the next line blank to finish."
    while true; do
      printf '  %s chat id: ' "$BOT_ARROW"
      local id=""
      IFS= read -r id
      [ -z "$id" ] && break
      if ! valid_telegram_chat_id "$id"; then
        echo "      invalid chat id; expected an integer like 12345678 or -1001234567890"
        continue
      fi
      if [ "$id" = "${bot_token%%:*}" ]; then
        echo "      that is the bot ID from the token, not an approver chat ID"
        echo "      send the bot a message, then copy chat.id from getUpdates"
        continue
      fi
      local existing
      for existing in "${chat_ids[@]+"${chat_ids[@]}"}"; do
        [ "$existing" = "$id" ] && id="" && break
      done
      [ -n "$id" ] && chat_ids+=("$id")
    done
    if [ "${#chat_ids[@]}" -eq 0 ]; then
      echo "  at least one chat ID is required" >&2
      return 1
    fi

    hmac_secret="$(openssl rand -hex 32 2>/dev/null || true)"
    if [ -z "$hmac_secret" ]; then
      echo "[fieldwork notify] openssl is required to generate the HMAC secret" >&2
      return 1
    fi
  fi

  if [ "$existing_config" != "2" ]; then
    local tmp_config tmp_secret
    tmp_config="$(mktemp "${TMPDIR:-/tmp}/fieldwork-bot-config.XXXXXX")"
    tmp_secret="$(mktemp "${TMPDIR:-/tmp}/fieldwork-bot-secret.XXXXXX")"
    {
      printf 'bot_token = "%s"\n' "$bot_token"
      printf 'allowed_chat_ids = [%s]\n' "$(IFS=,; printf '%s' "${chat_ids[*]}")"
    } >"$tmp_config"
    printf '%s' "$hmac_secret" >"$tmp_secret"

    fieldwork_status_start "copying approval bot config to VPS"
    if scp -q "$tmp_config" "$FIELDWORK_SSH_HOST:/tmp/fieldwork-bot-config.toml" \
      && scp -q "$tmp_secret" "$FIELDWORK_SSH_HOST:/tmp/fieldwork-bot-secret"; then
      fieldwork_status_succeed "approval bot config copied to VPS"
    else
      fieldwork_status_fail "approval bot config copy failed"
      rm -f "$tmp_config" "$tmp_secret"
      return 1
    fi
    rm -f "$tmp_config" "$tmp_secret"

    status_info_line "installing approval bot config and restarting service"
    ssh -t "$FIELDWORK_SSH_HOST" "$(remote_sudo_command 'bash -lc "install -o root -g fieldwork-bot -m 640 /tmp/fieldwork-bot-config.toml /etc/fieldwork-bot/config.toml && install -o fieldwork-bot -g fieldwork-bot -m 400 /tmp/fieldwork-bot-secret /etc/fieldwork-bot/secret && rm -f /tmp/fieldwork-bot-config.toml /tmp/fieldwork-bot-secret && systemctl daemon-reload && systemctl enable --now fieldwork-bot.service && systemctl restart fieldwork-bot.service"')" || {
      echo "[fieldwork notify] remote install of bot config failed" >&2
      return 1
    }
    status_ok_line "fieldwork-bot config + HMAC secret installed and service started"
  else
    status_info_line "restarting approval bot service"
    ssh -t "$FIELDWORK_SSH_HOST" "$(remote_sudo_command 'bash -lc "systemctl enable --now fieldwork-bot.service && systemctl restart fieldwork-bot.service"')" || {
      echo "[fieldwork notify] remote restart of fieldwork-bot.service failed" >&2
      return 1
    }
    status_ok_line "fieldwork-bot.service restarted with existing config"
  fi

  if progress_wait "checking approval bot service" ssh "$FIELDWORK_SSH_HOST" "systemctl is-active --quiet fieldwork-bot.service"; then
    status_ok_line "fieldwork-bot.service is active"
  else
    setup_status_line manual "fieldwork-bot.service did not become active"
    echo "    Inspect: $(remote_sudo_ssh_command "journalctl -u fieldwork-bot.service -n 50 --no-pager")"
  fi

  echo
  label_line "Next"
  echo "  Opt a repo into the approval gate:"
  echo "    fieldwork onboard <owner>/<repo> --with-approval-gate"
  echo "  Or add .fieldwork/approval-gate to an existing repo and commit it."
}

setup_notify() {
  local remote=0
  local topic=""
  local yes=0
  local defer_remote=0
  local skip_local=0
  local telegram_bot=0
  local topic_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --remote) remote=1; shift ;;
      --topic) topic="${2:?--topic requires a value}"; topic_set=1; shift 2 ;;
      --yes) yes=1; shift ;;
      --defer-remote) defer_remote=1; shift ;;
      --skip-local) skip_local=1; shift ;;
      --telegram-bot) telegram_bot=1; shift ;;
      --help)
        cat <<'EOF'
usage: fieldwork setup-notify [--remote] [--topic <ntfy-topic>] [--yes]
       fieldwork setup-notify --telegram-bot [--yes]

ntfy mode (default): generate or reuse a private ntfy topic, write the local
and (with --remote) remote notify.env, send a test push.

Telegram bot mode: guided install of the approval-gate bot daemon on the VPS.
Prompts for a BotFather bot token + allowed chat IDs, writes
/etc/fieldwork-bot/config.toml + the HMAC secret on the VPS, then starts
fieldwork-bot.service. The bot user holds the Telegram token; the agent user
never sees it. Resumable: rerunning is safe.
EOF
        return 0
        ;;
      *) echo "unknown setup-notify argument: $1" >&2; return 2 ;;
    esac
  done

  if [ "$telegram_bot" = "1" ]; then
    if [ "$remote" = "1" ] || [ "$topic_set" = "1" ] || [ "$defer_remote" = "1" ] || [ "$skip_local" = "1" ]; then
      echo "fieldwork setup-notify --telegram-bot accepts only --yes" >&2
      return 2
    fi
    setup_notify_telegram_bot "$yes"
    return $?
  fi

  if [ -z "$topic" ] && [ -f "$HOME/.fieldwork/notify.env" ]; then
    topic="$(grep -E '^NTFY_TOPIC=.+' "$HOME/.fieldwork/notify.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [ -n "$topic" ]; then
      printf '[fieldwork notify] Reusing existing local ntfy topic from ~/.fieldwork/notify.env\n'
    fi
  fi

  if [ -z "$topic" ]; then
    topic="$(random_topic)"
    printf '[fieldwork notify] Generated ntfy topic: %s\n' "$topic"
    if [ "$yes" = "1" ]; then
      printf '[fieldwork notify] Using generated topic because --yes was supplied\n'
    else
      printf '[fieldwork notify] Press Enter to use it, or type a different private topic: '
      local entered=""
      IFS= read -r entered
      echo
      [ -z "$entered" ] || topic="$entered"
    fi
  fi

	  [[ "$topic" =~ ^[A-Za-z0-9._-]{8,128}$ ]] || {
	    echo "[fieldwork notify] invalid topic. Use 8-128 chars from A-Z a-z 0-9 . _ -" >&2
	    return 2
	  }

	  phase_section "Notifications"
	  echo "  provider: ntfy"
	  echo "  topic: $topic"

	  if [ "$skip_local" != "1" ]; then
	    phase_section "Local Notification Config"
	    progress_run "writing local notification config" "local notification config written" write_local_notify_env "$topic" \
	      || return 1
    prompt_for_ntfy_subscription "$topic" "$yes"
    if command -v curl >/dev/null 2>&1; then
      if progress_run "sending local ntfy test push" "local ntfy test push sent" send_local_ntfy_test "$topic"; then
        status_info_line "if your phone is subscribed to this topic in the ntfy.sh app, you should see the test notification now"
      else
        setup_status_line needs "local ntfy test publish was not acknowledged"
        status_info_line "a timed-out ntfy publish can still arrive; check the phone before rerunning"
      fi
    else
      status_info_line "curl missing; skipped local ntfy test push"
    fi
	  fi

	  if [ "$remote" = 1 ]; then
	    phase_section "Remote Notification Config"
	    progress_run "copying notification config to VPS" "remote notification config copied" install_remote_notify_env \
	      || return 1
    if progress_run "sending remote ntfy test push" "remote ntfy test push sent" send_remote_ntfy_test; then
      status_info_line "if your phone is subscribed to this topic in the ntfy.sh app, you should see the VPS test notification now"
	    else
	      setup_status_line needs "remote ntfy test publish was not acknowledged"
        status_info_line "a timed-out ntfy publish can still arrive; check the phone before rerunning"
	    fi
	  elif [ "$defer_remote" != "1" ]; then
	    echo
	    label_line "Next action"
	    echo "  fieldwork setup-notify --remote"
	  fi
	}

sync_vps() {
  local dry_run=0
  local yes=0
  local force_install=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --yes) yes=1; shift ;;
      --force-install) force_install=1; shift ;;
      --help)
        cat <<'EOF'
usage: fieldwork sync-vps [--dry-run] [--yes] [--force-install]

Copies the current Fieldwork checkout to ~/fieldwork on the VPS, excluding .git,
then runs bash install.sh --quiet there. --force-install passes --force too.
EOF
        return 0
        ;;
      *) echo "unknown sync-vps argument: $1" >&2; return 2 ;;
    esac
  done

  local source="$FIELDWORK_ROOT/"
  local source_display
  local source_command_display
  source_display="$(display_local_path "$source")"
  source_command_display="$(display_shell_local_path "$source")"
  local destination="$FIELDWORK_SSH_HOST:~/fieldwork/"
  local install_cmd="cd ~/fieldwork && bash install.sh --quiet"
  if [ "$force_install" = "1" ]; then
    install_cmd="$install_cmd --force"
  fi

  if [ ! -f "$FIELDWORK_ROOT/install.sh" ] || [ ! -x "$FIELDWORK_ROOT/bin/fieldwork" ] || [ ! -d "$FIELDWORK_ROOT/lib" ]; then
    echo "[fieldwork sync-vps] FAIL: source does not look like a Fieldwork checkout: $(display_local_path "$FIELDWORK_ROOT")" >&2
    echo "[fieldwork sync-vps] Run from the cloned Fieldwork repo, or reinstall the CLI symlink with: bash install.sh" >&2
    return 1
  fi

  info_heading "Remote Fieldwork install"
  info_list_heading "This will:"
  info_bullet "copy this checkout to $FIELDWORK_SSH_HOST:~/fieldwork"
  info_bullet "link Fieldwork commands and Claude assets on the VPS"
  info_bullet "add ~/.local/bin to the VPS shell profile if needed"
  echo
  info_list_heading "It will not:"
  info_bullet "install secrets"
  info_bullet "edit your local SSH config"
  info_bullet "change GitHub repositories"
  echo
  label_line "Details"
  info_row "source" "$source_display"
  info_row "destination" "$destination"
  info_row "excludes" ".git"
  info_row "remote install" "$install_cmd"

  if [ "$dry_run" = "1" ]; then
    echo
    echo "[fieldwork sync-vps] dry run only; no SSH or rsync mutation performed"
    echo "rsync -a --delete --exclude .git $source_command_display '$destination'"
    echo "ssh '$FIELDWORK_SSH_HOST' '$install_cmd'"
    echo "ssh '$FIELDWORK_SSH_HOST' 'add ~/.local/bin to ~/.profile if needed'"
    return 0
  fi

  command -v rsync >/dev/null 2>&1 || { echo "[fieldwork sync-vps] FAIL: rsync is required" >&2; return 1; }
  echo
  if ! confirm "Proceed with remote Fieldwork install?" "$yes"; then
    echo "[fieldwork sync-vps] cancelled"
    return 0
  fi

  if fieldwork_ssh_mux_configured && [ "$FIELDWORK_SSH_MUX_READY" = "1" ]; then
    if ! progress_run "checkout syncing" "checkout synced" rsync -a --delete -e "$(fieldwork_rsync_ssh_command)" --exclude .git "$source" "$destination"; then
      echo "[fieldwork sync-vps] FAIL: checkout sync failed" >&2
      return 1
    fi
  elif ! progress_run "checkout syncing" "checkout synced" rsync -a --delete --exclude .git "$source" "$destination"; then
    echo "[fieldwork sync-vps] FAIL: checkout sync failed" >&2
    return 1
  fi
  if ! progress_run "remote Fieldwork assets linking" "remote Fieldwork assets linked" ssh "$FIELDWORK_SSH_HOST" "$install_cmd"; then
    echo "[fieldwork sync-vps] FAIL: remote Fieldwork install failed" >&2
    return 1
  fi
  if ! progress_run "VPS shell profile checking ~/.local/bin" "VPS shell profile can find ~/.local/bin" ensure_remote_fieldwork_path; then
    echo "[fieldwork sync-vps] FAIL: could not update VPS shell profile" >&2
    return 1
  fi
}
