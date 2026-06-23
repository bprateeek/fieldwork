# shellcheck shell=bash
# Sourced by bin/fieldwork. Do not execute directly.
# Public resumable quickstart command handler.

quickstart_usage() {
  cat <<'EOF'
usage: fieldwork quickstart [owner/repo] [options]

Resumable public first-run path. It runs the existing setup flow, records setup
completion under ~/.config/fieldwork/quickstart/, and when owner/repo is supplied
runs the existing onboarding flow. Completed quickstart phases are skipped on
later runs unless --reset-state is used. Use --dry-run to report remaining
friction through doctor without running setup or onboarding.

Options:
  --agent claude|codex|both   pass through to setup
  --yes                       pass through to setup
  --skip-sync                 pass through to setup
  --force-install             pass through to setup
  --branch fieldwork/init     pass through to onboard
  --no-workflows              pass through to onboard
  --with-approval-gate        pass through to onboard
  --reseed-templates          pass through to onboard
  --dry-run                   read-only preflight; do not mutate or update ledgers
  --status                    show quickstart phase state without changing it
  --reset-state               remove quickstart's phase ledger before running
EOF
}

quickstart_config_home() {
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s\n' "$XDG_CONFIG_HOME"
  else
    printf '%s/.config\n' "$HOME"
  fi
}

quickstart_safe_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

quickstart_ledger_root() {
  printf '%s/fieldwork/quickstart/%s\n' \
    "$(quickstart_config_home)" \
    "$(quickstart_safe_key "${FIELDWORK_PROFILE:-default}")"
}

quickstart_ledger_path() {
  local key="$1"
  printf '%s/%s.state\n' "$(quickstart_ledger_root)" "$(quickstart_safe_key "$key")"
}

quickstart_phase_done() {
  local ledger="$1" phase="$2"
  [ -f "$ledger" ] && grep -qx "$phase=done" "$ledger"
}

quickstart_mark_phase() {
  local ledger="$1" phase="$2" repo="${3:-}" tmp
  mkdir -p "$(dirname "$ledger")" || return 1
  tmp="$(mktemp "${ledger}.XXXXXX")" || return 1
  if [ -f "$ledger" ]; then
    grep -v -e "^$phase=" -e '^repo=' -e '^updated_at=' "$ledger" >"$tmp" || true
  fi
  [ -n "$repo" ] && printf 'repo=%s\n' "$repo" >>"$tmp"
  printf '%s=done\n' "$phase" >>"$tmp"
  printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$tmp"
  mv "$tmp" "$ledger"
}

quickstart_reset_ledger() {
  local ledger="$1"
  rm -f "$ledger"
}

quickstart_phase_label() {
  local ledger="$1" phase="$2"
  if quickstart_phase_done "$ledger" "$phase"; then
    printf 'done\n'
  else
    printf 'pending\n'
  fi
}

quickstart_print_status() {
  local owner_repo="$1" setup_ledger="$2" onboard_ledger="${3:-}"
  phase_section "Quickstart status"
  info_row "setup ledger" "$setup_ledger"
  info_row "setup" "$(quickstart_phase_label "$setup_ledger" setup)"
  if [ -n "$owner_repo" ]; then
    info_row "repo" "$owner_repo"
    info_row "onboard ledger" "$onboard_ledger"
    info_row "onboard" "$(quickstart_phase_label "$onboard_ledger" onboard)"
  else
    info_row "onboard" "not requested"
  fi
}

quickstart_preflight() {
  local owner_repo="$1" setup_ledger="$2" onboard_ledger="${3:-}"
  local repo_slug="" doctor_status=0

  if [ -n "$owner_repo" ]; then
    repo_slug="${owner_repo#*/}"
    valid_slug "$repo_slug" || { echo "invalid Fieldwork repo slug for doctor preflight: $repo_slug" >&2; return 2; }
  fi

  phase_section "Quickstart dry run"
  info_row "mutations" "none"
  info_row "setup ledger" "$setup_ledger"
  info_row "setup" "$(quickstart_phase_label "$setup_ledger" setup)"
  if [ -n "$owner_repo" ]; then
    info_row "repo" "$owner_repo"
    info_row "repo slug" "$repo_slug"
    info_row "onboard ledger" "$onboard_ledger"
    info_row "onboard" "$(quickstart_phase_label "$onboard_ledger" onboard)"
  else
    info_row "onboard" "not requested"
  fi
  status_info_line "running doctor preflight; setup and onboarding will not run"

  set +e
  if [ -n "$repo_slug" ]; then
    doctor --remote "$repo_slug" --explain
    doctor_status=$?
  else
    doctor --remote --explain
    doctor_status=$?
  fi
  set -e

  echo
  label_line "Dry run result"
  if [ "$doctor_status" = "0" ]; then
    echo "  quickstart has no blocking doctor findings for the requested scope"
  else
    echo "  quickstart would stop at the doctor finding above"
  fi
  return "$doctor_status"
}

