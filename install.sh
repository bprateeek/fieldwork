#!/usr/bin/env bash
# Install Fieldwork's local assets for the current user.
#
# This does not install secrets and does not mutate any GitHub repositories.
# It symlinks Fieldwork-managed scripts and templates into ~/.fieldwork,
# Claude Code config into ~/.claude, and the `fieldwork` CLI into ~/.local/bin.

set -euo pipefail

FORCE=0
VERBOSE=0
QUIET=0
FIELDWORK_UI_COLOR=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  FIELDWORK_UI_COLOR=1
fi

usage() {
  cat <<'EOF'
usage: bash install.sh [--force] [--verbose] [--quiet]

Options:
  --force    back up existing files and replace blocking symlinks
  --verbose  print each source and destination symlink
  --quiet    suppress first-run UI; intended for scripted remote installs
  --help     show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --verbose) VERBOSE=1 ;;
    --quiet) QUIET=1 ;;
    --help)
      usage
      exit 0
      ;;
    *) echo "[install] unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
linked=0
already=0
skipped=0
backed_up=0
GROUP_LABEL=""
GROUP_TOTAL=0
GROUP_LINKED=0
GROUP_ALREADY=0
GROUP_SKIPPED=0
GROUP_BACKED_UP=0
GROUP_BLOCKED=""

verbose() {
  [ "$VERBOSE" = "1" ] || return 0
  echo "[install] $*"
}

verbose_err() {
  [ "$VERBOSE" = "1" ] || return 0
  echo "[install] $*" >&2
}

supports_utf8() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf8*) return 0 ;;
    *) return 1 ;;
  esac
}

use_color() {
  [ "$FIELDWORK_UI_COLOR" = "1" ]
}

green() {
  if use_color; then
    printf '\033[32m%s\033[0m' "$1"
  else
    printf '%s' "$1"
  fi
}

yellow() {
  if use_color; then
    printf '\033[33m%s\033[0m' "$1"
  else
    printf '%s' "$1"
  fi
}

print_intro() {
  cat <<'EOF'
Fieldwork install

Installs the fieldwork command and Claude helper files locally.
No secrets, repos, SSH config, or VPS settings are touched.
EOF
}

status_symbol() {
  case "$1" in
    ok)
      if supports_utf8; then green "✓"; else printf 'ok'; fi
      ;;
    warn)
      if supports_utf8; then yellow "!"; else printf '!'; fi
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

print_row() {
  local status="$1"
  local label="$2"
  local detail="${3:-}"
  if [ -n "$detail" ]; then
    printf '  %s %-24s %s\n' "$(status_symbol "$status")" "$label" "$detail"
  else
    printf '  %s %s\n' "$(status_symbol "$status")" "$label"
  fi
}

display_path() {
  local path="$1"
  case "$path" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${path#$HOME/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

start_group() {
  GROUP_LABEL="$1"
  GROUP_TOTAL=0
  GROUP_LINKED=0
  GROUP_ALREADY=0
  GROUP_SKIPPED=0
  GROUP_BACKED_UP=0
  GROUP_BLOCKED=""
}

record_group_state() {
  local prefix="$1"
  case "$prefix" in
    command)
      command_label="$GROUP_LABEL"
      command_total="$GROUP_TOTAL"
      command_skipped="$GROUP_SKIPPED"
      command_blocked="$GROUP_BLOCKED"
      ;;
    claude)
      claude_label="$GROUP_LABEL"
      claude_total="$GROUP_TOTAL"
      claude_skipped="$GROUP_SKIPPED"
      claude_blocked="$GROUP_BLOCKED"
      ;;
    template)
      template_label="$GROUP_LABEL"
      template_total="$GROUP_TOTAL"
      template_skipped="$GROUP_SKIPPED"
      template_blocked="$GROUP_BLOCKED"
      ;;
    vps)
      vps_label="$GROUP_LABEL"
      vps_total="$GROUP_TOTAL"
      vps_skipped="$GROUP_SKIPPED"
      vps_blocked="$GROUP_BLOCKED"
      ;;
  esac
}

