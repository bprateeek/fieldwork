#!/usr/bin/env bash
# bootstrap-vps.sh - first-boot setup for an Ubuntu 24.04 VPS.
#
# Run as the agent user (sudo-capable) after creating it manually. The agent
# user defaults to `fieldwork`; override with FIELDWORK_REMOTE_USER:
#   adduser fieldwork && usermod -aG sudo fieldwork
#   rsync ~/.ssh/authorized_keys to /home/fieldwork/.ssh/
#
# Idempotent: re-running on a partially-bootstrapped VPS is safe.
#
# IMPORTANT: This script does NOT install the `fieldwork-pr-broker` daemon.
# That has its own installer at lib/broker/install.sh, exposed as
# `fieldwork install-broker`, and must be run as root separately.

set -euo pipefail

VERBOSE=0
LOG_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    --log-file)
      LOG_FILE="${2:?--log-file requires a path}"
      shift 2
      ;;
    --help)
      echo "usage: fieldwork bootstrap-vps [--verbose] [--log-file <path>]"
      exit 0
      ;;
    *) echo "unknown bootstrap-vps argument: $1" >&2; exit 2 ;;
  esac
done

LOG_DIR="${FIELDWORK_BOOTSTRAP_LOG_DIR:-$HOME/.cache/fieldwork}"
SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd)"
# shellcheck source=lib/scripts/fieldwork-status
source "$SCRIPT_DIR/../scripts/fieldwork-status"
install -d -m 700 "$LOG_DIR"
if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$LOG_DIR/bootstrap-$(date -u +%Y%m%d-%H%M%S).log"
fi
if [ -L "$LOG_FILE" ]; then
  echo "refusing to write bootstrap log through symlink: $LOG_FILE" >&2
  exit 1
fi
umask 077
: >"$LOG_FILE"
chmod 600 "$LOG_FILE"

TOTAL_PHASES=10
PHASE_INDEX=0
CURRENT_STEP=""
SUDO_PROMPT="[sudo] VPS Linux password for '$USER': "
export SUDO_PROMPT
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

normalize_bootstrap_agents() {
  case "$1" in
    claude|codex) printf '%s\n' "$1" ;;
    both|claude,codex|codex,claude) printf 'both\n' ;;
    "") printf 'claude\n' ;;
    *) return 1 ;;
  esac
}

bootstrap_agents_raw="${FIELDWORK_SETUP_AGENTS:-}"
if [ -z "$bootstrap_agents_raw" ] && [ -f "$HOME/.fieldwork/agents" ]; then
  bootstrap_agents_raw="$(sed -n '1p' "$HOME/.fieldwork/agents" 2>/dev/null || true)"
fi
if ! FIELDWORK_BOOTSTRAP_AGENTS="$(normalize_bootstrap_agents "$bootstrap_agents_raw")"; then
  echo "invalid FIELDWORK_SETUP_AGENTS: $bootstrap_agents_raw (expected claude, codex, or both)" >&2
  exit 2
fi
export FIELDWORK_BOOTSTRAP_AGENTS

bootstrap_agent_enabled() {
  case "$FIELDWORK_BOOTSTRAP_AGENTS:$1" in
    both:claude|both:codex|claude:claude|codex:codex) return 0 ;;
    *) return 1 ;;
  esac
}

USE_COLOR=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  USE_COLOR=1
fi
HEARTBEAT_SECONDS="${FIELDWORK_PROGRESS_HEARTBEAT_SECONDS:-20}"
CURSOR_HIDDEN=0
BOOTSTRAP_ACTIVE_PID=""

hide_cursor() {
  [ -t 1 ] || return 0
  printf '\033[?25l'
  CURSOR_HIDDEN=1
}

show_cursor() {
  [ "$CURSOR_HIDDEN" = "1" ] || return 0
  printf '\033[?25h'
  CURSOR_HIDDEN=0
}

cleanup_active_child() {
  local pid="${BOOTSTRAP_ACTIVE_PID:-}"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  BOOTSTRAP_ACTIVE_PID=""
}

cleanup_terminal() {
  cleanup_active_child
  fieldwork_status_cleanup
  show_cursor
}

trap 'cleanup_terminal' EXIT
trap 'cleanup_active_child; show_cursor; trap - INT; kill -INT "$$"' INT
trap 'cleanup_active_child; show_cursor; trap - TERM; kill -TERM "$$"' TERM

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

SUDO() { command sudo -p "$SUDO_PROMPT" "$@"; }