quickstart_run_onboard() {
  local control_path="" control_persist=""
  if fieldwork_ssh_prepare_mux; then
    control_path="$(fieldwork_ssh_control_path)"
    control_persist="$(fieldwork_ssh_control_persist)"
  fi
  FIELDWORK_PROFILE="$FIELDWORK_PROFILE" \
  FIELDWORK_FORGE="$FIELDWORK_FORGE" \
  FIELDWORK_SSH_HOST="$FIELDWORK_SSH_HOST" \
  FIELDWORK_REMOTE_USER="$FIELDWORK_REMOTE_USER" \
  FIELDWORK_PROJECTS_DIR="$FIELDWORK_PROJECTS_DIR" \
  FIELDWORK_DEFAULT_BRANCH="$FIELDWORK_DEFAULT_BRANCH" \
  FIELDWORK_SSH_CONTROL_PATH="$control_path" \
  FIELDWORK_SSH_CONTROL_PERSIST="$control_persist" \
  "$FIELDWORK_ROOT/lib/scripts/fieldwork-onboard" "$@"
}

quickstart_fieldwork() {
  local owner_repo=""
  local dry_run=0
  local show_status=0
  local reset_state=0
  local setup_ledger onboard_ledger
  local -a setup_args=()
  local -a onboard_args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h)
        quickstart_usage
        return 0
        ;;
      --status)
        show_status=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --reset-state)
        reset_state=1
        shift
        ;;
      --yes|--skip-sync|--force-install)
        setup_args+=("$1")
        shift
        ;;
      --agent)
        [ -n "${2:-}" ] || { echo "--agent requires claude, codex, or both" >&2; return 2; }
        setup_args+=("$1" "$2")
        shift 2
        ;;
      --agent=*)
        setup_args+=("$1")
        shift
        ;;
      --branch)
        [ -n "${2:-}" ] || { echo "--branch requires a fieldwork/... branch" >&2; return 2; }
        onboard_args+=("$1" "$2")
        shift 2
        ;;
      --branch=*)
        onboard_args+=("$1")
        shift
        ;;
      --no-workflows|--with-approval-gate|--reseed-templates)
        onboard_args+=("$1")
        shift
        ;;
      --*)
        echo "unknown quickstart argument: $1" >&2
        return 2
        ;;
      *)
        [ -z "$owner_repo" ] || { echo "fieldwork quickstart accepts at most one <owner/repo>" >&2; return 2; }
        owner_repo="$1"
        shift
        ;;
    esac
  done

  if [ -n "$owner_repo" ]; then
    valid_owner_repo "$owner_repo" || { echo "invalid GitHub owner/repo: $owner_repo" >&2; return 2; }
    onboard_ledger="$(quickstart_ledger_path "$owner_repo")"
  elif [ "${#onboard_args[@]}" -gt 0 ]; then
    echo "quickstart onboarding flags require <owner/repo>" >&2
    return 2
  else
    onboard_ledger=""
  fi
  setup_ledger="$(quickstart_ledger_path setup)"

  if [ "$dry_run" = "1" ] && [ "$reset_state" = "1" ]; then
    echo "quickstart --dry-run cannot be combined with --reset-state" >&2
    return 2
  fi
  if [ "$dry_run" = "1" ] && [ "$show_status" = "1" ]; then
    echo "quickstart --dry-run cannot be combined with --status" >&2
    return 2
  fi

  if [ "$reset_state" = "1" ]; then
    quickstart_reset_ledger "$setup_ledger"
    [ -z "$onboard_ledger" ] || quickstart_reset_ledger "$onboard_ledger"
  fi

  if [ "$show_status" = "1" ]; then
    quickstart_print_status "$owner_repo" "$setup_ledger" "$onboard_ledger"
    return 0
  fi

  if [ "$dry_run" = "1" ]; then
    quickstart_preflight "$owner_repo" "$setup_ledger" "$onboard_ledger"
    return $?
  fi

  phase_section "Quickstart"
  info_row "setup ledger" "$setup_ledger"
  [ -n "$owner_repo" ] && info_row "onboard ledger" "$onboard_ledger"

  if quickstart_phase_done "$setup_ledger" setup; then
    setup_status_line ok "setup phase already completed"
  else
    phase_section "Setup"
    setup_fieldwork "${setup_args[@]}"
    quickstart_mark_phase "$setup_ledger" setup
    status_ok_line "setup phase recorded"
  fi

  if [ -z "$owner_repo" ]; then
    echo
    label_line "Next action"
    echo "  fieldwork quickstart <owner/repo>"
    return 0
  fi

  if quickstart_phase_done "$onboard_ledger" onboard; then
    setup_status_line ok "onboarding phase already completed"
  else
    phase_section "Onboard"
    quickstart_run_onboard "$owner_repo" "${onboard_args[@]}"
    quickstart_mark_phase "$onboard_ledger" onboard "$owner_repo"
    status_ok_line "onboarding phase recorded"
  fi

  phase_section "Quickstart complete"
  status_ok_line "setup and onboarding phases are complete"
  echo
  label_line "Next action"
  echo "  fieldwork smoke $owner_repo"
}