print_install_row() {
  local label="$1"
  local total="$2"
  local blocked="$3"
  local show_count="${4:-1}"
  if [ "$blocked" -gt 0 ]; then
    if [ "$blocked" -eq 1 ]; then
      print_row warn "$label" "1 file blocked"
    else
      print_row warn "$label" "$blocked files blocked"
    fi
  elif [ "$show_count" = "1" ] && [ "$total" -gt 1 ]; then
    print_row ok "$label" "($total files)"
  else
    print_row ok "$label"
  fi
}

print_blocked_group() {
  local label="$1"
  local blocked_count="$2"
  local blocked_paths="$3"
  [ "$blocked_count" -gt 0 ] || return 0
  if [ "$blocked_count" -eq 1 ]; then
    echo "  ! $label: 1 file blocked"
  else
    echo "  ! $label: $blocked_count files blocked"
  fi
  printf '%s' "$blocked_paths" | while IFS= read -r blocked_path; do
    [ -n "$blocked_path" ] || continue
    printf '      %s\n' "$(display_path "$blocked_path")"
  done
  echo
}

link_one() {
  local src="$1"
  local dst="$2"
  GROUP_TOTAL=$((GROUP_TOTAL + 1))
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ]; then
    local current
    current="$(readlink "$dst")"
    if [ "$current" = "$src" ]; then
      verbose "ok: $dst -> $src"
      already=$((already + 1))
      GROUP_ALREADY=$((GROUP_ALREADY + 1))
      return 0
    fi
    if [ "$FORCE" = "1" ]; then
      verbose "replace symlink: $dst was $current"
      rm -f "$dst"
    else
      verbose_err "skip: $dst is a symlink to $current; pass --force to replace"
      skipped=$((skipped + 1))
      GROUP_SKIPPED=$((GROUP_SKIPPED + 1))
      GROUP_BLOCKED="${GROUP_BLOCKED}${dst}
"
      return 0
    fi
  elif [ -e "$dst" ]; then
    if [ "$FORCE" = "1" ]; then
      local backup="$dst.bak-$(date +%s)"
      mv "$dst" "$backup"
      backed_up=$((backed_up + 1))
      GROUP_BACKED_UP=$((GROUP_BACKED_UP + 1))
      verbose "backup: $dst -> $backup"
    else
      verbose_err "skip: $dst exists; pass --force to back it up and replace"
      skipped=$((skipped + 1))
      GROUP_SKIPPED=$((GROUP_SKIPPED + 1))
      GROUP_BLOCKED="${GROUP_BLOCKED}${dst}
"
      return 0
    fi
  fi
  ln -s "$src" "$dst"
  verbose "linked: $dst -> $src"
  linked=$((linked + 1))
  GROUP_LINKED=$((GROUP_LINKED + 1))
}

mkdir -p "$HOME/.fieldwork/scripts" "$HOME/.fieldwork/infra" "$HOME/.fieldwork/templates" "$HOME/.fieldwork/state" "$HOME/.local/bin"
if [ ! -f "$HOME/.fieldwork/agents" ]; then
  umask 077
  printf 'claude\n' > "$HOME/.fieldwork/agents"
  chmod 600 "$HOME/.fieldwork/agents"
fi