running_mark() {
  local frame="${1:-0}"
  if [ -t 1 ]; then
    if [ "$SUPPORTS_UTF8" = "1" ]; then
      if [ $((frame % 2)) -eq 0 ]; then
        printf '•'
      else
        printf '••'
      fi
    else
      if [ $((frame % 2)) -eq 0 ]; then
        printf '.'
      else
        printf '..'
      fi
    fi
  else
    printf '...'
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

pending() {
  local frame="${1:-0}"
  local mark
  mark="$(running_mark "$frame")"
  printf '\r\033[K'
  if [ -t 1 ] && [ "$SUPPORTS_UTF8" = "1" ]; then
    printf '  %-2s Working...' "$mark"
  else
    printf '  %-4s Working...' "$mark"
  fi
}

heartbeat() {
  local elapsed="$1"
  local frame="${2:-0}"
  local mark
  mark="$(running_mark "$frame")"
  printf '\r\033[K'
  if [ -t 1 ] && [ "$SUPPORTS_UTF8" = "1" ]; then
    printf '  %-2s Still working... %ss' "$mark" "$elapsed"
  else
    printf '  %-4s Still working... %ss' "$mark" "$elapsed"
  fi
}

clear_live_line() {
  printf '\r\033[K'
}

warn() {
  if [ -t 1 ] && [ "$SUPPORTS_UTF8" = "1" ]; then
    printf '  %s  %s\n' "$(yellow "! needs action")" "$*"
  else
    printf '  [needs-action] %s\n' "$*"
  fi
}

fail() {
  if [ -t 1 ] && [ "$SUPPORTS_UTF8" = "1" ]; then
    printf '  %s  %s\n' "$(red "× blocked")" "$*" >&2
  else
    printf '  [blocked] %s\n' "$*" >&2
  fi
}

log() { note "$*"; }

refresh_sudo() {
  if SUDO -n true >/dev/null 2>&1; then
    return 0
  fi
  SUDO -v
}

sudo_ready_without_prompt() {
  SUDO -n true >/dev/null 2>&1
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
    echo "  fieldwork bootstrap-vps"
  fi
}

run_logged() {
  local optional="$1"
  local label="$2"
  shift 2
  local cmd_log status
  cmd_log="$(mktemp "${TMPDIR:-/tmp}/fieldwork-bootstrap-step.XXXXXX")"

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
  elif [ -t 1 ]; then
    local pid
    fieldwork_status_start "[$PHASE_INDEX/$TOTAL_PHASES] $label"
    set +e
    "$@" >"$cmd_log" 2>&1 &
    pid=$!
    BOOTSTRAP_ACTIVE_PID="$pid"
    wait "$pid"
    status=$?
    BOOTSTRAP_ACTIVE_PID=""
    set -e
    if [ "$status" -eq 0 ]; then
      fieldwork_status_succeed ""
    else
      fieldwork_status_fail ""
    fi
    cat "$cmd_log" >>"$LOG_FILE"
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

  if [ "$optional" = "1" ]; then
    warn "$label reported a warning; continuing"
    rm -f "$cmd_log"
    return "$status"
  fi

  fail "${CURRENT_STEP:-bootstrap} failed at: $label"
  print_failure_tail "$cmd_log"
  rm -f "$cmd_log"
  return "$status"
}

run_quiet() {
  run_logged 0 "$@"
}

run_optional() {
  run_logged 1 "$@"
}

show_version() {
  local label="$1"
  shift
  local version=""
  version="$("$@" 2>/dev/null | sed -n '1p')" || true
  [ -n "$version" ] && note "$label: $version"
}

download_to_temp() {
  local label="$1"
  local url="$2"
  local tmp
  REPLY_DOWNLOAD=""
  tmp="$(mktemp "${TMPDIR:-/tmp}/fieldwork-download.XXXXXX")"
  run_quiet "$label downloaded" curl -fsSL -o "$tmp" "$url"
  REPLY_DOWNLOAD="$tmp"
}

EXPECTED_USER="${FIELDWORK_REMOTE_USER:-fieldwork}"
[ "$(id -un)" = "$EXPECTED_USER" ] || {
  echo "must run as the '$EXPECTED_USER' user (id -un says $(id -un))" >&2
  echo "set FIELDWORK_REMOTE_USER if your agent user has a different name" >&2
  exit 1
}

echo "VPS bootstrap"
note "configured agent support: $FIELDWORK_BOOTSTRAP_AGENTS"
if ! sudo_ready_without_prompt; then
  note "sudo may prompt for the Linux password for '$USER' (not your Claude/Codex account password or GitHub token)"
fi
note "log: $LOG_FILE"
refresh_sudo

# ----- 1. base system -----
step "system packages and GitHub CLI"
# GitHub CLI and Node.js ship from their own apt repos. Set signed keyrings
# and sources before apt-get install so systemd/bwrap see the same toolchains
# as interactive shells.
refresh_sudo
run_quiet "APT keyring directory ready" SUDO install -m 0755 -d /etc/apt/keyrings
download_to_temp "GitHub CLI signing key" "https://cli.github.com/packages/githubcli-archive-keyring.gpg"
gh_key="$REPLY_DOWNLOAD"
run_quiet "GitHub CLI signing key installed" SUDO gpg --batch --yes --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg "$gh_key"
rm -f "$gh_key"
run_quiet "GitHub CLI signing key permissions set" SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
gh_source="$(mktemp "${TMPDIR:-/tmp}/fieldwork-gh-source.XXXXXX")"
printf '%s\n' "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" >"$gh_source"
run_quiet "GitHub CLI apt source configured" SUDO install -m 0644 "$gh_source" /etc/apt/sources.list.d/github-cli.list
rm -f "$gh_source"

download_to_temp "NodeSource signing key" "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key"
nodesource_key="$REPLY_DOWNLOAD"
run_quiet "NodeSource signing key installed" SUDO gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg "$nodesource_key"
rm -f "$nodesource_key"
run_quiet "NodeSource signing key permissions set" SUDO chmod go+r /etc/apt/keyrings/nodesource.gpg
nodesource_source="$(mktemp "${TMPDIR:-/tmp}/fieldwork-nodesource-source.XXXXXX")"
cat >"$nodesource_source" <<EOF
Types: deb
URIs: https://deb.nodesource.com/node_22.x
Suites: nodistro
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/nodesource.gpg
EOF
run_quiet "NodeSource apt source configured" SUDO install -m 0644 "$nodesource_source" /etc/apt/sources.list.d/nodesource.sources
rm -f "$nodesource_source"

run_quiet "Package index refreshed" SUDO apt-get update -y
packages=(
  ca-certificates curl wget jq git tmux
  bubblewrap socat
  ufw fail2ban
  logrotate
  acl
  uidmap dbus-user-session fuse-overlayfs
  python3 python3-pip
  nodejs
  gh
)
run_quiet "System packages installed" SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
show_version "git" git --version
show_version "GitHub CLI" gh --version
show_version "python" python3 --version
show_version "node" node --version
show_version "npm" npm --version
ok "system packages and GitHub CLI installed"

# ----- 1b. gitleaks (no apt package; pinned tarball) -----
step "gitleaks"
if ! command -v gitleaks >/dev/null 2>&1; then
  refresh_sudo
  download_to_temp "gitleaks archive" "https://github.com/gitleaks/gitleaks/releases/download/v8.21.2/gitleaks_8.21.2_linux_x64.tar.gz"
  gitleaks_archive="$REPLY_DOWNLOAD"
  download_to_temp "gitleaks checksums" "https://github.com/gitleaks/gitleaks/releases/download/v8.21.2/gitleaks_8.21.2_checksums.txt"
  gitleaks_checksums="$REPLY_DOWNLOAD"
  run_quiet "gitleaks archive checksum verified" bash -c '
set -euo pipefail
expected="$(grep " gitleaks_8.21.2_linux_x64.tar.gz$" "$1" | sed -n "1s/[[:space:]].*//p")"
[ -n "$expected" ]
actual="$(sha256sum "$2" | sed -n "1s/[[:space:]].*//p")"
[ "$actual" = "$expected" ]
' bash "$gitleaks_checksums" "$gitleaks_archive"
  run_quiet "gitleaks binary installed" SUDO tar -xzf "$gitleaks_archive" -C /usr/local/bin gitleaks
  rm -f "$gitleaks_checksums"
  rm -f "$gitleaks_archive"
else
  note "gitleaks is already installed"
fi
show_version "gitleaks" gitleaks version
ok "gitleaks installed"

# ----- 2. SSH hardening -----
step "SSH hardening"
sshd_conf=/etc/ssh/sshd_config
refresh_sudo
note "bootstrap disables root SSH and password SSH login; keep a non-Fieldwork sudo account for recovery before deleting the fieldwork user."
run_quiet "SSH daemon config hardened" SUDO sed -i \
  -e 's|^#\?PermitRootLogin .*|PermitRootLogin no|' \
  -e 's|^#\?PasswordAuthentication .*|PasswordAuthentication no|' \
  -e 's|^#\?ChallengeResponseAuthentication .*|ChallengeResponseAuthentication no|' \
  "$sshd_conf"
run_quiet "SSH daemon reloaded" bash -c 'sudo -p "$SUDO_PROMPT" systemctl reload ssh || sudo -p "$SUDO_PROMPT" systemctl reload sshd'
ok "SSH hardening applied"

# ----- 3. UFW (host firewall) -----
step "host firewall"
refresh_sudo
run_quiet "Firewall defaults and private network rules applied" bash -c '
set -euo pipefail
ufw_was_active=0
if sudo -p "$SUDO_PROMPT" ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw_was_active=1
fi
sudo -p "$SUDO_PROMPT" ufw default deny incoming
sudo -p "$SUDO_PROMPT" ufw default allow outgoing
if [ "$ufw_was_active" = "0" ]; then
  sudo -p "$SUDO_PROMPT" ufw allow 22/tcp comment "SSH access"
fi
sudo -p "$SUDO_PROMPT" ufw --force enable
'
ok "host firewall configured"

# ----- 4. fail2ban -----
step "fail2ban"
refresh_sudo
run_quiet "fail2ban service enabled" SUDO systemctl enable --now fail2ban
ok "fail2ban enabled"

# ----- 5. user-mode systemd linger -----
step "user services and projects directory"
refresh_sudo
run_quiet "user-mode systemd linger enabled" SUDO loginctl enable-linger "$USER"
run_quiet "projects directory ready" install -d -m 755 "$HOME/projects"
ok "user services and projects directory ready"

# ----- 6. AppArmor profiles (Ubuntu 24.04 unprivileged-userns gate) -----
step "AppArmor profiles"
ROOTLESS_PROFILE=/etc/apparmor.d/home.fieldwork.bin.rootlesskit
if [ ! -f "$ROOTLESS_PROFILE" ]; then
  refresh_sudo
  rootless_profile_tmp="$(mktemp "${TMPDIR:-/tmp}/fieldwork-rootlesskit-profile.XXXXXX")"
  cat >"$rootless_profile_tmp" <<'AAPROFILE'
abi <abi/4.0>,
include <tunables/global>

/home/fieldwork/bin/rootlesskit flags=(unconfined) {
  userns,
  include if exists <local/home.fieldwork.bin.rootlesskit>
}
AAPROFILE
  run_quiet "AppArmor rootlesskit profile installed" SUDO install -m 0644 "$rootless_profile_tmp" "$ROOTLESS_PROFILE"
  rm -f "$rootless_profile_tmp"
  run_quiet "AppArmor service restarted" SUDO systemctl restart apparmor.service
  ok "AppArmor profile installed"
else
  ok "AppArmor profile already present"
fi
BWRAP_PROFILE_SRC="$SCRIPT_DIR/../apparmor/fieldwork-bwrap"
BWRAP_PROFILE=/etc/apparmor.d/fieldwork-bwrap
if [ ! -f "$BWRAP_PROFILE_SRC" ]; then
  fail "Fieldwork bwrap AppArmor profile source missing: $BWRAP_PROFILE_SRC"
  echo "  Run fieldwork sync-vps, then rerun bootstrap-vps." >&2
  exit 1
fi
refresh_sudo
run_quiet "AppArmor bwrap profile installed" SUDO install -m 0644 "$BWRAP_PROFILE_SRC" "$BWRAP_PROFILE"
run_quiet "AppArmor bwrap profile reloaded" SUDO apparmor_parser -r "$BWRAP_PROFILE"
ok "Fieldwork bwrap AppArmor profile installed"

# ----- 7. rootless Docker -----
step "rootless Docker"
if ! command -v docker >/dev/null 2>&1; then
  download_to_temp "Docker rootless installer" "https://get.docker.com/rootless"
  docker_installer="$REPLY_DOWNLOAD"
  run_quiet "rootless Docker installed" sh "$docker_installer"
  rm -f "$docker_installer"
else
  note "Docker is already installed"
fi
# Add to user's profile so docker CLI works in subsequent sessions.
DOCKER_PROFILE='# rootless docker
export PATH=$HOME/bin:$PATH
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock'
if ! grep -q "rootless docker" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n%s\n' "$DOCKER_PROFILE" >> "$HOME/.bashrc"
fi
# Verify rootless mode.
export PATH="$HOME/bin:$PATH"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
systemctl --user enable docker.service 2>/dev/null || true
systemctl --user start docker.service 2>/dev/null || true
if docker info 2>/dev/null | grep -qi rootless; then
  show_version "Docker" docker --version
  ok "rootless Docker confirmed"
else
  note "rootless Docker not confirmed yet; reconnecting may be required"
fi
# Confirm the agent user is NOT in the `docker` group (must use rootless only).
if id -nG "$USER" | grep -qw docker; then
  note "$USER is in the docker group; removing to preserve rootless isolation"
  refresh_sudo
  run_optional "$USER removed from docker group" SUDO gpasswd -d "$USER" docker || true
fi

# ----- 8. Agent CLI -----
if bootstrap_agent_enabled claude; then
  step "Claude Code"
  if ! command -v claude >/dev/null 2>&1; then
    # claude.ai/install.sh uses bash syntax; Ubuntu's /bin/sh is dash and chokes.
    download_to_temp "Claude Code installer" "https://claude.ai/install.sh"
    claude_installer="$REPLY_DOWNLOAD"
    run_quiet "Claude Code installed" bash "$claude_installer"
    rm -f "$claude_installer"
    export PATH="$HOME/.local/bin:$PATH"
    echo 'export PATH=$HOME/.local/bin:$PATH' >> "$HOME/.bashrc"
  else
    note "Claude Code is already installed"
  fi
  run_optional "Claude Code stable channel selected" "$HOME/.local/bin/claude" install stable || true
  show_version "Claude Code" "$HOME/.local/bin/claude" --version
  ok "Claude Code installed"
else
  step "Agent CLI"
  note "Claude Code install skipped for Codex-only setup"
  ok "agent CLI bootstrap skipped"
fi

# ----- 8.5. Fieldwork user systemd units -----
step "Fieldwork systemd units"
mkdir -p "$HOME/.config/systemd/user"
units_installed=0
units=(
  fieldwork-dashboard.service
  fieldwork-event-poll.service
  fieldwork-event-poll.timer
  fieldwork-task-dispatcher.service
  fieldwork-verify-runner.socket
  fieldwork-verify-runner@.service
  fieldwork-pr-prepare-runner.socket
  fieldwork-pr-prepare-runner@.service
)
if bootstrap_agent_enabled claude; then
  units=(fieldwork-agent@.service "${units[@]}")
fi
for unit in "${units[@]}"; do
  src="$HOME/.fieldwork/infra/$unit"
  if [ -f "$src" ]; then
    run_quiet "$unit copied" cp "$src" "$HOME/.config/systemd/user/"
    units_installed=$((units_installed + 1))
  else
    note "$src missing. Run Fieldwork install.sh, then re-run bootstrap-vps."
  fi
done
if [ "$units_installed" -gt 0 ]; then
  run_optional "user systemd daemon reloaded" systemctl --user daemon-reload || note "user systemd daemon-reload failed; retry after reconnecting"
fi
# Enable + restart the runner sockets and poll timer. The sockets are cheap
# (no daemon process until first connect) and the agent's verify-before-pr skill
# expects them to exist; failing here is fail-fast onboarding, not runtime
# breakage. The restart after enable is what makes a re-bootstrap apply changed
# unit settings (e.g. socket MaxConnections); enable --now alone does not re-read
# an already-active unit. Already-accepted runner @ instances run as separate
# units and are not stopped by restarting the listening socket.
for unit in fieldwork-verify-runner.socket fieldwork-pr-prepare-runner.socket fieldwork-event-poll.timer fieldwork-task-dispatcher.service; do
  if [ -f "$HOME/.config/systemd/user/$unit" ]; then
    run_optional "$unit enabled" \
      systemctl --user enable --now "$unit" \
      || note "could not enable $unit; rerun: systemctl --user enable --now $unit"
    run_optional "$unit restarted to apply current settings" \
      systemctl --user restart "$unit" \
      || note "could not restart $unit; rerun: systemctl --user restart $unit"
  fi
done
ok "Fieldwork systemd units installed"

# ----- post -----
echo
ok "bootstrap complete"
note "Full log saved to $LOG_FILE"
if [ "${FIELDWORK_SETUP_CONTEXT:-}" = "guided" ]; then
  note "Bootstrap complete. Continuing setup from your workstation..."
else
  note "Bootstrap complete. Run fieldwork setup again for the next guided step."
fi
