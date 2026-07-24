#!/usr/bin/env bash
# Standalone protocol-v2 broker installer. The broker never needs checkout access.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: sudo bash standalone-install.sh --agent-user <name> [options]

Options:
  --agent-user <name>   Existing user allowed to connect to the agent socket
  --broker-user <name>  Broker daemon user (default: fieldwork-pr-broker)
  --broker-group <name> Agent socket group (default: agent primary group)
  -h, --help            Show this help

Runtime prerequisites: Python 3.10+, git, gitleaks, openssl, and systemd.
The GitHub CLI is bootstrap-only and is not used by the broker request path.
EOF
}

AGENT_USER="${AGENT_USER:-}"
BROKER_USER="${BROKER_USER:-fieldwork-pr-broker}"
BROKER_GROUP="${BROKER_GROUP:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --agent-user) AGENT_USER="${2:?value required}"; shift 2 ;;
    --broker-user) BROKER_USER="${2:?value required}"; shift 2 ;;
    --broker-group) BROKER_GROUP="${2:?value required}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$AGENT_USER" ] || { echo "--agent-user is required" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
id "$AGENT_USER" >/dev/null 2>&1 || { echo "agent user '$AGENT_USER' does not exist" >&2; exit 1; }
missing=""
for command_name in python3 git gitleaks openssl install useradd groupadd getent systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || missing="$missing $command_name"
done
[ -z "$missing" ] || { echo "missing required commands:$missing" >&2; exit 1; }
SRC="$(cd -P "$(dirname "$0")" && pwd)"
export FIELDWORK_REMOTE_USER="$AGENT_USER"
export FIELDWORK_BROKER_USER="$BROKER_USER"
export FIELDWORK_BROKER_SOCKET_GROUP="$BROKER_GROUP"
export FIELDWORK_BROKER_STANDALONE=1
exec /bin/bash "$SRC/install.sh"