start_group "fieldwork command"
link_one "$ROOT/bin/fieldwork" "$HOME/.local/bin/fieldwork"
# fieldwork-verify (the unix-socket client) is invoked by the /verify-before-pr
# skill via its absolute ~/.local/bin path so it can be listed in the agent's
# `sandbox.excludedCommands`. fieldwork-verify-runner is invoked by systemd
# socket activation, also via ~/.local/bin so the user unit's ExecStart is
# stable. Mirror the fieldwork-pr-submit shape: ~/.fieldwork/scripts/ holds the
# canonical file, ~/.local/bin/ holds the symlink. fieldwork-verify-pipeline
# is reached relative to the runner's location, so only ~/.fieldwork/scripts/.
link_one "$HOME/.fieldwork/scripts/fieldwork-verify" "$HOME/.local/bin/fieldwork-verify"
link_one "$HOME/.fieldwork/scripts/fieldwork-verify-runner" "$HOME/.local/bin/fieldwork-verify-runner"
# fieldwork-pr-prepare mirrors the verify split: client + runner go to both
# canonical (~/.fieldwork/scripts/) and user-facing (~/.local/bin/) locations;
# fieldwork-pr-prepare-impl stays canonical-only and is resolved relative to
# the runner via readlink -f.
link_one "$HOME/.fieldwork/scripts/fieldwork-pr-prepare" "$HOME/.local/bin/fieldwork-pr-prepare"
link_one "$HOME/.fieldwork/scripts/fieldwork-pr-prepare-runner" "$HOME/.local/bin/fieldwork-pr-prepare-runner"
link_one "$HOME/.fieldwork/scripts/fieldwork-setup-probe" "$HOME/.local/bin/fieldwork-setup-probe"
link_one "$HOME/.fieldwork/scripts/fieldwork-codex-sandbox" "$HOME/.local/bin/fieldwork-codex-sandbox"
# fieldwork-task-enqueue is invoked by `fieldwork task add` over SSH and by the
# Telegram /task handler; both reach it via the stable ~/.local/bin path.
link_one "$HOME/.fieldwork/scripts/fieldwork-task-enqueue" "$HOME/.local/bin/fieldwork-task-enqueue"
# The dispatcher (one_shot_job scheduler) spawns the runner via ~/.local/bin.
link_one "$HOME/.fieldwork/scripts/fieldwork-task-run" "$HOME/.local/bin/fieldwork-task-run"
link_one "$HOME/.fieldwork/scripts/fieldwork-task-dispatcher" "$HOME/.local/bin/fieldwork-task-dispatcher"
record_group_state command

start_group "Claude helpers"
for script in fieldwork-status fieldwork-status-snapshot fieldwork-dashboard-server fieldwork-clone fieldwork-init fieldwork-launch fieldwork-pr-submit fieldwork-agent-session fieldwork-task-enqueue fieldwork-task-run fieldwork-task-dispatcher fieldwork-event-poll fieldwork-setup-probe fieldwork-session-probe fieldwork-codex-sandbox fieldwork-verify fieldwork-verify-runner fieldwork-verify-pipeline fieldwork-pr-prepare fieldwork-pr-prepare-runner fieldwork-pr-prepare-impl notify.sh; do
  link_one "$ROOT/lib/scripts/$script" "$HOME/.fieldwork/scripts/$script"
done
link_one "$ROOT/lib/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
link_one "$ROOT/lib/claude/settings.json" "$HOME/.claude/settings.json"
record_group_state claude

start_group "repo template"
link_one "$ROOT/lib/templates/repo" "$HOME/.fieldwork/templates/repo"
record_group_state template

start_group "VPS support files"
link_one "$ROOT/lib/systemd/fieldwork-agent@.service" "$HOME/.fieldwork/infra/fieldwork-agent@.service"
link_one "$ROOT/lib/systemd/fieldwork-dashboard.service" "$HOME/.fieldwork/infra/fieldwork-dashboard.service"
link_one "$ROOT/lib/systemd/fieldwork-verify-runner.socket" "$HOME/.fieldwork/infra/fieldwork-verify-runner.socket"
link_one "$ROOT/lib/systemd/fieldwork-verify-runner@.service" "$HOME/.fieldwork/infra/fieldwork-verify-runner@.service"
link_one "$ROOT/lib/systemd/fieldwork-event-poll.service" "$HOME/.fieldwork/infra/fieldwork-event-poll.service"
link_one "$ROOT/lib/systemd/fieldwork-event-poll.timer" "$HOME/.fieldwork/infra/fieldwork-event-poll.timer"
link_one "$ROOT/lib/systemd/fieldwork-task-dispatcher.service" "$HOME/.fieldwork/infra/fieldwork-task-dispatcher.service"
link_one "$ROOT/lib/systemd/fieldwork-pr-prepare-runner.socket" "$HOME/.fieldwork/infra/fieldwork-pr-prepare-runner.socket"
link_one "$ROOT/lib/systemd/fieldwork-pr-prepare-runner@.service" "$HOME/.fieldwork/infra/fieldwork-pr-prepare-runner@.service"
link_one "$ROOT/lib/agents" "$HOME/.fieldwork/infra/agents"
link_one "$ROOT/lib/broker" "$HOME/.fieldwork/infra/fieldwork-pr-broker"
record_group_state vps

