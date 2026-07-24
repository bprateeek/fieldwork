#!/usr/bin/env bash
# Install every VPS escape-side component as a root-owned system asset.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "install-boundary must run as root" >&2; exit 1; }
SRC="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$(cd -P "$SRC/../.." && pwd)"
AGENT_USER="${FIELDWORK_REMOTE_USER:-fieldwork}"
AGENT_GROUP="$(id -gn "$AGENT_USER")"
AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
[ -n "$AGENT_HOME" ] && [ "${AGENT_HOME#/}" != "$AGENT_HOME" ] || { echo "agent home is invalid" >&2; exit 1; }
LIB=/usr/local/lib/fieldwork
CLAUDE_SOURCE="$AGENT_HOME/.local/bin/claude"

install -d -o root -g root -m 0755 "$LIB" "$LIB/agents"
install -d -o root -g root -m 0755 /usr/local/share/fieldwork-claude
cp -R "$ROOT/lib/local/managed/." /usr/local/share/fieldwork-claude/
chown -R root:root /usr/local/share/fieldwork-claude
find /usr/local/share/fieldwork-claude -type d -exec chmod 0755 {} +
find /usr/local/share/fieldwork-claude -type f -exec chmod 0644 {} +
install -d -o root -g root -m 0755 /etc/claude-code
install -o root -g root -m 0644 "$ROOT/lib/local/control/strict-managed-settings.json" \
  /etc/claude-code/managed-settings.json
install -o root -g root -m 0644 "$ROOT/lib/local/control/empty-mcp.json" "$LIB/empty-mcp.json"
for name in \
  fieldwork-agent-session fieldwork-task-dispatcher fieldwork-task-run \
  fieldwork-event-poll fieldwork-verify-runner fieldwork-verify-pipeline \
  fieldwork-pr-prepare-runner fieldwork-pr-prepare-impl notify.sh \
  fieldwork-session-probe fieldwork-session-probe-cage; do
  install -o root -g root -m 0755 "$ROOT/lib/scripts/$name" "$LIB/$name"
done
install -o root -g root -m 0755 "$ROOT/lib/scripts/fieldwork-bash-policy" /usr/local/bin/fieldwork-bash-policy
install -o root -g root -m 0755 "$ROOT/lib/scripts/fieldwork-session-probe-record" /usr/local/sbin/fieldwork-session-probe-record
if [ -x "$CLAUDE_SOURCE" ]; then
  install -o root -g root -m 0755 "$CLAUDE_SOURCE" "$LIB/claude-pinned"
  claude_digest="$(/usr/bin/sha256sum "$LIB/claude-pinned" | /usr/bin/awk '{print $1}')"
  printf '%s\n' "$claude_digest" >"$LIB/claude.sha256"
  chown root:root "$LIB/claude.sha256"
  chmod 0644 "$LIB/claude.sha256"
  if [ -f "$LIB/claude.probe.sha256" ] && [ "$(/bin/cat "$LIB/claude.probe.sha256")" != "$claude_digest" ]; then
    mv "$LIB/claude.probe.sha256" "$LIB/claude.probe.sha256.changed"
  fi
else
  echo "Claude is not installed at $CLAUDE_SOURCE; Claude sessions remain unavailable (Codex-only boundary install is valid)."
