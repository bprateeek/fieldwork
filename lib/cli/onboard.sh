#!/usr/bin/env bash
# Sourced by bin/fieldwork. Do not execute directly.
# Contains onboard-related command handlers only.

onboard() {
  # Warm one SSH ControlMaster here and hand its socket to fieldwork-onboard so
  # its ~20 ssh/scp calls reuse a single connection instead of each paying a cold
  # handshake. The exec below would otherwise drop our ssh()/scp() mux wrappers.
  # Skip the warm-up for --help so it stays instant and works with no VPS.
  local control_path="" control_persist=""
  case " $* " in
    *" --help "*|*" -h "*) ;;
    *)
      if fieldwork_ssh_prepare_mux; then
        control_path="$(fieldwork_ssh_control_path)"
        control_persist="$(fieldwork_ssh_control_persist)"
      fi
      ;;
  esac
  FIELDWORK_PROFILE="$FIELDWORK_PROFILE" \
  FIELDWORK_FORGE="$FIELDWORK_FORGE" \
  FIELDWORK_SSH_HOST="$FIELDWORK_SSH_HOST" \
  FIELDWORK_REMOTE_USER="$FIELDWORK_REMOTE_USER" \
  FIELDWORK_PROJECTS_DIR="$FIELDWORK_PROJECTS_DIR" \
  FIELDWORK_DEFAULT_BRANCH="$FIELDWORK_DEFAULT_BRANCH" \
  FIELDWORK_SSH_CONTROL_PATH="$control_path" \
  FIELDWORK_SSH_CONTROL_PERSIST="$control_persist" \
  exec "$FIELDWORK_ROOT/lib/scripts/fieldwork-onboard" "$@"
}
