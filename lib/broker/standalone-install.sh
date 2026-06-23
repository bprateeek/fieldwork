#!/usr/bin/env bash
# Standalone PR broker install: installs the broker on a host that does NOT
# have the full Fieldwork CLI or bootstrap layout. The broker is the durable
# artifact: any coding agent that can write a JSON request file can submit PRs
# through it without holding a GitHub write credential itself.
#
# This script is a thin wrapper: it collects the identities and projects root
# the operator chose, verifies prerequisites are already installed (it does
# NOT install gh/gitleaks/python3. bootstrap-vps.sh does that for Fieldwork
# users, but the broker has no opinion on how they get there), then exports
# FIELDWORK_BROKER_* / FIELDWORK_REMOTE_USER and execs lib/broker/install.sh.
# The parameterized installer does the rest.

set -euo pipefail

usage() {
  cat <<'EOF'
usage: sudo bash standalone-install.sh [options]

Installs the Fieldwork PR broker on a host without the rest of Fieldwork.
The broker is agent-agnostic: any process that can write a JSON request to
the broker socket can open a PR through it.

Options (also readable from the matching environment variables):
  --agent-user <name>        Unprivileged user that will submit PR requests.
                             Must already exist.                  (AGENT_USER)
  --projects-root <path>     Directory containing per-repo checkouts the
                             broker may read and push from.
                             Default: /home/<agent-user>/projects (PROJECTS_ROOT)
  --broker-user <name>       Broker daemon user.
                             Default: fieldwork-pr-broker         (BROKER_USER)
  --broker-group <name>      Socket access group.
                             Default: agent user's primary group  (BROKER_GROUP)
                             A dedicated group can be specified, but agents
                             that run inside a user namespace (e.g.
                             `claude remote-control --sandbox`) often have
                             their supplementary groups stripped. In that
                             case keep the default so the agent's primary
                             group, which the userns preserves, gates the
                             socket.
  --verbose                  Stream raw install output to the terminal.
  --log-file <path>          Override the install log path.
  -h, --help                 Print this help and exit.

Prerequisites (the installer verifies, but does not install, these):
  - python3 (>= 3.8)
  - gh (GitHub CLI), authenticated separately via rotate-pat after install
  - gitleaks (binary on PATH)
  - the agent user must already exist with a home directory

After install:
  1. Store the broker's GitHub credential. PAT mode:
       sudo /usr/local/sbin/rotate-pat <<< 'github_pat_...'
     GitHub App mode:
       sudo env FIELDWORK_GITHUB_CREDENTIAL_MODE=app FIELDWORK_GITHUB_APP_ID=<id> FIELDWORK_GITHUB_APP_INSTALLATION_ID=<id> /usr/local/sbin/rotate-pat < private-key.pem
  2. The broker socket appears at
       /run/fieldwork-pr-broker/fieldwork-pr.sock
     readable+writable by group <broker-group> (default: the agent user's
     primary group).
  3. See docs/broker-standalone.md for a reference Python client and the
     curl --unix-socket recipe for other languages.

Pass --help to lib/broker/install.sh for the lower-level installer options.
EOF
}

AGENT_USER="${AGENT_USER:-}"
PROJECTS_ROOT="${PROJECTS_ROOT:-}"
BROKER_USER="${BROKER_USER:-fieldwork-pr-broker}"
# Default empty; lib/broker/install.sh resolves an empty value to the agent
# user's primary group. See the comment on BROKER_SOCKET_GROUP there for why
# a dedicated supplementary group breaks claude's userns-sandboxed agents.
BROKER_GROUP="${BROKER_GROUP:-}"
VERBOSE_FLAG=""
LOG_FILE_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --agent-user)     AGENT_USER="${2:?--agent-user requires a value}"; shift 2 ;;
    --projects-root)  PROJECTS_ROOT="${2:?--projects-root requires a value}"; shift 2 ;;
    --broker-user)    BROKER_USER="${2:?--broker-user requires a value}"; shift 2 ;;
    --broker-group)   BROKER_GROUP="${2:?--broker-group requires a value}"; shift 2 ;;
    --verbose)        VERBOSE_FLAG="--verbose"; shift ;;
    --log-file)       LOG_FILE_FLAG="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; echo "see --help for usage" >&2; exit 2 ;;
  esac
done

if [ -z "$AGENT_USER" ]; then
  echo "standalone-install.sh: --agent-user (or AGENT_USER env var) is required" >&2
  echo "see --help for usage" >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "standalone-install.sh must run as root (use sudo)" >&2
  exit 1
fi

missing=""
for cmd in python3 gh gitleaks install useradd usermod groupadd getent systemctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing="$missing $cmd"
  fi
done
if [ -n "$missing" ]; then
  echo "missing required commands:$missing" >&2
  echo "install these before running standalone-install.sh. The broker installer" >&2
  echo "will not install them for you." >&2
  exit 1
fi

if ! id "$AGENT_USER" >/dev/null 2>&1; then
  echo "agent user '$AGENT_USER' does not exist" >&2
  echo "create it first (e.g. 'useradd --create-home --shell /bin/bash $AGENT_USER')" >&2
  exit 1
fi

if [ -z "$PROJECTS_ROOT" ]; then
  agent_home="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
  if [ -z "$agent_home" ]; then
    echo "cannot resolve home directory for '$AGENT_USER'" >&2
    exit 1
  fi
  PROJECTS_ROOT="$agent_home/projects"
fi

case "$PROJECTS_ROOT" in
  /*) ;;
  *) echo "--projects-root must be an absolute path (got: $PROJECTS_ROOT)" >&2; exit 2 ;;
esac

install -d -m 755 "$PROJECTS_ROOT"
chown "$AGENT_USER:$AGENT_USER" "$PROJECTS_ROOT" 2>/dev/null || true

SRC="$(cd -P "$(dirname "$0")" && pwd)"

echo "Standalone broker install"
echo "  agent user:    $AGENT_USER"
echo "  projects root: $PROJECTS_ROOT"
echo "  broker user:   $BROKER_USER"
echo "  broker group:  ${BROKER_GROUP:-(default: agent user primary group)}"
echo
echo "Delegating to $SRC/install.sh ..."

export FIELDWORK_REMOTE_USER="$AGENT_USER"
export FIELDWORK_BROKER_USER="$BROKER_USER"
export FIELDWORK_BROKER_SOCKET_GROUP="$BROKER_GROUP"
export FIELDWORK_BROKER_PROJECTS_ROOT="$PROJECTS_ROOT"
export FIELDWORK_BROKER_STANDALONE=1

set --
[ -n "$VERBOSE_FLAG" ] && set -- "$@" "$VERBOSE_FLAG"
[ -n "$LOG_FILE_FLAG" ] && set -- "$@" --log-file "$LOG_FILE_FLAG"

exec bash "$SRC/install.sh" "$@"
