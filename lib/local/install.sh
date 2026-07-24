#!/usr/bin/env bash
# Install the local hard-boundary control plane from an already verified tree.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "local install must run as root" >&2; exit 1; }
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
unset BASH_ENV ENV CDPATH PYTHONPATH PYTHONHOME COMPOSE_FILE COMPOSE_PROJECT_NAME DOCKER_HOST DOCKER_CONFIG
SRC="$(cd -P "$(dirname "$0")" && pwd)"
ROOT="$(cd -P "$SRC/../.." && pwd)"
CLAUDE_SOURCE="${FIELDWORK_CLAUDE_BIN:-$(command -v claude || true)}"
[ -n "$CLAUDE_SOURCE" ] && [ -f "$CLAUDE_SOURCE" ] || { echo "set FIELDWORK_CLAUDE_BIN to the Claude executable" >&2; exit 1; }
[ -x /usr/bin/python3 ] || { echo "/usr/bin/python3 is required for isolated boundary clients" >&2; exit 1; }

# Complete compatibility checks before creating the dedicated account, keychain,
# project tree, or any root-owned installation asset.
case "$(uname -s)" in
  Darwin)
    managed="/Library/Application Support/ClaudeCode/managed-settings.json"
    [ -x /usr/local/bin/docker ] || { echo "/usr/local/bin/docker is required for the local hard boundary" >&2; exit 1; }
    ;;
  Linux)
    managed=/etc/claude-code/managed-settings.json
    [ -x /usr/bin/docker ] || { echo "/usr/bin/docker is required for the local hard boundary" >&2; exit 1; }
    command -v setfacl >/dev/null 2>&1 || { echo "setfacl is required for inherited local-project ACLs" >&2; exit 1; }
    ;;
  *) echo "unsupported platform" >&2; exit 1 ;;
esac
if [ -e "$managed" ]; then
  if [ -L "$managed" ] || ! [ -f "$managed" ] \
    || ! /usr/bin/grep -Fq '/usr/local/lib/fieldwork-local/fieldwork-policy-helper' "$managed"; then
    echo "refusing to replace an existing unsafe or non-Fieldwork Claude managed-settings.json" >&2
    exit 1
  fi
fi
for install_parent in /usr/local/lib/fieldwork-local /usr/local/share/fieldwork-claude /usr/local/etc; do
  [ ! -L "$install_parent" ] || { echo "refusing symlinked install path: $install_parent" >&2; exit 1; }
done

case "$(uname -s)" in
  Darwin)
    if ! id fieldwork-agent >/dev/null 2>&1; then
      next_uid=503
      while id "$next_uid" >/dev/null 2>&1; do next_uid=$((next_uid + 1)); done
      dscl . -create /Users/fieldwork-agent
      dscl . -create /Users/fieldwork-agent UserShell /bin/bash
      dscl . -create /Users/fieldwork-agent UniqueID "$next_uid"
      dscl . -create /Users/fieldwork-agent PrimaryGroupID 20
      dscl . -create /Users/fieldwork-agent NFSHomeDirectory /Users/fieldwork-agent
    fi
    install -d -o fieldwork-agent -g staff -m 0700 /Users/fieldwork-agent
    install -d -o fieldwork-agent -g staff -m 0700 /Users/fieldwork-agent/Library /Users/fieldwork-agent/Library/Keychains
    keychain_secret=/usr/local/etc/fieldwork-agent.keychain-secret
    if [ ! -s "$keychain_secret" ]; then
      umask 077
      /usr/bin/openssl rand -hex 32 >"$keychain_secret"
    fi
    chown root:wheel "$keychain_secret"
    chmod 0600 "$keychain_secret"
    keychain=/Users/fieldwork-agent/Library/Keychains/login.keychain-db
    if [ ! -f "$keychain" ]; then
      /usr/bin/sudo -H -u fieldwork-agent /usr/bin/security create-keychain -p "$(/bin/cat "$keychain_secret")" "$keychain"
    fi
    /usr/bin/sudo -H -u fieldwork-agent /usr/bin/security list-keychains -d user -s "$keychain"
    /usr/bin/sudo -H -u fieldwork-agent /usr/bin/security default-keychain -d user -s "$keychain"
    install -d -o fieldwork-agent -g staff -m 0700 /Users/Shared/Fieldwork/projects
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
      chmod +a "$SUDO_USER allow list,search,add_file,add_subdirectory,delete_child,file_inherit,directory_inherit" /Users/Shared/Fieldwork/projects
    fi
    install -d -o root -g wheel -m 0755 "/Library/Application Support/ClaudeCode"
    install -o root -g wheel -m 0644 "$SRC/control/managed-settings.json" "/Library/Application Support/ClaudeCode/managed-settings.json"
    install -o root -g wheel -m 0644 "$SRC/com.fieldwork.spool-init.plist" /Library/LaunchDaemons/com.fieldwork.spool-init.plist
    ;;
  Linux)
    id fieldwork-agent >/dev/null 2>&1 || useradd --create-home --home-dir /home/fieldwork-agent --shell /bin/bash fieldwork-agent
    install -d -o fieldwork-agent -g fieldwork-agent -m 0770 /srv/fieldwork/projects
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
      setfacl -m "u:$SUDO_USER:rwx,d:u:$SUDO_USER:rwx" /srv/fieldwork/projects
    fi
    install -d -o root -g root -m 0755 /etc/claude-code
    install -o root -g root -m 0644 "$SRC/control/managed-settings.json" /etc/claude-code/managed-settings.json
    ;;
  *) echo "unsupported platform" >&2; exit 1 ;;