path_ok=0
case ":$PATH:" in
  *":$HOME/.local/bin:"*) path_ok=1 ;;
esac

if [ "$QUIET" = "1" ]; then
  if [ "$skipped" -gt 0 ]; then
    echo "[install] skipped $skipped assets; rerun without --quiet to inspect blockers" >&2
    exit 1
  fi
  exit 0
fi

print_intro
echo
if [ "$skipped" -eq 0 ] && [ "$linked" -eq 0 ] && [ "$backed_up" -eq 0 ]; then
  echo "Everything is already up to date."
  echo
elif [ "$skipped" -gt 0 ] && [ "$command_skipped" -eq 0 ]; then
  echo "Installed the fieldwork command, but some helper files could not be updated"
  echo "because existing files are in the way."
  echo
elif [ "$skipped" -gt 0 ]; then
  echo "Some Fieldwork files could not be installed because existing files are in the way."
  echo
elif [ "$path_ok" != "1" ]; then
  echo "Installed Fieldwork locally."
  echo
fi

echo "Installing"
count_details=1
if [ "$skipped" -eq 0 ] && [ "$linked" -eq 0 ] && [ "$backed_up" -eq 0 ]; then
  count_details=0
fi
print_install_row "$command_label" "$command_total" "$command_skipped" 0
print_install_row "$claude_label" "$claude_total" "$claude_skipped" "$count_details"
print_install_row "$template_label" "$template_total" "$template_skipped" 0
print_install_row "$vps_label" "$vps_total" "$vps_skipped" "$count_details"
if [ "$path_ok" = "1" ]; then
  print_row ok "PATH check"
else
  print_row warn "PATH check"
fi

if [ "$skipped" -gt 0 ]; then
  echo
  echo "Needs attention"
  print_blocked_group "$command_label" "$command_skipped" "$command_blocked"
  print_blocked_group "$claude_label" "$claude_skipped" "$claude_blocked"
  print_blocked_group "$template_label" "$template_skipped" "$template_blocked"
  print_blocked_group "$vps_label" "$vps_skipped" "$vps_blocked"
  echo "To inspect all details:"
  echo "  bash install.sh --verbose"
  echo
  echo "To replace blockers safely:"
  echo "  bash install.sh --force"
  echo
  echo "  --force backs up replaced files as <path>.bak-<timestamp>"
  echo
  echo "Next after fixing:"
  echo "  fieldwork setup"
  exit 0
fi

if [ "$path_ok" != "1" ]; then
  echo
  echo "Needs attention"
  echo "  ~/.local/bin is not on PATH."
  echo
  echo "Add this to your shell profile:"
  echo
  echo '  export PATH="$HOME/.local/bin:$PATH"'
  echo
  echo "Then restart your terminal or run:"
  echo
  case "${SHELL:-}" in
    */zsh) echo "  source ~/.zshrc" ;;
    */bash) echo "  source ~/.bashrc" ;;
    *) echo "  source ~/.zshrc" ;;
  esac
  echo
  echo "Next"
  echo "  fieldwork setup"
  exit 0
fi

if [ "$linked" -gt 0 ] || [ "$backed_up" -gt 0 ]; then
  echo
  echo "Ready."
  echo
  echo "  fieldwork    ~/.local/bin/fieldwork"
  echo "  PATH         ok"
fi

echo
echo "Next"
echo "  fieldwork setup"
if [ "$linked" -gt 0 ] || [ "$backed_up" -gt 0 ]; then
  echo
  echo "For details: bash install.sh --verbose"
fi
