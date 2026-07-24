#!/usr/bin/env bash
# Root-only, convergent protocol-v2 broker install from a verified artifact.
set -euo pipefail

BROKER_USER="${FIELDWORK_BROKER_USER:-fieldwork-pr-broker}"
AGENT_USER="${FIELDWORK_REMOTE_USER:-fieldwork}"
BROKER_SOCKET_GROUP="${FIELDWORK_BROKER_SOCKET_GROUP:-}"
BROKER_BOT_GROUP="${FIELDWORK_BROKER_BOT_GROUP:-fieldwork-bot}"
CONFIG_DIR="/etc/fieldwork-pr-broker"
STATE_DIR="/var/lib/fieldwork-pr-broker"
LIB_DIR="/usr/local/lib/fieldwork-pr-broker"

usage() {
  cat <<'EOF'
usage: sudo bash install.sh

Installs the checkout-blind Fieldwork broker, protocol-v2 clients, broker-owned
policy writer, split pending stores, persistent MAC key, and system sockets.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

SRC="$(cd -P "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd -P "$SRC/../.." && pwd)"
id "$AGENT_USER" >/dev/null 2>&1 || { echo "agent user '$AGENT_USER' is missing" >&2; exit 1; }
if ! id "$BROKER_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$BROKER_USER"
fi
if ! id fieldwork-bot >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin fieldwork-bot
fi
if [ -z "$BROKER_SOCKET_GROUP" ]; then
  BROKER_SOCKET_GROUP="$(id -gn "$AGENT_USER")"
fi
getent group "$BROKER_SOCKET_GROUP" >/dev/null || groupadd --system "$BROKER_SOCKET_GROUP"
getent group "$BROKER_BOT_GROUP" >/dev/null || groupadd --system "$BROKER_BOT_GROUP"
if id "$AGENT_USER" | grep -qw "$BROKER_BOT_GROUP"; then
  echo "agent user must not be a member of the approval group '$BROKER_BOT_GROUP'" >&2
  exit 1
fi

# Protocol-v1 used named/default ACLs to share broker state with the agent.
# Remove those upgrade artifacts before applying the protocol-v2 split-store
# ownership below. find selects real directories/files, so symlinks are never
# passed to setfacl.
if [ -d "$STATE_DIR" ] && command -v setfacl >/dev/null 2>&1; then
  find "$STATE_DIR" -xdev \( -type d -o -type f \) \
    -exec setfacl -b -k -- {} +
fi

install -d -o "$BROKER_USER" -g "$BROKER_USER" -m 700 "$CONFIG_DIR"
install -d -o root -g root -m 755 "$LIB_DIR"
install -d -o "$BROKER_USER" -g "$BROKER_BOT_GROUP" -m 710 "$STATE_DIR"
install -d -o "$BROKER_USER" -g "$BROKER_USER" -m 700 \
  "$STATE_DIR/requests" "$STATE_DIR/pending-pack" \
  "$STATE_DIR/tombstones" "$STATE_DIR/work" "$STATE_DIR/keys" "$STATE_DIR/ca"
install -d -o "$BROKER_USER" -g "$BROKER_USER" -m 750 "$STATE_DIR/policy"
install -d -o "$BROKER_USER" -g "$BROKER_BOT_GROUP" -m 750 "$STATE_DIR/pending-meta"
install -d -o "$BROKER_USER" -g "$BROKER_BOT_GROUP" -m 2770 \
  "$STATE_DIR/pending-sidecar" "$STATE_DIR/notifications"
install -d -o root -g fieldwork-bot -m 0750 /etc/fieldwork-bot
install -d -o fieldwork-bot -g fieldwork-bot -m 700 /var/lib/fieldwork-bot

# Clearing an extended ACL restores its underlying group bits. Reassert the
# group-readable/writable modes required by the bot for any durable files that
# already existed before this convergent install.
find "$STATE_DIR/pending-meta" -xdev -mindepth 1 -maxdepth 1 -type f \
  -exec chown "$BROKER_USER:$BROKER_BOT_GROUP" {} + \
  -exec chmod 640 {} +
for shared_dir in "$STATE_DIR/pending-sidecar" "$STATE_DIR/notifications"; do
  find "$shared_dir" -xdev -mindepth 1 -maxdepth 1 -type f \
    -exec chgrp "$BROKER_BOT_GROUP" {} + \
    -exec chmod 660 {} +
done
audit_log="$STATE_DIR/audit.jsonl"
if [ -f "$audit_log" ] && [ ! -L "$audit_log" ]; then
  chown "$BROKER_USER:$BROKER_USER" "$audit_log"
  chmod 640 "$audit_log"
fi