esac

install -d -o root -g root -m 0755 /usr/local/lib/fieldwork-local /usr/local/lib/fieldwork-local/context/lib/broker \
  /usr/local/lib/fieldwork-local/context/lib/scripts /usr/local/lib/fieldwork-local/context/lib/local \
  /usr/local/lib/fieldwork-local/context/schema /usr/local/share/fieldwork-claude /usr/local/etc
sed 's|context: ../..|context: /usr/local/lib/fieldwork-local/context|' "$SRC/docker-compose.yml" >/usr/local/lib/fieldwork-local/docker-compose.yml
chown root:root /usr/local/lib/fieldwork-local/docker-compose.yml
chmod 0644 /usr/local/lib/fieldwork-local/docker-compose.yml
install -o root -g root -m 0644 "$SRC/Dockerfile" /usr/local/lib/fieldwork-local/context/lib/local/Dockerfile
install -o root -g root -m 0644 "$ROOT/lib/broker/server.py" "$ROOT/lib/broker/policy_writer.py" "$ROOT/lib/broker/originnorm.py" /usr/local/lib/fieldwork-local/context/lib/broker/
install -o root -g root -m 0755 "$ROOT/lib/broker/git-askpass" "$ROOT/lib/broker/rotate-pat" "$ROOT/lib/broker/maintenance-submit" /usr/local/lib/fieldwork-local/context/lib/broker/
install -o root -g root -m 0755 "$ROOT/lib/scripts/fieldwork-bot" /usr/local/lib/fieldwork-local/context/lib/scripts/
install -o root -g root -m 0755 "$SRC/entrypoint.sh" "$SRC/rotate-token" "$SRC/local-admin" /usr/local/lib/fieldwork-local/context/lib/local/
install -o root -g root -m 0644 "$ROOT/schema/pr-request.schema.json" /usr/local/lib/fieldwork-local/context/schema/
install -o root -g root -m 0755 "$SRC/entrypoint.sh" "$SRC/rotate-token" /usr/local/lib/fieldwork-local/
install -o root -g root -m 0755 "$SRC/control/fieldwork-local" /usr/local/sbin/fieldwork-local
install -o root -g root -m 0755 "$SRC/control/fieldwork-policy-helper" "$SRC/control/fieldwork-local-claude" "$SRC/control/fieldwork-local-probe" "$SRC/control/spool-init" /usr/local/lib/fieldwork-local/
install -o root -g root -m 0644 "$SRC/control/strict-managed-settings.json" "$SRC/control/empty-mcp.json" /usr/local/lib/fieldwork-local/
cp -R "$SRC/managed/." /usr/local/share/fieldwork-claude/
chown -R root:root /usr/local/share/fieldwork-claude
find /usr/local/share/fieldwork-claude -type d -exec chmod 0755 {} +
find /usr/local/share/fieldwork-claude -type f -exec chmod 0644 {} +
install -o root -g root -m 0755 \
  "$ROOT/lib/scripts/fieldwork-bash-policy" \
  "$ROOT/lib/scripts/fieldwork-pr-build" "$ROOT/lib/scripts/fieldwork-pr-upload" \
  "$ROOT/lib/scripts/fieldwork-pr-prepare" "$ROOT/lib/scripts/fieldwork-verify" \
  /usr/local/bin/
install -o root -g root -m 0755 "$CLAUDE_SOURCE" /usr/local/lib/fieldwork-local/claude-pinned
if command -v shasum >/dev/null 2>&1; then digest="$(shasum -a 256 /usr/local/lib/fieldwork-local/claude-pinned | awk '{print $1}')"; else digest="$(sha256sum /usr/local/lib/fieldwork-local/claude-pinned | awk '{print $1}')"; fi
printf '%s\n' "$digest" >/usr/local/lib/fieldwork-local/claude.sha256
if [ -f /usr/local/lib/fieldwork-local/claude.probe.sha256 ] \
  && [ "$(/bin/cat /usr/local/lib/fieldwork-local/claude.probe.sha256)" != "$digest" ]; then
  mv /usr/local/lib/fieldwork-local/claude.probe.sha256 /usr/local/lib/fieldwork-local/claude.probe.sha256.changed
fi
printf '%s\n' "$(id -u fieldwork-agent)" >/usr/local/etc/fieldwork-agent.uid
chmod 0644 /usr/local/lib/fieldwork-local/claude.sha256 /usr/local/etc/fieldwork-agent.uid
/usr/local/lib/fieldwork-local/spool-init
if [ "$(uname -s)" = Darwin ]; then
  launchctl bootout system/com.fieldwork.spool-init >/dev/null 2>&1 || true
  launchctl bootstrap system /Library/LaunchDaemons/com.fieldwork.spool-init.plist
fi
echo "Local hard-boundary control plane installed. Run the hostile probe before fieldwork-local claude."