fi
for adapter in "$ROOT"/lib/agents/*; do
  [ -f "$adapter" ] || continue
  install -o root -g root -m 0755 "$adapter" "$LIB/agents/$(basename "$adapter")"
done
for name in fieldwork-verify fieldwork-pr-prepare fieldwork-pr-build fieldwork-pr-upload; do
  install -o root -g root -m 0755 "$ROOT/lib/scripts/$name" "/usr/local/bin/$name"
done

install -d -o "$AGENT_USER" -g "$AGENT_GROUP" -m 0700 \
  /var/lib/fieldwork-verify /var/lib/fieldwork-pr-prepare
install -d -o "$AGENT_USER" -g "$AGENT_GROUP" -m 0750 /var/lib/fieldwork-tasks
for part in queue processing done failed; do
  install -d -o "$AGENT_USER" -g "$AGENT_GROUP" -m 0700 "/var/lib/fieldwork-tasks/$part"
done

install_unit() {
  unit="$1"
  sed \
    -e "s|^User=fieldwork$|User=$AGENT_USER|" \
    -e "s|^Group=fieldwork$|Group=$AGENT_GROUP|" \
    -e "s|^SocketUser=fieldwork$|SocketUser=$AGENT_USER|" \
    -e "s|^SocketGroup=fieldwork$|SocketGroup=$AGENT_GROUP|" \
    -e "s|/home/fieldwork|$AGENT_HOME|g" \
    "$SRC/$unit" >"/etc/systemd/system/$unit"
  chown root:root "/etc/systemd/system/$unit"
  chmod 0644 "/etc/systemd/system/$unit"
}

for unit in \
  fieldwork-agent@.service fieldwork-event-poll.service fieldwork-event-poll.timer \
  fieldwork-task-dispatcher.service fieldwork-verify-runner.socket \
  fieldwork-verify-runner@.service fieldwork-pr-prepare-runner.socket \
  fieldwork-pr-prepare-runner@.service; do
  install_unit "$unit"
done

# The dashboard is deliberately absent from hard-boundary mode. Disable stale
# user-scoped copies so they cannot shadow the root-owned system inventory.
user_units="$AGENT_HOME/.config/systemd/user"
agent_uid="$(id -u "$AGENT_USER")"
if [ -d "/run/user/$agent_uid" ]; then
  # Stop only legacy Fieldwork user units. Rootless Docker deliberately remains
  # a user service and is not touched by this migration.
  /usr/sbin/runuser -u "$AGENT_USER" -- /usr/bin/env \
    XDG_RUNTIME_DIR="/run/user/$agent_uid" PATH=/usr/bin:/bin \
    /usr/bin/systemctl --user disable --now \
      fieldwork-dashboard.service fieldwork-event-poll.timer \
      fieldwork-task-dispatcher.service fieldwork-verify-runner.socket \
      fieldwork-pr-prepare-runner.socket >/dev/null 2>&1 || true
  /usr/sbin/runuser -u "$AGENT_USER" -- /usr/bin/env \
    XDG_RUNTIME_DIR="/run/user/$agent_uid" PATH=/usr/bin:/bin \
    /usr/bin/systemctl --user stop 'fieldwork-agent@*.service' >/dev/null 2>&1 || true
fi
if [ -d "$user_units" ]; then
  for unit in \
    fieldwork-agent@.service fieldwork-dashboard.service \
    fieldwork-event-poll.service fieldwork-event-poll.timer \
    fieldwork-task-dispatcher.service fieldwork-verify-runner.socket \
    fieldwork-verify-runner@.service fieldwork-pr-prepare-runner.socket \
    fieldwork-pr-prepare-runner@.service; do
    [ ! -e "$user_units/$unit" ] || mv "$user_units/$unit" "$user_units/$unit.user-scope-disabled"
  done
fi

# Hard-boundary Claude starts with explicit root-owned settings/instructions.
# Preserve legacy convenience links for recovery, but keep them out of the
# active discovery paths so an agent-writable checkout cannot become policy.
for path in "$AGENT_HOME/.claude/settings.json" "$AGENT_HOME/.claude/CLAUDE.md"; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    disabled="$path.user-scope-disabled"
    if [ -e "$disabled" ] || [ -L "$disabled" ]; then
      [ -L "$path" ] || {
        echo "refusing to discard a new non-symlink Claude discovery file: $path" >&2
        exit 1
      }
      rm -f "$path"
    else
      mv "$path" "$disabled"
    fi
  fi
done

systemctl daemon-reload
systemctl enable --now \
  fieldwork-verify-runner.socket fieldwork-pr-prepare-runner.socket \
  fieldwork-event-poll.timer fieldwork-task-dispatcher.service
echo "Fieldwork root-owned VPS boundary installed; dashboard remains disabled."