mac_key="$STATE_DIR/keys/pending-mac.key"
if [ -L "$mac_key" ] || { [ -e "$mac_key" ] && ! [ -f "$mac_key" ]; }; then
  echo "refusing unsafe pending MAC-key path: $mac_key" >&2
  exit 1
fi
if [ ! -e "$mac_key" ]; then
  umask 077
  mac_temp="$(mktemp "$STATE_DIR/keys/.pending-mac.XXXXXX")"
  /usr/bin/openssl rand 64 >"$mac_temp"
  chown "$BROKER_USER:$BROKER_USER" "$mac_temp"
  chmod 600 "$mac_temp"
  mv "$mac_temp" "$mac_key"
fi
[ "$(wc -c <"$mac_key")" -ge 32 ] || { echo "pending MAC key is too short" >&2; exit 1; }
chown "$BROKER_USER:$BROKER_USER" "$mac_key"
chmod 600 "$mac_key"

install -o root -g root -m 644 "$SRC/server.py" "$SRC/policy_writer.py" "$SRC/originnorm.py" "$LIB_DIR/"
install -o root -g root -m 644 "$REPO_ROOT/schema/pr-request.schema.json" "$LIB_DIR/pr-request.schema.json"
install -o root -g root -m 755 "$SRC/git-askpass" "$LIB_DIR/git-askpass"
install -o root -g root -m 755 "$REPO_ROOT/lib/scripts/fieldwork-pr-build" /usr/local/bin/fieldwork-pr-build
install -o root -g root -m 755 "$REPO_ROOT/lib/scripts/fieldwork-pr-upload" /usr/local/bin/fieldwork-pr-upload
install -o root -g root -m 755 "$REPO_ROOT/lib/scripts/fieldwork-bot" /usr/local/bin/fieldwork-bot
install -o root -g root -m 755 "$SRC/policy_writer.py" /usr/local/sbin/fieldwork-policy-write
install -o root -g root -m 700 "$SRC/maintenance-submit" /usr/local/sbin/fieldwork-pr-maintenance-submit
install -o root -g root -m 700 "$SRC/maintenance-mode" /usr/local/sbin/fieldwork-pr-maintenance-mode
install -o root -g root -m 700 "$SRC/migrate-instructions" /usr/local/sbin/fieldwork-migrate-instructions
install -o root -g root -m 700 "$SRC/rotate-pat" /usr/local/sbin/rotate-pat

install_unit() {
  sed \
    -e "s|^User=fieldwork-pr-broker$|User=$BROKER_USER|" \
    -e "s|^Group=fieldwork-pr-broker$|Group=$BROKER_USER|" \
    -e "s|^SocketUser=fieldwork-pr-broker$|SocketUser=$BROKER_USER|" \
    -e "s|^SocketGroup=fieldwork-pr$|SocketGroup=$BROKER_SOCKET_GROUP|" \
    -e "s|^SocketGroup=fieldwork-bot$|SocketGroup=$BROKER_BOT_GROUP|" \
    "$1" >"$2"
  chown root:root "$2"
  chmod 644 "$2"
}

install_unit "$SRC/fieldwork-pr-broker.service" /etc/systemd/system/fieldwork-pr-broker.service
install_unit "$SRC/fieldwork-pr-broker.socket" /etc/systemd/system/fieldwork-pr-broker.socket
install_unit "$SRC/fieldwork-pr-approve.socket" /etc/systemd/system/fieldwork-pr-approve.socket
install_unit "$SRC/fieldwork-pr-broker-maintenance.socket" /etc/systemd/system/fieldwork-pr-broker-maintenance.socket
install_unit "$REPO_ROOT/lib/systemd/fieldwork-bot.service" /etc/systemd/system/fieldwork-bot.service

# Protocol v1 is intentionally removed so stale delivery instructions fail
# loudly during the discrete upgrade transaction.
for stale in /usr/local/bin/fieldwork-pr-submit; do
  [ ! -e "$stale" ] || mv "$stale" "$stale.protocol-v1-disabled"
done

systemctl stop fieldwork-pr-broker.service fieldwork-pr-broker.socket \
  fieldwork-pr-approve.socket fieldwork-pr-broker-maintenance.socket 2>/dev/null || true
# A maintenance-mode marker is deliberately runtime-only. An interrupted
# upgrade must not make a later normal install inherit maintenance mode.
rm -f /run/systemd/system/fieldwork-pr-broker.service.d/maintenance.conf
rmdir /run/systemd/system/fieldwork-pr-broker.service.d 2>/dev/null || true
systemctl daemon-reload
systemctl disable fieldwork-pr-broker-maintenance.socket 2>/dev/null || true
systemctl enable --now fieldwork-pr-broker.socket fieldwork-pr-approve.socket

echo "Fieldwork PR broker protocol v2 installed."
echo "Wire each slug with /usr/local/sbin/fieldwork-policy-write (approval defaults to require)."
