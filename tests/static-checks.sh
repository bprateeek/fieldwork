#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIELDWORK_TEST_FINGERPRINT_FILES="bin/fieldwork install.sh AGENTS.md lib/cli/config.sh lib/cli/messaging.sh lib/cli/health.sh lib/cli/ssh-config.sh lib/cli/setup.sh lib/cli/onboard.sh lib/cli/quickstart.sh lib/cli/provision.sh lib/cli/verify-security.sh lib/cli/uninstall.sh lib/cli/developer-preview.sh lib/systemd/bootstrap-vps.sh lib/apparmor/fieldwork-bwrap lib/broker/install.sh lib/broker/standalone-install.sh lib/broker/fieldwork-pr-broker.service lib/broker/fieldwork-pr-broker.socket lib/broker/fieldwork-pr-approve.socket lib/broker/server.py schema/pr-request.schema.json schema/pr-prepare-request.schema.json lib/scripts/fieldwork-status lib/scripts/fieldwork-status-snapshot lib/scripts/fieldwork-dashboard-server lib/scripts/fieldwork-pr-submit lib/scripts/fieldwork-clone lib/scripts/fieldwork-init lib/scripts/fieldwork-launch lib/scripts/fieldwork-agent-session lib/scripts/fieldwork-event-poll lib/scripts/fieldwork-setup-probe lib/scripts/fieldwork-session-probe lib/scripts/fieldwork-codex-sandbox lib/scripts/fieldwork-bot lib/scripts/fieldwork-pr-prepare lib/scripts/fieldwork-pr-prepare-runner lib/scripts/fieldwork-pr-prepare-impl lib/agents/claude-remote-control lib/templates/repo/AGENTS.md lib/templates/repo/CLAUDE.md lib/templates/repo/.gitignore lib/templates/repo/.fieldwork/expected-origin lib/systemd/fieldwork-agent@.service lib/systemd/fieldwork-dashboard.service lib/systemd/fieldwork-event-poll.service lib/systemd/fieldwork-event-poll.timer lib/systemd/fieldwork-bot.service lib/systemd/fieldwork-pr-prepare-runner.socket lib/systemd/fieldwork-pr-prepare-runner@.service lib/systemd/fieldwork-verify-runner.socket lib/systemd/fieldwork-verify-runner@.service examples/eval/docker-compose.yml examples/eval/Dockerfile examples/eval/eval-smoke.sh examples/eval/fake-gh examples/eval/fake-gitleaks examples/eval/gh examples/eval/gitleaks examples/eval/README.md"
TMP_DIRS=""
cleanup() {
  local dir
  for dir in $TMP_DIRS; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT
mktemp_dir() {
  local dir
  # Pass an explicit template under $TMPDIR: macOS `mktemp -d` with no template
  # ignores $TMPDIR and uses _CS_DARWIN_USER_TEMP_DIR, which can be outside a
  # restricted sandbox's writable paths.
  dir="$(mktemp -d "${TMPDIR:-/tmp}/fieldwork-test.XXXXXX")"
  TMP_DIRS="$TMP_DIRS $dir"
  printf '%s\n' "$dir"
}
grep_regex() {
  local pattern="$1"
  shift
  grep -RInE -- "$pattern" "$@"
}
grep_repo_regex_excluding_static() {
  local pattern="$1"
  local found=1
  local matches
  local rel
  while IFS= read -r -d '' rel; do
    [ "$rel" = "tests/static-checks.sh" ] && continue
    matches="$(grep -nIE -- "$pattern" "$ROOT/$rel" || true)"
    if [ -n "$matches" ]; then
      printf '%s\n' "$matches" | sed "s|^|$rel:|"
      found=0
    fi
  done < <(git -C "$ROOT" ls-files -z)
  return "$found"
}
count_fixed_occurrences() {
  local needle="$1"
  shift
  { grep -RohF -- "$needle" "$@" || true; } | wc -l | tr -d ' '
}

echo "[checks] shell syntax"
while IFS= read -r file; do
  # Skip Python scripts shipped in lib/scripts/; they're parsed below with py_compile.
  if head -n 1 "$file" | grep -q 'python'; then continue; fi
  bash -n "$file"
done < <(find "$ROOT" -path "$ROOT/.git" -prune -o -type f \( -name '*.sh' -o -path "$ROOT/bin/fieldwork" -o -path "$ROOT/lib/scripts/*" -o -path "$ROOT/lib/broker/git-askpass" -o -path "$ROOT/lib/broker/rotate-pat" \) -perm -111 -print | sort)
bash -n "$ROOT/lib/cli/config.sh"
bash -n "$ROOT/lib/cli/messaging.sh"
bash -n "$ROOT/lib/cli/health.sh"
bash -n "$ROOT/lib/cli/ssh-config.sh"
bash -n "$ROOT/lib/cli/provision.sh"
bash -n "$ROOT/lib/cli/uninstall.sh"
bash -n "$ROOT/lib/cli/developer-preview.sh"
bash -n "$ROOT/lib/cli/setup.sh"
bash -n "$ROOT/lib/scripts/fieldwork-status"
test -x "$ROOT/lib/scripts/fieldwork-codex-sandbox"

echo "[checks] fingerprint file list mirror"
fieldwork_fingerprint_files_from_cli="$(awk -F\" '/^FIELDWORK_FINGERPRINT_FILES=/{ print $2; exit }' "$ROOT/bin/fieldwork")"
if [ "$fieldwork_fingerprint_files_from_cli" != "$FIELDWORK_TEST_FINGERPRINT_FILES" ]; then
  echo "tests/static-checks.sh FIELDWORK_TEST_FINGERPRINT_FILES must match bin/fieldwork FIELDWORK_FINGERPRINT_FILES" >&2
  exit 1
fi

echo "[checks] control-plane config loader"
bash "$ROOT/tests/config-tests.sh"

echo "[checks] message helpers"
bash "$ROOT/tests/messaging-tests.sh"

echo "[checks] health render"
bash "$ROOT/tests/health-tests.sh"

echo "[checks] health round-trip budget and degradation"
# Drives the real `fieldwork health` against a fake ssh that distinguishes the
# setup probe from the bot snapshot by their stdin, and counts each. With mux
# off, a healthy run must be exactly one probe + one bot snapshot; an
# unreachable VPS must be one probe, zero bot snapshots, blocked, exit 3.
tmp_health_bin="$(mktemp_dir)"
tmp_health_home="$(mktemp_dir)"
cat > "$tmp_health_bin/ssh" <<'SH'
#!/usr/bin/env bash
stdin="$(cat)"
if printf '%s' "$stdin" | grep -q 'SERVICE_STATE'; then
  printf 'bot\n' >> "$FAKE_HEALTH_SSH_LOG"
  [ "${FAKE_HEALTH_SSH_MODE:-ok}" = "transport" ] && exit 255
  printf 'SERVICE_STATE=active\nBROKER_SUBMIT_STATUS=ok\nTOKEN_CONFIG_STATUS=ok\nDIR_PENDING_COUNT=0\n'
  exit 0
fi
printf 'probe\n' >> "$FAKE_HEALTH_SSH_LOG"
[ "${FAKE_HEALTH_SSH_MODE:-ok}" = "transport" ] && exit 255
cat <<'SNAP'
remote_user=fieldwork
fieldwork_cli=ok
fieldwork_checkout=ok
path_configured=ok
bootstrap_ready=ok
claude_login=ok
claude_cli=ok
codex_cli=missing
codex_login=missing
configured_agents_raw=claude
configured_agents=claude
configured_agents_status=ok
gh_cli=ok
gh_hosts=ok
gh_live=ok
verify_runner=ok
prepare_runner=ok
claude_service=ok
broker_socket=ok
broker_pat_tool=ok
broker_thin_client=ok
broker_pat_marker=ok
broker_pat_sudo=ok
broker_pat_sudo_probe=ok
temporary_sudo=missing
public_ssh_rule=ok
projects_dir=ok
SNAP
exit 0
SH
chmod +x "$tmp_health_bin/ssh"

FAKE_HEALTH_SSH_LOG="$tmp_health_bin/health-ok.log"
: > "$FAKE_HEALTH_SSH_LOG"
FAKE_HEALTH_SSH_LOG="$FAKE_HEALTH_SSH_LOG" FAKE_HEALTH_SSH_MODE=ok \
FIELDWORK_SSH_MULTIPLEX=0 FIELDWORK_SSH_HOST=fieldwork-vps NO_COLOR=1 \
HOME="$tmp_health_home" PATH="$tmp_health_bin:$PATH" \
  "$ROOT/bin/fieldwork" health >${TMPDIR:-/tmp}/fieldwork-health-ok.out 2>&1
grep -q "All systems go." ${TMPDIR:-/tmp}/fieldwork-health-ok.out
grep -q "Agent: claude" ${TMPDIR:-/tmp}/fieldwork-health-ok.out
test "$(grep -c probe "$tmp_health_bin/health-ok.log")" = "1"
test "$(grep -c bot "$tmp_health_bin/health-ok.log")" = "1"

FAKE_HEALTH_SSH_LOG="$tmp_health_bin/health-tr.log"
: > "$FAKE_HEALTH_SSH_LOG"
health_tr_rc=0
FAKE_HEALTH_SSH_LOG="$FAKE_HEALTH_SSH_LOG" FAKE_HEALTH_SSH_MODE=transport \
FIELDWORK_SSH_MULTIPLEX=0 FIELDWORK_SSH_HOST=fieldwork-vps NO_COLOR=1 \
HOME="$tmp_health_home" PATH="$tmp_health_bin:$PATH" \
  "$ROOT/bin/fieldwork" health >${TMPDIR:-/tmp}/fieldwork-health-tr.out 2>&1 || health_tr_rc=$?
test "$health_tr_rc" = "3"
grep -q "unreachable over SSH" ${TMPDIR:-/tmp}/fieldwork-health-tr.out
test "$(grep -c bot "$tmp_health_bin/health-tr.log")" = "0"

echo "[checks] status queue render"
bash "$ROOT/tests/status-queue-tests.sh"

echo "[checks] status --queue argument handling"
status_queue_rc=0
FIELDWORK_SSH_HOST=fieldwork-vps "$ROOT/bin/fieldwork" status --queue --verbose >/dev/null 2>&1 || status_queue_rc=$?
test "$status_queue_rc" = "2"
status_queue_rc=0
FIELDWORK_SSH_HOST=fieldwork-vps "$ROOT/bin/fieldwork" status 'Bad Slug' --queue >/dev/null 2>&1 || status_queue_rc=$?
test "$status_queue_rc" = "2"
"$ROOT/bin/fieldwork" status --help 2>&1 | grep -q -- "--queue"

echo "[checks] health surface in usage and docs"
grep -q '^  health ' "$ROOT/bin/fieldwork"
grep -q '`fieldwork health`' "$ROOT/docs/cli-reference.md"
# Health hints point at these troubleshooting anchors; the headings must slugify to them.
grep -qi '^## VPS Unreachable$' "$ROOT/docs/troubleshooting.md"
grep -qi '^## VPS Untrusted$' "$ROOT/docs/troubleshooting.md"

echo "[checks] managed ssh-config writer"
bash "$ROOT/tests/ssh-config-tests.sh"

echo "[checks] provision seam"
bash "$ROOT/tests/provision-tests.sh"

echo "[checks] rotate-pat validation"
bash "$ROOT/tests/rotate-pat-tests.sh"

echo "[checks] broker python syntax"
python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' "$ROOT/lib/broker/server.py"

echo "[checks] broker validation tests"
python3 "$ROOT/tests/broker-validation-tests.py"

echo "[checks] broker schema JSON"
python3 -c 'import json, pathlib, sys; json.loads(pathlib.Path(sys.argv[1]).read_text())' "$ROOT/schema/pr-request.schema.json"

echo "[checks] pr-prepare schema JSON"
python3 -c 'import json, pathlib, sys; json.loads(pathlib.Path(sys.argv[1]).read_text())' "$ROOT/schema/pr-prepare-request.schema.json"

echo "[checks] pr-prepare client compiles"
python3 -m py_compile "$ROOT/lib/scripts/fieldwork-pr-prepare"
grep -Fq 'allowed_prefix = os.path.join(repo_root, ".fieldwork", "local")' "$ROOT/lib/scripts/fieldwork-pr-prepare"
if grep -Fq '.claude/local' "$ROOT/lib/scripts/fieldwork-pr-prepare"; then
  echo "fieldwork-pr-prepare must not accept or mention .claude/local request files" >&2
  exit 1
fi

echo "[checks] pr-prepare validation tests"
python3 "$ROOT/tests/pr-prepare-validation-tests.py" >/dev/null

echo "[checks] pr-prepare runner unit hardening"
# Socket: 0600 + Accept=yes + ListenStream under $XDG_RUNTIME_DIR (%t).
grep -Fxq "SocketMode=0600" "$ROOT/lib/systemd/fieldwork-pr-prepare-runner.socket"
grep -Fxq "Accept=yes"      "$ROOT/lib/systemd/fieldwork-pr-prepare-runner.socket"
grep -Fxq "ListenStream=%t/fieldwork-pr-prepare.sock" "$ROOT/lib/systemd/fieldwork-pr-prepare-runner.socket"
grep -Fxq "MaxConnections=4" "$ROOT/lib/systemd/fieldwork-pr-prepare-runner.socket"
grep -Fxq "MaxConnections=4" "$ROOT/lib/systemd/fieldwork-verify-runner.socket"
# Service: explicitly NO NoNewPrivileges=true (only the explanatory comment).
if grep -E '^\s*NoNewPrivileges\s*=\s*true' "$ROOT/lib/systemd/fieldwork-pr-prepare-runner@.service" >/dev/null; then
  echo "fieldwork-pr-prepare-runner@.service must not set NoNewPrivileges=true (see comment in unit)" >&2
  exit 1
fi
grep -Fq "do NOT set NoNewPrivileges=true" "$ROOT/lib/systemd/fieldwork-pr-prepare-runner@.service"
grep -Fxq "ExecStart=%h/.local/bin/fieldwork-pr-prepare-runner" "$ROOT/lib/systemd/fieldwork-pr-prepare-runner@.service"

echo "[checks] pr-prepare scripts have no NUL bytes"
for f in lib/scripts/fieldwork-pr-prepare lib/scripts/fieldwork-pr-prepare-runner lib/scripts/fieldwork-pr-prepare-impl; do
  python3 -c "import sys; sys.exit(0 if b'\\x00' not in open(sys.argv[1],'rb').read() else 1)" "$ROOT/$f" \
    || { echo "$f contains embedded NUL bytes" >&2; exit 1; }
done

echo "[checks] pr-prepare impl uses core.hooksPath=/dev/null"
grep -q "core.hooksPath=/dev/null" "$ROOT/lib/scripts/fieldwork-pr-prepare-impl"

echo "[checks] event poller tests"
python3 "$ROOT/tests/event-poll-tests.py"
grep -q "fieldwork-event-poll.timer" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "fieldwork-event-poll" "$ROOT/install.sh"
grep -q "fieldwork-event-poll.timer" "$ROOT/lib/cli/uninstall.sh"

echo "[checks] dashboard tests"
python3 -m py_compile "$ROOT/lib/scripts/fieldwork-status-snapshot" "$ROOT/lib/scripts/fieldwork-dashboard-server" "$ROOT/tests/dashboard-tests.py"
python3 "$ROOT/tests/dashboard-tests.py"
grep -q '^  dashboard ' "$ROOT/bin/fieldwork"
grep -q '`fieldwork dashboard`' "$ROOT/docs/cli-reference.md"
grep -q "fieldwork-status-snapshot" "$ROOT/install.sh"
grep -q "fieldwork-dashboard-server" "$ROOT/install.sh"
grep -q "fieldwork-dashboard.service" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "fieldwork-dashboard.service" "$ROOT/lib/cli/setup.sh"
grep -q "fieldwork-dashboard.service" "$ROOT/lib/cli/uninstall.sh"
grep -Fxq "Environment=FIELDWORK_DASHBOARD_HOST=127.0.0.1" "$ROOT/lib/systemd/fieldwork-dashboard.service"
if grep -Fq "innerHTML" "$ROOT/lib/scripts/fieldwork-dashboard-server"; then
  echo "fieldwork-dashboard-server must render with safe DOM APIs, not innerHTML" >&2
  exit 1
fi

echo "[checks] settings.json has pr-prepare in excludedCommands"
python3 -c '
import json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())
ex = s.get("sandbox", {}).get("excludedCommands", [])
assert "/home/fieldwork/.local/bin/fieldwork-pr-prepare *" in ex, ex
' "$ROOT/lib/claude/settings.json"

echo "[checks] broker socket-group default is the agent primary group (userns-safe)"
# claude remote-control --sandbox strips supplementary groups inside the
# agent's userns. The installer must default the socket group to the agent
# user's primary group; a hard-coded dedicated group (e.g. fieldwork-pr)
# silently breaks /pr-delivery from a sandboxed agent.
if grep -Eq '^BROKER_SOCKET_GROUP="\$\{FIELDWORK_BROKER_SOCKET_GROUP:-fieldwork-pr\}"' \
     "$ROOT/lib/broker/install.sh"; then
  echo "lib/broker/install.sh resets BROKER_SOCKET_GROUP to the hard-coded fieldwork-pr default" >&2
  echo "see docs/threat-model.md \"Userns interaction\" for why this regresses /pr-delivery" >&2
  exit 1
fi
grep -F 'BROKER_SOCKET_GROUP="$(id -gn "$AGENT_USER")"' \
     "$ROOT/lib/broker/install.sh" >/dev/null \
  || { echo "lib/broker/install.sh must compute BROKER_SOCKET_GROUP from id -gn AGENT_USER when empty" >&2; exit 1; }

echo "[checks] standalone-install passes BROKER_GROUP through (empty -> agent primary)"
if grep -Eq '^BROKER_GROUP="\$\{BROKER_GROUP:-fieldwork-pr\}"' \
     "$ROOT/lib/broker/standalone-install.sh"; then
  echo "standalone-install.sh resets BROKER_GROUP to the hard-coded fieldwork-pr default" >&2
  exit 1
fi
grep -F 'BROKER_GROUP="${BROKER_GROUP:-}"' \
     "$ROOT/lib/broker/standalone-install.sh" >/dev/null \
  || { echo "standalone-install.sh must default BROKER_GROUP empty so lib/broker/install.sh resolves it" >&2; exit 1; }

echo "[checks] standalone broker install --help"
bash "$ROOT/lib/broker/standalone-install.sh" --help >${TMPDIR:-/tmp}/fieldwork-broker-standalone-help.out
grep -q "usage: sudo bash standalone-install.sh" ${TMPDIR:-/tmp}/fieldwork-broker-standalone-help.out
grep -q -- "--agent-user" ${TMPDIR:-/tmp}/fieldwork-broker-standalone-help.out
grep -q -- "--projects-root" ${TMPDIR:-/tmp}/fieldwork-broker-standalone-help.out
grep -q "rotate-pat" ${TMPDIR:-/tmp}/fieldwork-broker-standalone-help.out

echo "[checks] standalone broker install requires --agent-user"
if bash "$ROOT/lib/broker/standalone-install.sh" >${TMPDIR:-/tmp}/fieldwork-broker-standalone-no-arg.out 2>&1; then
  echo "standalone-install.sh should fail when --agent-user is missing" >&2
  exit 1
fi
grep -q "agent-user.*required" ${TMPDIR:-/tmp}/fieldwork-broker-standalone-no-arg.out

echo "[checks] reference broker client compiles"
python3 -m py_compile "$ROOT/examples/broker-client.py"

echo "[checks] broker standalone docs present"
test -f "$ROOT/docs/broker-standalone.md"
grep -q "Advanced / operator path" "$ROOT/docs/broker-standalone.md"
grep -q "supported developer preview path is \`fieldwork setup\`" "$ROOT/docs/broker-standalone.md"
grep -q "standalone-install.sh" "$ROOT/docs/broker-standalone.md"
grep -q "curl --unix-socket" "$ROOT/docs/broker-standalone.md"
test -f "$ROOT/docs/agent-adapters.md"
grep -q "agent adapter" "$ROOT/docs/agent-adapters.md"
grep -q "FIELDWORK_BRANCH_PREFIX" "$ROOT/docs/agent-adapters.md"

echo "[checks] README points to standalone broker"
grep -q "advanced broker-only install" "$ROOT/README.md"
grep -q "broker-standalone.md" "$ROOT/README.md"

echo "[checks] fieldwork help"
"$ROOT/bin/fieldwork" --help >${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "^Fieldwork .*self-hosted mobile-to-PR workflows" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "^Getting started$" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "quickstart \\[repo\\] .*resumable setup" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "setup .*install and configure Fieldwork locally" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "onboard <repo> .*prepare a GitHub repo for Fieldwork" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "start <repo> .*begin a phone-driven session on a repo" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "^Day to day$" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "refresh <repo> .*update the VPS checkout after merge" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "log \\[repo\\] .*tail the audit log" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "report \\[repo\\] .*generate a redacted support bundle" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "^Health and diagnostics$" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "doctor .*check local and remote configuration" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "verify-security .*run the security boundary checks" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "smoke <repo> .*end-to-end test against a real repo" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "^Setup helpers$" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "setup-notify .*configure notification transport" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "sync-vps .*push local config to the VPS" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "install-broker .*install or update the broker on the VPS" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "adapter doctor .*diagnose the active adapter" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "eval up|smoke|logs|down|clean .*manage the eval environment" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "^Removal$" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q "uninstall .*remove Fieldwork (use --dry-run first)" ${TMPDIR:-/tmp}/fieldwork-help.out
grep -q 'Run `fieldwork doctor --explain` to see current values' ${TMPDIR:-/tmp}/fieldwork-help.out
if grep -q "fieldwork uninstall \\[" ${TMPDIR:-/tmp}/fieldwork-help.out; then
  echo "top-level help should not show uninstall flag soup" >&2
  exit 1
fi
if grep -q "Developer preview defaults:" ${TMPDIR:-/tmp}/fieldwork-help.out; then
  echo "top-level help should point to doctor --explain instead of listing stale defaults" >&2
  exit 1
fi
grep -q "FIELDWORK_STABLE_EXEC" "$ROOT/bin/fieldwork"
grep -q "FIELDWORK_ROOT_OVERRIDE" "$ROOT/bin/fieldwork"
grep -q "source /dev/fd/3" "$ROOT/bin/fieldwork"
if grep -q 'exec bash -c "$fieldwork_script"' "$ROOT/bin/fieldwork"; then
  echo "stable exec must not pass the full CLI through one bash -c argument" >&2
  exit 1
fi

echo "[checks] no-arg setup helper wrappers tolerate empty option arrays"
fake_install_broker_nonlinux_bin="$(mktemp_dir)"
cat > "$fake_install_broker_nonlinux_bin/uname" <<'SH'
#!/bin/sh
if [ "$1" = "-s" ]; then
  printf 'Darwin\n'
  exit 0
fi
exec /usr/bin/uname "$@"
SH
cat > "$fake_install_broker_nonlinux_bin/sudo" <<'SH'
#!/bin/sh
echo "non-Linux path should not invoke sudo" >&2
exit 1
SH
chmod +x "$fake_install_broker_nonlinux_bin/uname" "$fake_install_broker_nonlinux_bin/sudo"
if PATH="$fake_install_broker_nonlinux_bin:$PATH" USER=fieldwork-test \
  "$ROOT/bin/fieldwork" install-broker >${TMPDIR:-/tmp}/fieldwork-install-broker-nonlinux.out 2>&1; then
  echo "install-broker should refuse non-Linux current hosts" >&2
  exit 1
fi
grep -q "^Broker install target$" ${TMPDIR:-/tmp}/fieldwork-install-broker-nonlinux.out
grep -q "Current host OS: Darwin" ${TMPDIR:-/tmp}/fieldwork-install-broker-nonlinux.out
grep -q "Broker installation requires the Linux VPS/systemd host" ${TMPDIR:-/tmp}/fieldwork-install-broker-nonlinux.out
grep -q "fieldwork setup" ${TMPDIR:-/tmp}/fieldwork-install-broker-nonlinux.out
grep -q "ssh -t .*'cd ~/fieldwork && ./bin/fieldwork install-broker'" ${TMPDIR:-/tmp}/fieldwork-install-broker-nonlinux.out
if grep -q "Current-host sudo authentication\\|non-Linux path should not invoke sudo" ${TMPDIR:-/tmp}/fieldwork-install-broker-nonlinux.out; then
  echo "install-broker non-Linux path should guide without sudo" >&2
  exit 1
fi
fake_install_broker_bin="$(mktemp_dir)"
cat > "$fake_install_broker_bin/uname" <<'SH'
#!/bin/sh
if [ "$1" = "-s" ]; then
  printf 'Linux\n'
  exit 0
fi
exec /usr/bin/uname "$@"
SH
cat > "$fake_install_broker_bin/id" <<'SH'
#!/bin/sh
if [ "$1" = "-u" ]; then
  printf '1000\n'
  exit 0
fi
exec /usr/bin/id "$@"
SH
cat > "$fake_install_broker_bin/sudo" <<'SH'
#!/bin/sh
if [ "$1" = "-n" ] && [ "$2" = "true" ]; then
  exit 1
fi
printf 'fake sudo:'
for arg in "$@"; do
  printf ' %s' "$arg"
done
printf '\n'
SH
chmod +x "$fake_install_broker_bin/uname" "$fake_install_broker_bin/id" "$fake_install_broker_bin/sudo"
PATH="$fake_install_broker_bin:$PATH" USER=fieldwork-test \
  "$ROOT/bin/fieldwork" install-broker >${TMPDIR:-/tmp}/fieldwork-install-broker-empty-args.out
grep -q "^Current-host sudo authentication$" ${TMPDIR:-/tmp}/fieldwork-install-broker-empty-args.out
grep -q "From your workstation, use: fieldwork setup" ${TMPDIR:-/tmp}/fieldwork-install-broker-empty-args.out
grep -q "Run this helper directly only on the VPS or in advanced broker-only flows" ${TMPDIR:-/tmp}/fieldwork-install-broker-empty-args.out
grep -q "If prompted, enter the sudo password" ${TMPDIR:-/tmp}/fieldwork-install-broker-empty-args.out
grep -q "fake sudo: -p \\[sudo\\] Current-host password:  bash .*lib/broker/install.sh$" ${TMPDIR:-/tmp}/fieldwork-install-broker-empty-args.out
if grep -q "unbound variable" ${TMPDIR:-/tmp}/fieldwork-install-broker-empty-args.out; then
  echo "install-broker no-arg wrapper tripped nounset on an empty option array" >&2
  exit 1
fi
fake_install_broker_passwordless_bin="$(mktemp_dir)"
cat > "$fake_install_broker_passwordless_bin/uname" <<'SH'
#!/bin/sh
if [ "$1" = "-s" ]; then
  printf 'Linux\n'
  exit 0
fi
exec /usr/bin/uname "$@"
SH
cat > "$fake_install_broker_passwordless_bin/id" <<'SH'
#!/bin/sh
if [ "$1" = "-u" ]; then
  printf '1000\n'
  exit 0
fi
exec /usr/bin/id "$@"
SH
cat > "$fake_install_broker_passwordless_bin/sudo" <<'SH'
#!/bin/sh
if [ "$1" = "-n" ] && [ "$2" = "true" ]; then
  exit 0
fi
printf 'fake sudo:'
for arg in "$@"; do
  printf ' %s' "$arg"
done
printf '\n'
SH
chmod +x "$fake_install_broker_passwordless_bin/uname" "$fake_install_broker_passwordless_bin/id" "$fake_install_broker_passwordless_bin/sudo"
PATH="$fake_install_broker_passwordless_bin:$PATH" USER=fieldwork-test \
  "$ROOT/bin/fieldwork" install-broker >${TMPDIR:-/tmp}/fieldwork-install-broker-passwordless.out
grep -q "Sudo is already passwordless or authorized" ${TMPDIR:-/tmp}/fieldwork-install-broker-passwordless.out
grep -q "fake sudo: -n bash .*lib/broker/install.sh$" ${TMPDIR:-/tmp}/fieldwork-install-broker-passwordless.out
if grep -q "If prompted, enter the sudo password" ${TMPDIR:-/tmp}/fieldwork-install-broker-passwordless.out; then
  echo "install-broker passwordless path should not ask for a sudo password" >&2
  exit 1
fi
fake_install_broker_root_bin="$(mktemp_dir)"
cat > "$fake_install_broker_root_bin/uname" <<'SH'
#!/bin/sh
if [ "$1" = "-s" ]; then
  printf 'Linux\n'
  exit 0
fi
exec /usr/bin/uname "$@"
SH
cat > "$fake_install_broker_root_bin/id" <<'SH'
#!/bin/sh
if [ "$1" = "-u" ]; then
  printf '0\n'
  exit 0
fi
exec /usr/bin/id "$@"
SH
cat > "$fake_install_broker_root_bin/sudo" <<'SH'
#!/bin/sh
echo "root path should not invoke sudo" >&2
exit 1
SH
cat > "$fake_install_broker_root_bin/bash" <<'SH'
#!/bin/sh
case "$1" in
  -c)
    exec /bin/bash "$@"
    ;;
  *lib/broker/install.sh)
    printf 'fake bash installer:'
    for arg in "$@"; do
      printf ' %s' "$arg"
    done
    printf '\n'
    exit 0
    ;;
  *)
    exec /bin/bash "$@"
    ;;
esac
SH
chmod +x "$fake_install_broker_root_bin/uname" "$fake_install_broker_root_bin/id" "$fake_install_broker_root_bin/sudo" "$fake_install_broker_root_bin/bash"
PATH="$fake_install_broker_root_bin:$PATH" USER=root \
  "$ROOT/bin/fieldwork" install-broker >${TMPDIR:-/tmp}/fieldwork-install-broker-root.out
grep -q "Running as root on this host; no sudo password is required" ${TMPDIR:-/tmp}/fieldwork-install-broker-root.out
grep -q "fake bash installer: .*lib/broker/install.sh$" ${TMPDIR:-/tmp}/fieldwork-install-broker-root.out
if grep -q "If prompted, enter the sudo password\\|root path should not invoke sudo" ${TMPDIR:-/tmp}/fieldwork-install-broker-root.out; then
  echo "install-broker root path should run without sudo" >&2
  exit 1
fi
tmp_bootstrap_wrapper_home="$(mktemp_dir)"
if HOME="$tmp_bootstrap_wrapper_home" FIELDWORK_REMOTE_USER=fieldwork-never \
  "$ROOT/bin/fieldwork" bootstrap-vps >${TMPDIR:-/tmp}/fieldwork-bootstrap-empty-args.out 2>&1; then
  echo "bootstrap-vps empty-args validation should stop at the mismatched user" >&2
  exit 1
fi
grep -q "must run as the 'fieldwork-never' user" ${TMPDIR:-/tmp}/fieldwork-bootstrap-empty-args.out
if grep -q "unbound variable" ${TMPDIR:-/tmp}/fieldwork-bootstrap-empty-args.out; then
  echo "bootstrap-vps no-arg wrapper tripped nounset on an empty option array" >&2
  exit 1
fi

echo "[checks] uninstall help and dry-run scope"
"$ROOT/bin/fieldwork" uninstall --help >${TMPDIR:-/tmp}/fieldwork-uninstall-help.out
grep -q "usage: fieldwork uninstall" ${TMPDIR:-/tmp}/fieldwork-uninstall-help.out
grep -q -- "--no-broker" ${TMPDIR:-/tmp}/fieldwork-uninstall-help.out
grep -q -- "--bot" ${TMPDIR:-/tmp}/fieldwork-uninstall-help.out
grep -q -- "--quiet" ${TMPDIR:-/tmp}/fieldwork-uninstall-help.out
grep -q -- "--remove-system-users" ${TMPDIR:-/tmp}/fieldwork-uninstall-help.out
fake_uninstall_bin="$(mktemp_dir)"
cat > "$fake_uninstall_bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_UNINSTALL_SSH_LOG"
args="$*"
case "$args" in
  *"BatchMode=yes"*) exit 0 ;;
  *"test -e /etc/systemd/system/fieldwork-pr-broker.service"*) exit 0 ;;
  *"test -e /etc/systemd/system/fieldwork-bot.service"*) exit 0 ;;
  *"test -f ~/.fieldwork/notify.env"*) exit 0 ;;
  *"grep -Fq 'Managed by Fieldwork' ~/.fieldwork/notify.env"*) exit 0 ;;
  *"sudo -n true"*) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$fake_uninstall_bin/ssh"
tmp_uninstall_home="$(mktemp_dir)"
HOME="$tmp_uninstall_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_UNINSTALL_SSH_LOG="$fake_uninstall_bin/ssh.log" HOME="$tmp_uninstall_home" PATH="$fake_uninstall_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --dry-run >${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "^Fieldwork uninstall dry run$" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "^Fieldwork uninstall$" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "^Root: " ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "^Legend: \\[ready\\] | \\[needs-action\\] | \\[manual\\] | \\[blocked\\] | \\[info\\]$" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "^Safe to rerun: yes$" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "^Local$" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "^Remote user services$" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "^Remote broker/system services$" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "fieldwork-pr-broker.socket" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "^Approval bot$" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "fieldwork-bot.service" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "remote ~/.fieldwork/notify.env (Fieldwork-marked)" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
grep -q "User-authored Claude config" ${TMPDIR:-/tmp}/fieldwork-uninstall-dry-run.out
if grep -Eq 'rm -rf|systemctl disable|userdel|groupdel' "$fake_uninstall_bin/ssh.log"; then
  echo "uninstall --dry-run performed destructive remote commands" >&2
  exit 1
fi
FIELDWORK_FAKE_UNINSTALL_SSH_LOG="$fake_uninstall_bin/no-broker.log" HOME="$tmp_uninstall_home" PATH="$fake_uninstall_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --dry-run --no-broker >${TMPDIR:-/tmp}/fieldwork-uninstall-no-broker.out
if grep -q "^Remote broker/system services$" ${TMPDIR:-/tmp}/fieldwork-uninstall-no-broker.out; then
  echo "uninstall --no-broker still planned broker cleanup" >&2
  exit 1
fi
grep -q "^Approval bot$" ${TMPDIR:-/tmp}/fieldwork-uninstall-no-broker.out
FIELDWORK_FAKE_UNINSTALL_SSH_LOG="$fake_uninstall_bin/broker-only.log" HOME="$tmp_uninstall_home" PATH="$fake_uninstall_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --dry-run --broker >${TMPDIR:-/tmp}/fieldwork-uninstall-broker-only.out
grep -q "^Remote broker/system services$" ${TMPDIR:-/tmp}/fieldwork-uninstall-broker-only.out
if grep -q "^Local$" ${TMPDIR:-/tmp}/fieldwork-uninstall-broker-only.out || grep -q "^Remote user services$" ${TMPDIR:-/tmp}/fieldwork-uninstall-broker-only.out || grep -q "^Approval bot$" ${TMPDIR:-/tmp}/fieldwork-uninstall-broker-only.out; then
  echo "uninstall --broker planned non-broker cleanup" >&2
  exit 1
fi
FIELDWORK_FAKE_UNINSTALL_SSH_LOG="$fake_uninstall_bin/bot-only.log" HOME="$tmp_uninstall_home" PATH="$fake_uninstall_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --dry-run --bot >${TMPDIR:-/tmp}/fieldwork-uninstall-bot-only.out
grep -q "^Approval bot$" ${TMPDIR:-/tmp}/fieldwork-uninstall-bot-only.out
if grep -q "^Local$" ${TMPDIR:-/tmp}/fieldwork-uninstall-bot-only.out || grep -q "^Remote user services$" ${TMPDIR:-/tmp}/fieldwork-uninstall-bot-only.out || grep -q "^Remote broker/system services$" ${TMPDIR:-/tmp}/fieldwork-uninstall-bot-only.out; then
  echo "uninstall --bot planned non-bot cleanup" >&2
  exit 1
fi
fake_uninstall_offline_bin="$(mktemp_dir)"
cat > "$fake_uninstall_offline_bin/ssh" <<'SH'
#!/usr/bin/env bash
exit 255
SH
chmod +x "$fake_uninstall_offline_bin/ssh"
HOME="$tmp_uninstall_home" PATH="$fake_uninstall_offline_bin:$PATH" "$ROOT/bin/fieldwork" uninstall --dry-run >${TMPDIR:-/tmp}/fieldwork-uninstall-offline.out
grep -q "skipped: SSH unavailable" ${TMPDIR:-/tmp}/fieldwork-uninstall-offline.out

if bash -c 'set -euo pipefail; source "$1/lib/cli/uninstall.sh"; FIELDWORK_SSH_HOST=""; uninstall_fieldwork --dry-run --remote' bash "$ROOT" >${TMPDIR:-/tmp}/fieldwork-uninstall-no-host.out 2>&1; then
  echo "uninstall accepted a remote scope with empty FIELDWORK_SSH_HOST" >&2
  exit 1
fi
grep -q "FIELDWORK_SSH_HOST is required" ${TMPDIR:-/tmp}/fieldwork-uninstall-no-host.out

fake_uninstall_partial_bin="$(mktemp_dir)"
cat > "$fake_uninstall_partial_bin/ssh" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"BatchMode=yes"*) exit 0 ;;
  *"test -f /usr/local/sbin/rotate-pat"*) exit 0 ;;
  *"fieldwork-bot-config.toml"*) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_uninstall_partial_bin/ssh"
HOME="$tmp_uninstall_home" PATH="$fake_uninstall_partial_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --dry-run --broker >${TMPDIR:-/tmp}/fieldwork-uninstall-partial-broker.out
grep -q "^Remote broker/system services$" ${TMPDIR:-/tmp}/fieldwork-uninstall-partial-broker.out
grep -q "fieldwork-pr-broker.socket" ${TMPDIR:-/tmp}/fieldwork-uninstall-partial-broker.out
HOME="$tmp_uninstall_home" PATH="$fake_uninstall_partial_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --dry-run --bot >${TMPDIR:-/tmp}/fieldwork-uninstall-partial-bot.out
grep -q "^Approval bot$" ${TMPDIR:-/tmp}/fieldwork-uninstall-partial-bot.out
grep -q "fieldwork-bot.service" ${TMPDIR:-/tmp}/fieldwork-uninstall-partial-bot.out

echo "[checks] uninstall local ownership safety"
tmp_uninstall_local_home="$(mktemp_dir)"
mkdir -p "$tmp_uninstall_local_home/.local/bin" "$tmp_uninstall_local_home/.fieldwork/scripts" "$tmp_uninstall_local_home/.claude"
ln -s "$ROOT/bin/fieldwork" "$tmp_uninstall_local_home/.local/bin/fieldwork"
ln -s "$ROOT/lib/scripts/fieldwork-clone" "$tmp_uninstall_local_home/.fieldwork/scripts/fieldwork-clone"
printf 'user settings\n' > "$tmp_uninstall_local_home/.claude/settings.json"
printf 'NTFY_TOPIC=user-owned\n' > "$tmp_uninstall_local_home/.fieldwork/notify.env"
HOME="$tmp_uninstall_local_home" "$ROOT/bin/fieldwork" uninstall --local --yes >${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
test ! -e "$tmp_uninstall_local_home/.local/bin/fieldwork"
test ! -e "$tmp_uninstall_local_home/.fieldwork/scripts/fieldwork-clone"
test -f "$tmp_uninstall_local_home/.claude/settings.json"
test -f "$tmp_uninstall_local_home/.fieldwork/notify.env"
grep -q "^  \\[ready\\] ~/.local/bin/fieldwork$" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "^  \\[info\\] ~/.claude/settings.json (not a Fieldwork-managed symlink)$" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "User-authored Claude config" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "^Manual cleanup still outside Fieldwork uninstall$" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "^  \\[manual\\] GitHub broker PAT$" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "https://github.com/settings/personal-access-tokens" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "https://t.me/BotFather" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "ssh fieldwork@<your-vps-host> 'ssh-keygen -lf ~/.ssh/authorized_keys'" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "could not auto-detect VPS host" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "ssh -t fieldwork@<your-vps-host> 'sudo ufw delete allow 22/tcp'" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "Fieldwork bootstrap disables root SSH" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "future setup on this VPS needs root SSH, another sudo-capable account" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "provider console/rescue mode to recreate it" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "sudo userdel -r fieldwork" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
grep -q "^Uninstall complete\\.$" ${TMPDIR:-/tmp}/fieldwork-uninstall-local-safe.out
tmp_uninstall_quiet_home="$(mktemp_dir)"
mkdir -p "$tmp_uninstall_quiet_home/.local/bin"
ln -s "$ROOT/bin/fieldwork" "$tmp_uninstall_quiet_home/.local/bin/fieldwork"
HOME="$tmp_uninstall_quiet_home" "$ROOT/bin/fieldwork" uninstall --local --yes --quiet >${TMPDIR:-/tmp}/fieldwork-uninstall-quiet.out
if grep -Eq "^  \\[(ready|info)\\] (~|local |Fieldwork GitHub)" ${TMPDIR:-/tmp}/fieldwork-uninstall-quiet.out; then
  echo "uninstall --quiet printed cleanup ready/info rows" >&2
  exit 1
fi
source_status_out="${TMPDIR:-/tmp}/fieldwork-uninstall-quiet-failed.out"
bash -c 'set -euo pipefail; source "$1/lib/cli/uninstall.sh"; UNINSTALL_QUIET=1; uninstall_ok "hidden ok"; uninstall_skipped "hidden skipped" "reason"; uninstall_failed "visible failed" "reason"' bash "$ROOT" >"$source_status_out"
if grep -Eq "^  \\[(ready|info)\\]" "$source_status_out"; then
  echo "quiet logging helpers printed ready/info rows" >&2
  exit 1
fi
grep -q "^  \\[blocked\\] visible failed (reason)$" "$source_status_out"
tmp_uninstall_recorded_home="$(mktemp_dir)"
mkdir -p "$tmp_uninstall_recorded_home/.config/fieldwork"
cat > "$tmp_uninstall_recorded_home/.config/fieldwork/authorized-key.env" <<'EOF'
host=203.0.113.10
remote_user=fieldwork
fingerprint=SHA256:fieldworktest
public_key=ssh-ed25519 AAAAFIELDWORKTEST fieldwork
EOF
HOME="$tmp_uninstall_recorded_home" "$ROOT/bin/fieldwork" uninstall --local --yes --quiet >${TMPDIR:-/tmp}/fieldwork-uninstall-recorded-key.out
grep -q "Recorded fingerprint: SHA256:fieldworktest" ${TMPDIR:-/tmp}/fieldwork-uninstall-recorded-key.out
grep -q "Recorded target: fieldwork@203.0.113.10" ${TMPDIR:-/tmp}/fieldwork-uninstall-recorded-key.out
grep -q "Remove recorded key: ssh fieldwork@203.0.113.10" ${TMPDIR:-/tmp}/fieldwork-uninstall-recorded-key.out
if grep -q "Using direct target because" ${TMPDIR:-/tmp}/fieldwork-uninstall-recorded-key.out; then
  echo "uninstall printed removed-alias note for install with no alias at start" >&2
  exit 1
fi
grep -q "AAAAFIELDWORKTEST" ${TMPDIR:-/tmp}/fieldwork-uninstall-recorded-key.out
tmp_uninstall_marked_home="$(mktemp_dir)"
mkdir -p "$tmp_uninstall_marked_home/.fieldwork"
printf '# Managed by Fieldwork\nNTFY_TOPIC=fieldwork-test\n' > "$tmp_uninstall_marked_home/.fieldwork/notify.env"
HOME="$tmp_uninstall_marked_home" "$ROOT/bin/fieldwork" uninstall --local --yes >${TMPDIR:-/tmp}/fieldwork-uninstall-marked-notify.out
test ! -e "$tmp_uninstall_marked_home/.fieldwork/notify.env"

echo "[checks] uninstall SSH config cleanup"
tmp_uninstall_ssh_home="$(mktemp_dir)"
mkdir -p "$tmp_uninstall_ssh_home/.ssh"
cat > "$tmp_uninstall_ssh_home/.ssh/config" <<'EOF'
Host keep
  HostName keep.example

# BEGIN FIELDWORK GITHUB SSH CONFIG: github-demo
Host github-demo
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_demo
  IdentitiesOnly yes
# END FIELDWORK GITHUB SSH CONFIG: github-demo

# BEGIN FIELDWORK SSH CONFIG: fieldwork-vps
Host fieldwork-vps
  HostName 203.0.113.10
  User fieldwork
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
# END FIELDWORK SSH CONFIG: fieldwork-vps
EOF
chmod 600 "$tmp_uninstall_ssh_home/.ssh/config"
HOME="$tmp_uninstall_ssh_home" "$ROOT/bin/fieldwork" uninstall --local --yes >${TMPDIR:-/tmp}/fieldwork-uninstall-ssh-marked.out
grep -q "Host keep" "$tmp_uninstall_ssh_home/.ssh/config"
if grep -q "FIELDWORK .*SSH CONFIG\\|Host github-demo\\|Host fieldwork-vps" "$tmp_uninstall_ssh_home/.ssh/config"; then
  echo "uninstall did not remove marked Fieldwork SSH config blocks" >&2
  exit 1
fi
grep -q "# BEGIN FIELDWORK SSH CONFIG: fieldwork-vps" ${TMPDIR:-/tmp}/fieldwork-uninstall-ssh-marked.out
grep -q "Using direct target because the fieldwork-vps SSH alias was removed during uninstall\\." ${TMPDIR:-/tmp}/fieldwork-uninstall-ssh-marked.out
grep -q "ssh fieldwork@203.0.113.10 'ssh-keygen -lf ~/.ssh/authorized_keys'" ${TMPDIR:-/tmp}/fieldwork-uninstall-ssh-marked.out

tmp_uninstall_legacy_ssh_home="$(mktemp_dir)"
mkdir -p "$tmp_uninstall_legacy_ssh_home/.ssh"
cat > "$tmp_uninstall_legacy_ssh_home/.ssh/config" <<'EOF'
Host fieldwork-vps
  IdentityFile ~/.ssh/id_ed25519
  User fieldwork
  IdentitiesOnly yes
  HostName 203.0.113.10
EOF
chmod 600 "$tmp_uninstall_legacy_ssh_home/.ssh/config"
HOME="$tmp_uninstall_legacy_ssh_home" "$ROOT/bin/fieldwork" uninstall --local --yes >${TMPDIR:-/tmp}/fieldwork-uninstall-ssh-legacy.out
if grep -q "Host fieldwork-vps" "$tmp_uninstall_legacy_ssh_home/.ssh/config"; then
  echo "uninstall did not remove exact legacy Fieldwork SSH alias" >&2
  exit 1
fi

tmp_uninstall_extra_ssh_home="$(mktemp_dir)"
mkdir -p "$tmp_uninstall_extra_ssh_home/.ssh"
cat > "$tmp_uninstall_extra_ssh_home/.ssh/config" <<'EOF'
Host fieldwork-vps
  HostName 203.0.113.10
  User fieldwork
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  Port 22

Host keep
  HostName keep.example
EOF
chmod 600 "$tmp_uninstall_extra_ssh_home/.ssh/config"
HOME="$tmp_uninstall_extra_ssh_home" "$ROOT/bin/fieldwork" uninstall --local --yes >${TMPDIR:-/tmp}/fieldwork-uninstall-ssh-extra.out
grep -q "Host fieldwork-vps" "$tmp_uninstall_extra_ssh_home/.ssh/config"
grep -q "Port 22" "$tmp_uninstall_extra_ssh_home/.ssh/config"
grep -q "manual local SSH alias kept" ${TMPDIR:-/tmp}/fieldwork-uninstall-ssh-extra.out
grep -q "ssh fieldwork-vps 'ssh-keygen -lf ~/.ssh/authorized_keys'" ${TMPDIR:-/tmp}/fieldwork-uninstall-ssh-extra.out
if grep -q "Using direct target because" ${TMPDIR:-/tmp}/fieldwork-uninstall-ssh-extra.out; then
  echo "uninstall printed removed-alias note for kept custom alias" >&2
  exit 1
fi

fake_uninstall_ufw_bin="$(mktemp_dir)"
cat > "$fake_uninstall_ufw_bin/ssh" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"BatchMode=yes"*) exit 0 ;;
  *"sudo -n ufw status"*)
    printf 'Status: active\n22/tcp ALLOW Anywhere\n'
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$fake_uninstall_ufw_bin/ssh"
tmp_uninstall_ufw_home="$(mktemp_dir)"
HOME="$tmp_uninstall_ufw_home" PATH="$fake_uninstall_ufw_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --remote --yes --quiet >${TMPDIR:-/tmp}/fieldwork-uninstall-ufw.out
grep -q "Detected: public 22/tcp ALLOW rule appears present in ufw." ${TMPDIR:-/tmp}/fieldwork-uninstall-ufw.out

echo "[checks] uninstall keeps SSH alias until remote cleanup finishes"
fake_uninstall_order_bin="$(mktemp_dir)"
cat > "$fake_uninstall_order_bin/ssh" <<'SH'
#!/usr/bin/env bash
args="$*"
require_alias() {
  grep -q '^Host fieldwork-vps$' "$HOME/.ssh/config" 2>/dev/null || {
    printf 'alias missing during %s\n' "$1" >&2
    exit 44
  }
}
case "$args" in
  *"BatchMode=yes"*)
    require_alias reachability
    exit 0
    ;;
  *"test -f ~/.fieldwork/notify.env"*)
    require_alias notify
    exit 1
    ;;
  *"sudo -n ufw status"*)
    require_alias ufw
    printf 'Status: inactive\n'
    exit 0
    ;;
  *"FIELDWORK_UNINSTALL_PURGE="*)
    require_alias remote_user
    printf 'remote_user\n' >> "$FIELDWORK_FAKE_UNINSTALL_ORDER_LOG"
    printf '  ok       remote user order marker\n'
    exit 0
    ;;
  -t*"fieldwork-pr-broker"*)
    require_alias remote_broker
    printf 'remote_broker\n' >> "$FIELDWORK_FAKE_UNINSTALL_ORDER_LOG"
    printf '  [ready] broker order marker\n'
    exit 0
    ;;
  -t*"fieldwork-bot"*)
    require_alias remote_bot
    printf 'remote_bot\n' >> "$FIELDWORK_FAKE_UNINSTALL_ORDER_LOG"
    printf '  [ready] approval bot order marker\n'
    exit 0
    ;;
  *"fieldwork-pr-broker.service"*)
    require_alias broker_discovery
    exit 0
    ;;
  *"fieldwork-bot.service"*)
    require_alias bot_discovery
    exit 0
    ;;
  *)
    require_alias other
    exit 0
    ;;
esac
SH
chmod +x "$fake_uninstall_order_bin/ssh"
tmp_uninstall_order_home="$(mktemp_dir)"
mkdir -p "$tmp_uninstall_order_home/.ssh"
cat > "$tmp_uninstall_order_home/.ssh/config" <<'EOF'
# BEGIN FIELDWORK SSH CONFIG: fieldwork-vps
Host fieldwork-vps
  HostName 203.0.113.10
  User fieldwork
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
# END FIELDWORK SSH CONFIG: fieldwork-vps
EOF
chmod 600 "$tmp_uninstall_order_home/.ssh/config"
FIELDWORK_FAKE_UNINSTALL_ORDER_LOG="$fake_uninstall_order_bin/order.log" HOME="$tmp_uninstall_order_home" PATH="$fake_uninstall_order_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --yes >${TMPDIR:-/tmp}/fieldwork-uninstall-order.out
if grep -q "Host fieldwork-vps" "$tmp_uninstall_order_home/.ssh/config"; then
  echo "uninstall did not remove local SSH alias after remote cleanup" >&2
  exit 1
fi
printf 'remote_user\nremote_broker\nremote_bot\n' > "$fake_uninstall_order_bin/expected-order.log"
cmp "$fake_uninstall_order_bin/expected-order.log" "$fake_uninstall_order_bin/order.log"
awk '
  /^  \[ready\] remote user order marker$/ { remote_user = NR }
  /^  \[ready\] broker order marker$/ { broker = NR }
  /^  \[ready\] approval bot order marker$/ { bot = NR }
  /^  \[ready\] local SSH alias fieldwork-vps$/ { alias = NR }
  END { exit !(remote_user && broker && bot && alias && remote_user < alias && broker < alias && bot < alias) }
' ${TMPDIR:-/tmp}/fieldwork-uninstall-order.out

echo "[checks] uninstall defers temporary sudoers cleanup until system cleanup"
fake_uninstall_sudo_defer_bin="$(mktemp_dir)"
cat > "$fake_uninstall_sudo_defer_bin/ssh" <<'SH'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >> "$FIELDWORK_FAKE_UNINSTALL_SUDO_DEFER_LOG"
case "$args" in
  *"BatchMode=yes"*) exit 0 ;;
  *"test -f ~/.fieldwork/notify.env"*) exit 1 ;;
  *"sudo -n ufw status"*) printf 'Status: inactive\n'; exit 0 ;;
  *"FIELDWORK_UNINSTALL_PURGE="*)
    case "$args" in
      *"FIELDWORK_UNINSTALL_REMOVE_TEMP_SUDO=0"*) ;;
      *) printf 'remote user cleanup did not defer temporary sudo\n' >&2; exit 45 ;;
    esac
    printf 'remote_user\n' >> "$FIELDWORK_FAKE_UNINSTALL_SUDO_DEFER_ORDER"
    printf '  skipped  temporary sudoers rule (deferred until system cleanup)\n'
    exit 0
    ;;
  -t*"rm -f"*"fieldwork-fieldwork"*)
    printf 'temp_sudo\n' >> "$FIELDWORK_FAKE_UNINSTALL_SUDO_DEFER_ORDER"
    exit 0
    ;;
  -t*"fieldwork-pr-broker"*)
    printf 'broker\n' >> "$FIELDWORK_FAKE_UNINSTALL_SUDO_DEFER_ORDER"
    printf '  [ready] broker cleanup marker\n'
    exit 0
    ;;
  *"fieldwork-pr-broker.service"*) exit 0 ;;
  *"fieldwork-bot.service"*) exit 1 ;;
  *"sudo -n true"*) exit 0 ;;
  *"fieldwork-fieldwork"*) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_uninstall_sudo_defer_bin/ssh"
tmp_uninstall_sudo_defer_home="$(mktemp_dir)"
FIELDWORK_FAKE_UNINSTALL_SUDO_DEFER_LOG="$fake_uninstall_sudo_defer_bin/ssh.log" \
FIELDWORK_FAKE_UNINSTALL_SUDO_DEFER_ORDER="$fake_uninstall_sudo_defer_bin/order.log" \
HOME="$tmp_uninstall_sudo_defer_home" PATH="$fake_uninstall_sudo_defer_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --yes >${TMPDIR:-/tmp}/fieldwork-uninstall-sudo-defer.out
printf 'remote_user\nbroker\ntemp_sudo\n' > "$fake_uninstall_sudo_defer_bin/expected-order.log"
cmp "$fake_uninstall_sudo_defer_bin/expected-order.log" "$fake_uninstall_sudo_defer_bin/order.log"
grep -q "^  \[info\] temporary sudoers rule (deferred until system cleanup)$" ${TMPDIR:-/tmp}/fieldwork-uninstall-sudo-defer.out
grep -q "^  \[ready\] broker cleanup marker$" ${TMPDIR:-/tmp}/fieldwork-uninstall-sudo-defer.out
grep -q "^  \[ready\] temporary sudoers rule$" ${TMPDIR:-/tmp}/fieldwork-uninstall-sudo-defer.out
awk '
  /^  \[info\] temporary sudoers rule \(deferred until system cleanup\)$/ { deferred = NR }
  /^  \[ready\] broker cleanup marker$/ { broker = NR }
  /^  \[ready\] temporary sudoers rule$/ { removed = NR }
  END { exit !(deferred && broker && removed && deferred < broker && broker < removed) }
' ${TMPDIR:-/tmp}/fieldwork-uninstall-sudo-defer.out

echo "[checks] uninstall shows delayed remote probe status"
fake_uninstall_status_bin="$(mktemp_dir)"
cat > "$fake_uninstall_status_bin/ssh" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"BatchMode=yes"*) sleep 0.02; exit 0 ;;
  *"test -f ~/.fieldwork/notify.env"*) sleep 0.02; exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_uninstall_status_bin/ssh"
tmp_uninstall_status_home="$(mktemp_dir)"
FIELDWORK_STATUS_DELAY_SECONDS=0.01 HOME="$tmp_uninstall_status_home" PATH="$fake_uninstall_status_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --dry-run --remote >${TMPDIR:-/tmp}/fieldwork-uninstall-status-probes.out
grep -q "^  \\[info\\] checking SSH reachability for uninstall \\.\\.\\.$" ${TMPDIR:-/tmp}/fieldwork-uninstall-status-probes.out
grep -q "^  \\[info\\] checking remote notification config \\.\\.\\.$" ${TMPDIR:-/tmp}/fieldwork-uninstall-status-probes.out
if LC_ALL=C grep -q "$(printf '\033')" ${TMPDIR:-/tmp}/fieldwork-uninstall-status-probes.out; then
  echo "uninstall delayed probe status leaked cursor escape sequences in non-TTY output" >&2
  exit 1
fi

echo "[checks] uninstall replays remote cleanup output before status result"
fake_uninstall_remote_status_bin="$(mktemp_dir)"
cat > "$fake_uninstall_remote_status_bin/ssh" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"BatchMode=yes"*) exit 0 ;;
  *"test -f ~/.fieldwork/notify.env"*) exit 1 ;;
  *"sudo -n ufw status"*) printf 'Status: inactive\n'; exit 0 ;;
  *"FIELDWORK_UNINSTALL_PURGE="*)
    sleep 0.02
    printf '  ok       remote user runner sockets\n'
    exit 0
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_uninstall_remote_status_bin/ssh"
tmp_uninstall_remote_status_home="$(mktemp_dir)"
FIELDWORK_STATUS_DELAY_SECONDS=0.01 HOME="$tmp_uninstall_remote_status_home" PATH="$fake_uninstall_remote_status_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --remote --yes >${TMPDIR:-/tmp}/fieldwork-uninstall-remote-status.out
grep -q "^  \\[info\\] cleaning remote user services \\.\\.\\.$" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-status.out
grep -q "^  \\[ready\\] remote user runner sockets$" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-status.out
grep -q "^  \\[ready\\] remote user cleanup complete$" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-status.out
awk '
  /^  \[ready\] remote user runner sockets$/ { row = NR }
  /^  \[ready\] remote user cleanup complete$/ { ready = NR }
  END { exit !(row && ready && row < ready) }
' ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-status.out
grep -q "^Uninstall complete\\.$" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-status.out

echo "[checks] uninstall stops delayed status before failure rows"
fake_uninstall_remote_fail_bin="$(mktemp_dir)"
cat > "$fake_uninstall_remote_fail_bin/ssh" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"BatchMode=yes"*) exit 0 ;;
  *"test -f ~/.fieldwork/notify.env"*) exit 1 ;;
  *"sudo -n ufw status"*) printf 'Status: inactive\n'; exit 0 ;;
  *"FIELDWORK_UNINSTALL_PURGE="*)
    sleep 0.02
    printf 'remote cleanup diagnostic\n'
    exit 42
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_uninstall_remote_fail_bin/ssh"
tmp_uninstall_remote_fail_home="$(mktemp_dir)"
FIELDWORK_STATUS_DELAY_SECONDS=0.01 HOME="$tmp_uninstall_remote_fail_home" PATH="$fake_uninstall_remote_fail_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --remote --yes >${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-status.out
grep -q "^  \\[info\\] cleaning remote user services \\.\\.\\.$" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-status.out
grep -q "^    remote cleanup diagnostic$" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-status.out
grep -q "^  \\[blocked\\] remote user cleanup failed (command failed)$" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-status.out
awk '
  /^    remote cleanup diagnostic$/ { diagnostic = NR }
  /^  \[blocked\] remote user cleanup failed \(command failed\)$/ { blocked = NR }
  END { exit !(diagnostic && blocked && diagnostic < blocked) }
' ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-status.out
grep -q "^Uninstall finished with follow-up needed\\.$" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-status.out
if LC_ALL=C grep -q "$(printf '\033')" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-status.out; then
  echo "uninstall delayed failure status leaked cursor escape sequences in non-TTY output" >&2
  exit 1
fi

FIELDWORK_STATUS_DELAY_SECONDS=0.01 HOME="$tmp_uninstall_remote_fail_home" PATH="$fake_uninstall_remote_fail_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --remote --yes --quiet >${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-quiet.out
if grep -q "^  \\[info\\] cleaning" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-quiet.out; then
  echo "uninstall --quiet printed waiting status info lines" >&2
  exit 1
fi
if grep -q "^  \\[ready\\]" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-quiet.out; then
  echo "uninstall --quiet printed status success lines" >&2
  exit 1
fi
grep -q "^    remote cleanup diagnostic$" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-quiet.out
grep -q "^  \\[blocked\\] remote user cleanup failed (command failed)$" ${TMPDIR:-/tmp}/fieldwork-uninstall-remote-fail-quiet.out

echo "[checks] uninstall announces interactive sudo SSH handoff"
fake_uninstall_handoff_bin="$(mktemp_dir)"
cat > "$fake_uninstall_handoff_bin/ssh" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  -t*) printf 'interactive sudo cleanup\n'; exit 0 ;;
  *"BatchMode=yes"*) exit 0 ;;
  *"sudo -n ufw status"*) printf 'Status: inactive\n'; exit 0 ;;
  *"fieldwork-pr-broker.service"*) exit 0 ;;
  *"fieldwork-bot.service"*) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_uninstall_handoff_bin/ssh"
tmp_uninstall_handoff_home="$(mktemp_dir)"
HOME="$tmp_uninstall_handoff_home" PATH="$fake_uninstall_handoff_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --broker --yes >${TMPDIR:-/tmp}/fieldwork-uninstall-broker-handoff.out
grep -q "^  \\[info\\] cleaning broker services (sudo), entering interactive SSH$" ${TMPDIR:-/tmp}/fieldwork-uninstall-broker-handoff.out
if grep -q "entering interactive SSH \\.\\.\\." ${TMPDIR:-/tmp}/fieldwork-uninstall-broker-handoff.out; then
  echo "broker interactive SSH handoff was wrapped in a spinner" >&2
  exit 1
fi
HOME="$tmp_uninstall_handoff_home" PATH="$fake_uninstall_handoff_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --bot --yes >${TMPDIR:-/tmp}/fieldwork-uninstall-bot-handoff.out
grep -q "^  \\[info\\] cleaning approval bot (sudo), entering interactive SSH$" ${TMPDIR:-/tmp}/fieldwork-uninstall-bot-handoff.out
if grep -q "entering interactive SSH \\.\\.\\." ${TMPDIR:-/tmp}/fieldwork-uninstall-bot-handoff.out; then
  echo "approval bot interactive SSH handoff was wrapped in a spinner" >&2
  exit 1
fi

echo "[checks] uninstall system users need typed confirmation"
FIELDWORK_FAKE_UNINSTALL_SSH_LOG="$fake_uninstall_bin/remove-users.log" HOME="$tmp_uninstall_home" PATH="$fake_uninstall_bin:$PATH" \
  "$ROOT/bin/fieldwork" uninstall --broker --purge --remove-system-users >${TMPDIR:-/tmp}/fieldwork-uninstall-remove-users.out <<'EOF'
y
not yet
EOF
grep -q "Type \"remove fieldwork users\" to continue" ${TMPDIR:-/tmp}/fieldwork-uninstall-remove-users.out
grep -q "keeping system users/groups" ${TMPDIR:-/tmp}/fieldwork-uninstall-remove-users.out
if "$ROOT/bin/fieldwork" uninstall --broker --no-broker >${TMPDIR:-/tmp}/fieldwork-uninstall-conflict.out 2>&1; then
  echo "uninstall accepted --broker with --no-broker" >&2
  exit 1
fi
grep -q "cannot be used together" ${TMPDIR:-/tmp}/fieldwork-uninstall-conflict.out
if "$ROOT/bin/fieldwork" uninstall --remove-system-users >${TMPDIR:-/tmp}/fieldwork-uninstall-users-no-purge.out 2>&1; then
  echo "uninstall accepted --remove-system-users without --purge" >&2
  exit 1
fi
grep -q "requires --purge" ${TMPDIR:-/tmp}/fieldwork-uninstall-users-no-purge.out

echo "[checks] onboard help"
"$ROOT/bin/fieldwork" onboard --help >${TMPDIR:-/tmp}/fieldwork-onboard-help.out
grep -q -- "--no-workflows" ${TMPDIR:-/tmp}/fieldwork-onboard-help.out
grep -q -- "--status" ${TMPDIR:-/tmp}/fieldwork-onboard-help.out
grep -q -- "--reset-state" ${TMPDIR:-/tmp}/fieldwork-onboard-help.out

echo "[checks] doctor help/explain"
"$ROOT/bin/fieldwork" doctor --help >${TMPDIR:-/tmp}/fieldwork-doctor-help.out
grep -q "usage: fieldwork doctor \\[--remote\\] \\[repo-slug\\] \\[--explain\\]" ${TMPDIR:-/tmp}/fieldwork-doctor-help.out
grep -q -- "--explain" ${TMPDIR:-/tmp}/fieldwork-doctor-help.out
tmp_doctor_local_home="$(mktemp_dir)"
HOME="$tmp_doctor_local_home" PATH="$tmp_doctor_local_home/.local/bin:$PATH" "$ROOT/install.sh" >/dev/null
HOME="$tmp_doctor_local_home" PATH="$tmp_doctor_local_home/.local/bin:$PATH" "$ROOT/bin/fieldwork" doctor >${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "^Local$" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "workstation tools .*bash, git, jq, ssh, scp, sed, grep, rsync" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "Fieldwork command" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "Fieldwork helper files" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "Broker server" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "Repo template" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "not checked .*run with --remote" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "not configured .*optional" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "^Summary$" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "Local install is ready" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "^Next$" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
grep -q "  fieldwork setup" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out
if grep -q "^Legend:" ${TMPDIR:-/tmp}/fieldwork-doctor-local.out; then
  echo "plain doctor should not print a legend" >&2
  exit 1
fi
HOME="$tmp_doctor_local_home" PATH="$tmp_doctor_local_home/.local/bin:$PATH" "$ROOT/bin/fieldwork" doctor --explain >${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
grep -q -- "--remote would verify:" ${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
grep -q -- "- SSH access" ${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
grep -q -- "- broker service" ${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
grep -q -- "- systemd units" ${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
grep -q -- "- repo checkout paths" ${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
grep -q -- "- notification transport" ${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
grep -q "^  Run:$" ${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
grep -q "    fieldwork doctor --remote" ${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
grep -q "Optional. Mobile pushes" ${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
grep -q "^  Enable:$" ${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
grep -q "    fieldwork setup-notify" ${TMPDIR:-/tmp}/fieldwork-doctor-explain.out
fake_doctor_fail_bin="$(mktemp_dir)"
cat > "$fake_doctor_fail_bin/ssh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$fake_doctor_fail_bin/ssh"
if HOME="$tmp_doctor_local_home" PATH="$fake_doctor_fail_bin:$tmp_doctor_local_home/.local/bin:$PATH" "$ROOT/bin/fieldwork" doctor --remote >${TMPDIR:-/tmp}/fieldwork-doctor-remote-fail.out 2>&1; then
  echo "doctor --remote unexpectedly passed when SSH is unreachable" >&2
  exit 1
fi
grep -q "^VPS$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote-fail.out
grep -q "!  SSH access .*cannot reach fieldwork-vps" ${TMPDIR:-/tmp}/fieldwork-doctor-remote-fail.out
grep -q "^Summary$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote-fail.out
grep -q "Remote setup needs attention" ${TMPDIR:-/tmp}/fieldwork-doctor-remote-fail.out
grep -q "^Next$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote-fail.out
if grep -q "^Legend:\\|pending:$\\|After completing it:" ${TMPDIR:-/tmp}/fieldwork-doctor-remote-fail.out; then
  echo "doctor --remote SSH failure should use the shared compact style" >&2
  exit 1
fi

echo "[checks] doctor remote output is grouped by check area"
fake_doctor_bin="$(mktemp_dir)"
cat > "$fake_doctor_bin/ssh" <<'SH'
#!/usr/bin/env bash
while [ "${1:-}" = "-o" ]; do
  shift 2
done
if [ "${1:-}" = "-O" ]; then
  exit 0
fi
args="$*"
case "$args" in
  *"fieldwork-vps true"*) exit 0 ;;
  *"command -v claude"*) exit 0 ;;
  *"command -v gh"*) exit 0 ;;
  *"gh auth status"*) exit 0 ;;
  *"test -d '/home/fieldwork/projects'"*) exit 0 ;;
  *"test -x ~/.local/bin/fieldwork-verify"*) exit 0 ;;
  *"test -x ~/.local/bin/fieldwork-verify-runner && test -x ~/.fieldwork/scripts/fieldwork-verify-pipeline"*) exit 0 ;;
  *"test -f ~/.config/systemd/user/fieldwork-verify-runner.socket && test -f ~/.config/systemd/user/fieldwork-verify-runner@.service"*) exit 0 ;;
  *"systemctl --user is-active --quiet fieldwork-verify-runner.socket"*) exit 0 ;;
  *'echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fieldwork-verify.sock"'*) echo "/run/user/1000/fieldwork-verify.sock"; exit 0 ;;
  *"test -S '/run/user/1000/fieldwork-verify.sock'"*) exit 0 ;;
  *"test -x ~/.local/bin/fieldwork-pr-prepare && test -x ~/.local/bin/fieldwork-pr-prepare-runner && test -x ~/.fieldwork/scripts/fieldwork-pr-prepare-impl"*) exit 0 ;;
  *"test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner.socket && test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner@.service"*) exit 0 ;;
  *"systemctl --user is-active --quiet fieldwork-pr-prepare-runner.socket"*) exit 0 ;;
  *'echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fieldwork-pr-prepare.sock"'*) echo "/run/user/1000/fieldwork-pr-prepare.sock"; exit 0 ;;
  *"test -S '/run/user/1000/fieldwork-pr-prepare.sock'"*) exit 0 ;;
  *"command -v bwrap >/dev/null 2>&1"*) exit 0 ;;
  *"bwrap --unshare-user --unshare-net --unshare-pid --unshare-uts --unshare-ipc --ro-bind / / --tmpfs /tmp --dev /dev --proc /proc -- /bin/true >/dev/null 2>&1"*) exit 0 ;;
  *"command -v systemd-run >/dev/null 2>&1 && systemd-run --user --scope --quiet -p PrivateNetwork=yes -p PrivateTmp=yes -- /bin/true >/dev/null 2>&1"*) exit 0 ;;
  *"test -f ~/.fieldwork/state/claude-login-confirmed"*) exit 1 ;;
  *"test -f ~/.fieldwork/notify.env"*) exit 1 ;;
  *"test -f ~/.config/systemd/user/fieldwork-agent@.service"*) exit 0 ;;
  *"test -f /usr/local/sbin/rotate-pat"*) exit 1 ;;
  *"test -S /run/fieldwork-pr-broker/fieldwork-pr.sock"*) exit 1 ;;
  *"state/broker-pat-confirmed"*) exit 1 ;;
  *"git config --get user.email"*) exit 1 ;;
  *"git config --get user.name"*) exit 1 ;;
  *)
    echo "unexpected fake doctor ssh command: $args" >&2
    exit 1
    ;;
esac
SH
chmod +x "$fake_doctor_bin/ssh"
tmp_doctor_home="$(mktemp_dir)"
HOME="$tmp_doctor_home" PATH="$fake_doctor_bin:$PATH" \
  "$ROOT/bin/fieldwork" doctor --remote --explain >${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^Fieldwork doctor$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^Local$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "workstation tools .*bash, git, jq, ssh, scp, sed, grep, rsync" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "Fieldwork command" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "Fieldwork helper files" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^VPS$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "SSH multiplexing .*enabled; active control socket; dir" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "setup timing .*FIELDWORK_SETUP_TIMING=1 fieldwork setup --skip-sync" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^Remote Fieldwork$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^Account access$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^Notifications$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^Remote services$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^Verify runner$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^PR broker$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^Git identity$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "!  Claude Code login confirmation needed" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "purpose .*optional mobile pushes from Claude lifecycle hooks" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "local .*not configured; optional .* fieldwork setup-notify" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "remote .*not configured; optional .* fieldwork setup-notify --remote" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
if grep -q "^Legend:\\|pending:$\\|manual  \\|blocked" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out; then
  echo "remote doctor should use the shared compact doctor style" >&2
  exit 1
fi
if grep -q "^Notifications pending:$\\|Notifications details:\\|local ntfy topic not configured\\|remote notify.env missing" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out; then
  echo "doctor notifications should be informational, not pending manual actions" >&2
  exit 1
fi
grep -q "purpose .*verify Fieldwork user services and runner sockets" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "purpose .*verify the separate broker that owns the GitHub write token" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "!  PR broker install needed" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "!  PR broker socket missing or not writable" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "!  broker GitHub PAT not confirmed" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^Summary$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "Remote setup needs attention" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^Next$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
grep -q "^  ssh -t fieldwork-vps '~/.local/bin/claude login'$" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out
if grep -q "^After completing it:\\|^Remaining after that:" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out; then
  echo "remote doctor should end with a single Next block" >&2
  exit 1
fi
if grep -q "^\\[fieldwork doctor\\]" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out; then
  echo "doctor output should use clean phase headings" >&2
  exit 1
fi
if grep -q "info:" ${TMPDIR:-/tmp}/fieldwork-doctor-remote.out; then
  echo "doctor output should not use noisy info rows for actionable items" >&2
  exit 1
fi
FIELDWORK_SSH_MULTIPLEX=0 HOME="$tmp_doctor_home" PATH="$fake_doctor_bin:$PATH" \
  "$ROOT/bin/fieldwork" doctor --remote --explain >${TMPDIR:-/tmp}/fieldwork-doctor-remote-mux-off.out || true
grep -q "SSH multiplexing .*disabled by FIELDWORK_SSH_MULTIPLEX=0; dir" ${TMPDIR:-/tmp}/fieldwork-doctor-remote-mux-off.out

echo "[checks] doctor Codex Desktop and app-server diagnostics"
fake_codex_doctor_bin="$(mktemp_dir)"
cat > "$fake_codex_doctor_bin/ssh" <<'SH'
#!/usr/bin/env bash
while [ "${1:-}" = "-o" ]; do
  shift 2
done
if [ "${1:-}" = "-O" ]; then
  exit 0
fi
args="$*"
case "$args" in
  *"cat ~/.fieldwork/agents"*) echo "codex"; exit 0 ;;
  *"fieldwork-vps true"*) exit 0 ;;
  *"command -v codex"*"codex --version"*) echo "codex-cli ${FAKE_CODEX_VERSION:-0.137.0}"; exit 0 ;;
  *"command -v gh"*) exit 0 ;;
  *"gh auth status"*) exit 0 ;;
  *"test -d '/home/fieldwork/projects'"*) exit 0 ;;
  *"CODEX_LOGIN_STATE=logged_in"*)
    case "${FAKE_CODEX_LOGIN:-logged_in}" in
      logged_out) echo "CODEX_LOGIN_STATE=logged_out" ;;
      marker_only) echo "CODEX_LOGIN_STATE=marker_only" ;;
      *) echo "CODEX_LOGIN_STATE=logged_in" ;;
    esac
    exit 0
    ;;
  *"test -f ~/.fieldwork/notify.env"*) exit 1 ;;
  *"test -x ~/.local/bin/fieldwork-verify"*) exit 0 ;;
  *"test -x ~/.local/bin/fieldwork-verify-runner && test -x ~/.fieldwork/scripts/fieldwork-verify-pipeline"*) exit 0 ;;
  *"test -f ~/.config/systemd/user/fieldwork-verify-runner.socket && test -f ~/.config/systemd/user/fieldwork-verify-runner@.service"*) exit 0 ;;
  *"systemctl --user is-active --quiet fieldwork-verify-runner.socket"*) exit 0 ;;
  *'echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fieldwork-verify.sock"'*) echo "/run/user/1000/fieldwork-verify.sock"; exit 0 ;;
  *"test -S '/run/user/1000/fieldwork-verify.sock'"*) exit 0 ;;
  *"test -x ~/.local/bin/fieldwork-pr-prepare && test -x ~/.local/bin/fieldwork-pr-prepare-runner && test -x ~/.fieldwork/scripts/fieldwork-pr-prepare-impl"*) exit 0 ;;
  *"test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner.socket && test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner@.service"*) exit 0 ;;
  *"systemctl --user is-active --quiet fieldwork-pr-prepare-runner.socket"*) exit 0 ;;
  *'echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fieldwork-pr-prepare.sock"'*) echo "/run/user/1000/fieldwork-pr-prepare.sock"; exit 0 ;;
  *"test -S '/run/user/1000/fieldwork-pr-prepare.sock'"*) exit 0 ;;
  *"command -v bwrap >/dev/null 2>&1"*) exit 0 ;;
  *"bwrap --unshare-user --unshare-net --unshare-pid --unshare-uts --unshare-ipc --ro-bind / / --tmpfs /tmp --dev /dev --proc /proc -- /bin/true >/dev/null 2>&1"*) exit 0 ;;
  *"test -f /usr/local/sbin/rotate-pat"*) exit 0 ;;
  *"test -S /run/fieldwork-pr-broker/fieldwork-pr.sock"*) exit 0 ;;
  *"preflight request missing required field: repo"*) exit 0 ;;
  *"state/broker-pat-confirmed"*) exit 0 ;;
  *'test "$(id -un)" ='*) exit 0 ;;
  *"command -v fieldwork-verify"*"command -v fieldwork-pr-submit"*) exit 0 ;;
  *"loginctl show-user"*) exit 0 ;;
  *"permissions.fieldwork.network.unix_sockets"*) exit 0 ;;
  *'uid="$(id -u)"; runtime="${XDG_RUNTIME_DIR:-/run/user/$uid}"; test "$runtime" = "/run/user/$uid" && test -d "$runtime"'*) exit 0 ;;
  *"APP_SERVER_PROCESS"*)
    case "${FAKE_CODEX_APP_SERVER:-clean}" in
      stale)
        printf 'APP_SERVER_PROCESS=present\nAPP_SERVER_PROXY=present\nAPP_SERVER_SOCKET=present\nAPP_SERVER_STALE_SOCKET_LOG=present\nAPP_SERVER_AUTH_ENDED_LOG=present\n'
        ;;
      *)
        printf 'APP_SERVER_PROCESS=present\nAPP_SERVER_PROXY=present\nAPP_SERVER_SOCKET=present\nAPP_SERVER_STALE_SOCKET_LOG=missing\nAPP_SERVER_AUTH_ENDED_LOG=missing\n'
        ;;
    esac
    exit 0
    ;;
  *"command -v fieldwork-codex-sandbox"*) exit 0 ;;
  *"fieldwork-codex-sandbox run"*) exit 0 ;;
  *"git config --get user.email"*) echo "fieldwork@example.com"; exit 0 ;;
  *"git config --get user.name"*) echo "Fieldwork"; exit 0 ;;
  *"echo repo=ok"*) printf 'repo=ok\nstack=none\n'; exit 0 ;;
  *)
    echo "unexpected fake codex doctor ssh command: $args" >&2
    exit 1
    ;;
esac
SH
chmod +x "$fake_codex_doctor_bin/ssh"

tmp_codex_desktop_home="$(mktemp_dir)"
mkdir -p "$tmp_codex_desktop_home/.codex"
cat > "$tmp_codex_desktop_home/.codex/.codex-global-state.json" <<'JSON'
{
  "codex-managed-remote-connections": [
    {
      "hostId": "remote-ssh-discovered:fieldwork-vps",
      "displayName": "fieldwork-vps",
      "alias": "fieldwork-vps"
    }
  ],
  "selected-remote-host-id": "remote-ssh-discovered:fieldwork-vps",
  "remote-connection-auto-connect-by-host-id": {
    "remote-ssh-discovered:fieldwork-vps": true
  },
  "host-id-remote-control-allowed": {
    "remote-ssh-discovered:fieldwork-vps": true
  },
  "project-order": ["/Users/example/project"]
}
JSON
FAKE_CODEX_APP_SERVER=stale HOME="$tmp_codex_desktop_home" PATH="$fake_codex_doctor_bin:$PATH" \
  "$ROOT/bin/fieldwork" doctor --remote fieldwork-smoke --explain >${TMPDIR:-/tmp}/fieldwork-doctor-codex-folder-missing.out
grep -q "^Codex Desktop$" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-folder-missing.out
grep -q "Codex SSH host known to Desktop" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-folder-missing.out
grep -q "Codex Desktop repo folder not opened" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-folder-missing.out
grep -q "/home/fieldwork/projects/fieldwork-smoke" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-folder-missing.out
grep -q "Codex app-server stale socket seen" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-folder-missing.out
grep -q "Codex app-server saw ended app session" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-folder-missing.out
if grep -q "app_session_terminated\\|session has ended\\|control socket is already in use" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-folder-missing.out; then
  echo "Codex doctor must not print raw app-server log lines" >&2
  exit 1
fi

cat > "$tmp_codex_desktop_home/.codex/.codex-global-state.json" <<'JSON'
{
  "codex-managed-remote-connections": [
    {
      "hostId": "remote-ssh-discovered:fieldwork-vps",
      "displayName": "fieldwork-vps",
      "alias": "fieldwork-vps"
    }
  ],
  "selected-remote-host-id": "remote-ssh-discovered:cc-server",
  "remote-connection-auto-connect-by-host-id": {
    "remote-ssh-discovered:fieldwork-vps": true
  },
  "host-id-remote-control-allowed": {
    "remote-ssh-discovered:fieldwork-vps": true
  },
  "remote-projects": [
    {"path": "/home/fieldwork/projects/fieldwork-smoke"}
  ]
}
JSON
HOME="$tmp_codex_desktop_home" PATH="$fake_codex_doctor_bin:$PATH" \
  "$ROOT/bin/fieldwork" doctor --remote fieldwork-smoke --explain >${TMPDIR:-/tmp}/fieldwork-doctor-codex-host-not-selected.out
grep -q "Codex SSH host not selected" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-host-not-selected.out
grep -q "select the configured VPS SSH connection (fieldwork-vps) in Codex Desktop Connections -> SSH" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-host-not-selected.out
grep -q "stale non-VPS context" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-host-not-selected.out

cat > "$tmp_codex_desktop_home/.codex/.codex-global-state.json" <<'JSON'
{
  "codex-managed-remote-connections": [
    {
      "hostId": "remote-ssh-discovered:fieldwork-vps",
      "displayName": "fieldwork-vps",
      "alias": "fieldwork-vps"
    }
  ],
  "selected-remote-host-id": "remote-ssh-discovered:fieldwork-vps",
  "remote-connection-auto-connect-by-host-id": {
    "remote-ssh-discovered:fieldwork-vps": true
  },
  "host-id-remote-control-allowed": {
    "remote-ssh-discovered:fieldwork-vps": true
  },
  "remote-projects": [
    {"path": "/home/fieldwork/projects/fieldwork-smoke"}
  ]
}
JSON
HOME="$tmp_codex_desktop_home" PATH="$fake_codex_doctor_bin:$PATH" \
  "$ROOT/bin/fieldwork" doctor --remote fieldwork-smoke --explain >${TMPDIR:-/tmp}/fieldwork-doctor-codex-folder-present.out
grep -q "Codex Desktop repo folder recorded" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-folder-present.out
if grep -q "Codex Desktop repo folder not opened" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-folder-present.out; then
  echo "Codex doctor should accept a recorded remote repo folder" >&2
  exit 1
fi

FAKE_CODEX_VERSION=0.133.0 HOME="$tmp_codex_desktop_home" PATH="$fake_codex_doctor_bin:$PATH" \
  "$ROOT/bin/fieldwork" doctor --remote --explain >${TMPDIR:-/tmp}/fieldwork-doctor-codex-old.out || true
grep -q "remote Codex CLI 0.133.0 older than 0.137.0" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-old.out
grep -Fq 'ssh -t fieldwork-vps '"'"'npm install -g --prefix "$HOME/.local" @openai/codex@0.137.0'"'"'' ${TMPDIR:-/tmp}/fieldwork-doctor-codex-old.out

FAKE_CODEX_LOGIN=logged_out HOME="$tmp_codex_desktop_home" PATH="$fake_codex_doctor_bin:$PATH" \
  "$ROOT/bin/fieldwork" doctor --remote --explain >${TMPDIR:-/tmp}/fieldwork-doctor-codex-logged-out.out
grep -q "Codex login not authenticated" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-logged-out.out
grep -q "marker is ignored when Codex itself reports logged out" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-logged-out.out
if grep -q "Codex login confirmed" ${TMPDIR:-/tmp}/fieldwork-doctor-codex-logged-out.out; then
  echo "Codex doctor must not trust marker-only state when Codex reports logged out" >&2
  exit 1
fi

echo "[checks] doctor repo verify readiness"
fake_doctor_repo_bin="$(mktemp_dir)"
cat > "$fake_doctor_repo_bin/ssh" <<'SH'
#!/usr/bin/env bash
while [ "${1:-}" = "-o" ]; do
  shift 2
done
if [ "${1:-}" = "-O" ]; then
  exit 0
fi
args="$*"
case "$args" in
  *"fieldwork-vps true"*) exit 0 ;;
  *"command -v claude"*) exit 0 ;;
  *"command -v gh"*) exit 0 ;;
  *"gh auth status"*) exit 0 ;;
  *"test -d '/home/fieldwork/projects'"*) exit 0 ;;
  *"test -x ~/.local/bin/fieldwork-verify"*) exit 0 ;;
  *"test -x ~/.local/bin/fieldwork-verify-runner && test -x ~/.fieldwork/scripts/fieldwork-verify-pipeline"*) exit 0 ;;
  *"test -f ~/.config/systemd/user/fieldwork-verify-runner.socket && test -f ~/.config/systemd/user/fieldwork-verify-runner@.service"*) exit 0 ;;
  *"systemctl --user is-active --quiet fieldwork-verify-runner.socket"*) exit 0 ;;
  *'echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fieldwork-verify.sock"'*) echo "/run/user/1000/fieldwork-verify.sock"; exit 0 ;;
  *"test -S '/run/user/1000/fieldwork-verify.sock'"*) exit 0 ;;
  *"test -x ~/.local/bin/fieldwork-pr-prepare && test -x ~/.local/bin/fieldwork-pr-prepare-runner && test -x ~/.fieldwork/scripts/fieldwork-pr-prepare-impl"*) exit 0 ;;
  *"test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner.socket && test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner@.service"*) exit 0 ;;
  *"systemctl --user is-active --quiet fieldwork-pr-prepare-runner.socket"*) exit 0 ;;
  *'echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fieldwork-pr-prepare.sock"'*) echo "/run/user/1000/fieldwork-pr-prepare.sock"; exit 0 ;;
  *"test -S '/run/user/1000/fieldwork-pr-prepare.sock'"*) exit 0 ;;
  *"command -v bwrap >/dev/null 2>&1"*) exit 0 ;;
  *"bwrap --unshare-user --unshare-net --unshare-pid --unshare-uts --unshare-ipc --ro-bind / / --tmpfs /tmp --dev /dev --proc /proc -- /bin/true >/dev/null 2>&1"*) exit 0 ;;
  *"test -f ~/.fieldwork/state/claude-login-confirmed"*) exit 0 ;;
  *"test -f ~/.fieldwork/notify.env"*) exit 1 ;;
  *"test -f ~/.config/systemd/user/fieldwork-agent@.service"*) exit 0 ;;
  *"test -f /usr/local/sbin/rotate-pat"*) exit 0 ;;
  *"test -S /run/fieldwork-pr-broker/fieldwork-pr.sock"*) exit 0 ;;
  *"http://localhost/preflight"*) printf '{"ok": false, "request_id": "test", "error": "preflight request missing required field: repo"}\n'; exit 0 ;;
  *"state/broker-pat-confirmed"*) exit 0 ;;
  *"stat -c '%U:%G %a' /etc/fieldwork-pr-broker/gh-token"*) exit 0 ;;
  *"git config --get user.email"*) echo "fieldwork@example.com"; exit 0 ;;
  *"git config --get user.name"*) echo "Fieldwork"; exit 0 ;;
  *"repo_path="*"/home/fieldwork/projects/whichonetho"*)
    cat <<'EOF'
repo=ok
stack=node
pkg_mgr=npm
install_cmd=npm ci
node=missing
npm=missing
pkg_mgr_tool=missing
project_deps=missing
EOF
    exit 0
    ;;
  *)
    echo "unexpected fake doctor repo ssh command: $args" >&2
    exit 1
    ;;
esac
SH
chmod +x "$fake_doctor_repo_bin/ssh"
if HOME="$tmp_doctor_home" PATH="$fake_doctor_repo_bin:$PATH" \
  "$ROOT/bin/fieldwork" doctor --remote whichonetho --explain >${TMPDIR:-/tmp}/fieldwork-doctor-repo.out; then
  echo "doctor --remote <slug> unexpectedly passed with missing Node deps" >&2
  exit 1
fi
grep -q "^Repo verify readiness$" ${TMPDIR:-/tmp}/fieldwork-doctor-repo.out
grep -q "repo checkout exists at /home/fieldwork/projects/whichonetho" ${TMPDIR:-/tmp}/fieldwork-doctor-repo.out
grep -q "repo stack node (npm)" ${TMPDIR:-/tmp}/fieldwork-doctor-repo.out
grep -q "!  Node.js toolchain missing" ${TMPDIR:-/tmp}/fieldwork-doctor-repo.out
grep -q "Node.js 22 from the signed NodeSource apt source" ${TMPDIR:-/tmp}/fieldwork-doctor-repo.out
grep -q "!  node_modules missing" ${TMPDIR:-/tmp}/fieldwork-doctor-repo.out
grep -q "npm ci" ${TMPDIR:-/tmp}/fieldwork-doctor-repo.out
grep -q "^  ssh -t fieldwork-vps 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'$" ${TMPDIR:-/tmp}/fieldwork-doctor-repo.out

fake_doctor_apparmor_bin="$(mktemp_dir)"
cat > "$fake_doctor_apparmor_bin/ssh" <<'SH'
#!/usr/bin/env bash
while [ "${1:-}" = "-o" ]; do
  shift 2
done
if [ "${1:-}" = "-O" ]; then
  exit 0
fi
args="$*"
case "$args" in
  *"fieldwork-vps true"*) exit 0 ;;
  *"command -v claude"*) exit 0 ;;
  *"command -v gh"*) exit 0 ;;
  *"gh auth status"*) exit 0 ;;
  *"test -d '/home/fieldwork/projects'"*) exit 0 ;;
  *"test -x ~/.local/bin/fieldwork-verify"*) exit 0 ;;
  *"test -x ~/.local/bin/fieldwork-verify-runner && test -x ~/.fieldwork/scripts/fieldwork-verify-pipeline"*) exit 0 ;;
  *"test -f ~/.config/systemd/user/fieldwork-verify-runner.socket && test -f ~/.config/systemd/user/fieldwork-verify-runner@.service"*) exit 0 ;;
  *"systemctl --user is-active --quiet fieldwork-verify-runner.socket"*) exit 0 ;;
  *'echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fieldwork-verify.sock"'*) echo "/run/user/1000/fieldwork-verify.sock"; exit 0 ;;
  *"test -S '/run/user/1000/fieldwork-verify.sock'"*) exit 0 ;;
  *"test -x ~/.local/bin/fieldwork-pr-prepare && test -x ~/.local/bin/fieldwork-pr-prepare-runner && test -x ~/.fieldwork/scripts/fieldwork-pr-prepare-impl"*) exit 0 ;;
  *"test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner.socket && test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner@.service"*) exit 0 ;;
  *"systemctl --user is-active --quiet fieldwork-pr-prepare-runner.socket"*) exit 0 ;;
  *'echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fieldwork-pr-prepare.sock"'*) echo "/run/user/1000/fieldwork-pr-prepare.sock"; exit 0 ;;
  *"test -S '/run/user/1000/fieldwork-pr-prepare.sock'"*) exit 0 ;;
  *"command -v bwrap >/dev/null 2>&1"*) exit 0 ;;
  *"bwrap --unshare-user --unshare-net --unshare-pid --unshare-uts --unshare-ipc --ro-bind / / --tmpfs /tmp --dev /dev --proc /proc -- /bin/true >/dev/null 2>&1"*) exit 1 ;;
  *"command -v systemd-run >/dev/null 2>&1 && systemd-run --user --scope --quiet -p PrivateNetwork=yes -p PrivateTmp=yes -- /bin/true >/dev/null 2>&1"*) exit 0 ;;
  *"cat /proc/sys/kernel/unprivileged_userns_clone"*) echo "1"; exit 0 ;;
  *"cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns"*) echo "1"; exit 0 ;;
  *"aa-status"*) echo "no"; exit 0 ;;
  *"test -f ~/.fieldwork/state/claude-login-confirmed"*) exit 0 ;;
  *"test -f ~/.fieldwork/notify.env"*) exit 1 ;;
  *"test -f ~/.config/systemd/user/fieldwork-agent@.service"*) exit 0 ;;
  *"test -f /usr/local/sbin/rotate-pat"*) exit 0 ;;
  *"test -S /run/fieldwork-pr-broker/fieldwork-pr.sock"*) exit 0 ;;
  *"http://localhost/preflight"*) printf '{"ok": false, "request_id": "test", "error": "preflight request missing required field: repo"}\n'; exit 0 ;;
  *"state/broker-pat-confirmed"*) exit 0 ;;
  *"stat -c '%U:%G %a' /etc/fieldwork-pr-broker/gh-token"*) exit 0 ;;
  *"git config --get user.email"*) echo "fieldwork@example.com"; exit 0 ;;
  *"git config --get user.name"*) echo "Fieldwork"; exit 0 ;;
  *)
    echo "unexpected fake doctor apparmor ssh command: $args" >&2
    exit 1
    ;;
esac
SH
chmod +x "$fake_doctor_apparmor_bin/ssh"
HOME="$tmp_doctor_home" PATH="$fake_doctor_apparmor_bin:$PATH" \
  "$ROOT/bin/fieldwork" doctor --remote --explain >${TMPDIR:-/tmp}/fieldwork-doctor-apparmor.out || true
grep -q "verify inner sandbox unavailable .* AppArmor restricts bwrap" ${TMPDIR:-/tmp}/fieldwork-doctor-apparmor.out
grep -q "sudo install -m 644 ~/fieldwork/lib/apparmor/fieldwork-bwrap /etc/apparmor.d/fieldwork-bwrap" ${TMPDIR:-/tmp}/fieldwork-doctor-apparmor.out
grep -q "sudo apparmor_parser -r /etc/apparmor.d/fieldwork-bwrap" ${TMPDIR:-/tmp}/fieldwork-doctor-apparmor.out
grep -q "systemd-run fallback .*not accepted as verify-ready" ${TMPDIR:-/tmp}/fieldwork-doctor-apparmor.out
if grep -q "verify inner sandbox ready (systemd-run" ${TMPDIR:-/tmp}/fieldwork-doctor-apparmor.out; then
  echo "doctor must not report verify ready from systemd-run alone" >&2
  exit 1
fi

echo "[checks] setup help"
"$ROOT/bin/fieldwork" setup --help >${TMPDIR:-/tmp}/fieldwork-setup-help.out
grep -q "usage: fieldwork setup" ${TMPDIR:-/tmp}/fieldwork-setup-help.out
grep -q "main first-run entrypoint" ${TMPDIR:-/tmp}/fieldwork-setup-help.out

echo "[checks] quickstart help and resume ledger"
"$ROOT/bin/fieldwork" quickstart --help >${TMPDIR:-/tmp}/fieldwork-quickstart-help.out
grep -q "usage: fieldwork quickstart" ${TMPDIR:-/tmp}/fieldwork-quickstart-help.out
grep -q -- "--status" ${TMPDIR:-/tmp}/fieldwork-quickstart-help.out
grep -q -- "--reset-state" ${TMPDIR:-/tmp}/fieldwork-quickstart-help.out
tmp_quickstart_home="$(mktemp_dir)"
ROOT="$ROOT" HOME="$tmp_quickstart_home" bash >${TMPDIR:-/tmp}/fieldwork-quickstart-resume.out <<'SH'
set -euo pipefail
FIELDWORK_ROOT="$ROOT"
FIELDWORK_PROFILE=test-profile
FIELDWORK_FORGE=github
FIELDWORK_SSH_HOST=fake-vps
FIELDWORK_REMOTE_USER=fieldwork
FIELDWORK_PROJECTS_DIR=/home/fieldwork/projects
FIELDWORK_DEFAULT_BRANCH=main
phase_section() { echo "$1"; }
info_row() { printf '%s=%s\n' "$1" "$2"; }
setup_status_line() { printf '%s:%s\n' "$1" "$2"; }
status_ok_line() { printf 'ok:%s\n' "$1"; }
label_line() { printf '%s:\n' "$1"; }
valid_owner_repo() { case "$1" in */*) return 0 ;; *) return 1 ;; esac; }
setup_calls=0
onboard_calls=0
seen_setup_args=""
seen_onboard_args=""
setup_fieldwork() {
  setup_calls=$((setup_calls + 1))
  seen_setup_args="$*"
}
source "$ROOT/lib/cli/quickstart.sh"
quickstart_run_onboard() {
  onboard_calls=$((onboard_calls + 1))
  seen_onboard_args="$*"
}
quickstart_fieldwork owner/repo --yes --agent codex --no-workflows --with-approval-gate --branch fieldwork/init
quickstart_fieldwork owner/repo --yes --agent codex --no-workflows --with-approval-gate --branch fieldwork/init
[ "$setup_calls" = "1" ]
[ "$onboard_calls" = "1" ]
case "$seen_setup_args" in
  *"--yes"*"--agent codex"*|*"--agent codex"*"--yes"*) ;;
  *) echo "missing setup args"; exit 1 ;;
esac
case "$seen_onboard_args" in
  *"owner/repo"*) ;;
  *) echo "missing onboard repo"; exit 1 ;;
esac
case "$seen_onboard_args" in
  *"--no-workflows"*) ;;
  *) echo "missing --no-workflows"; exit 1 ;;
esac
case "$seen_onboard_args" in
  *"--with-approval-gate"*) ;;
  *) echo "missing --with-approval-gate"; exit 1 ;;
esac
setup_ledger="$(quickstart_ledger_path setup)"
onboard_ledger="$(quickstart_ledger_path owner/repo)"
test -f "$setup_ledger"
test -f "$onboard_ledger"
grep -q '^setup=done$' "$setup_ledger"
grep -q '^onboard=done$' "$onboard_ledger"
quickstart_fieldwork owner/repo --status
SH
grep -q "setup phase already completed" ${TMPDIR:-/tmp}/fieldwork-quickstart-resume.out
grep -q "onboarding phase already completed" ${TMPDIR:-/tmp}/fieldwork-quickstart-resume.out
grep -q "setup=done" ${TMPDIR:-/tmp}/fieldwork-quickstart-resume.out
grep -q 'label_line "Next action"' "$ROOT/bin/fieldwork"

echo "[checks] setup checklist output"
fake_setup_bin="$(mktemp_dir)"
cat > "$fake_setup_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  echo "hostname fake-vps.example"
  echo "user fieldwork"
  exit 0
fi
echo "ssh: connect to host fake-vps port 22: Operation not permitted" >&2
exit 255
SH
chmod +x "$fake_setup_bin/ssh"
tmp_setup_home="$(mktemp_dir)"
HOME="$tmp_setup_home" "$ROOT/install.sh" >/dev/null
HOME="$tmp_setup_home" FIELDWORK_SSH_HOST=fake-vps PATH="$fake_setup_bin:$tmp_setup_home/.local/bin:$PATH" "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-checklist.out || true
grep -q "^Fieldwork setup" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
grep -q "^Setup map:$" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
grep -q "\\[needs-action\\] Broker token: pending" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
grep -q "^\\[1/5\\] Connect to VPS" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
grep -q "VPS is not reachable" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
grep -q "SSH reported:" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
grep -q "Operation not permitted" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
grep -q "local execution environment blocked outbound SSH" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
grep -q "run fieldwork setup from a terminal with outbound SSH access" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
grep -q "^Manual action needed:" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
grep -q "^Run:" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
grep -q "^Then rerun:" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out
if grep -q "Configure local ntfy notifications now" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out; then
  echo "setup prompted for ntfy before VPS reachability was ready" >&2
  exit 1
fi
if grep -q "^Notifications" ${TMPDIR:-/tmp}/fieldwork-setup-checklist.out; then
  echo "setup showed notifications section before VPS reachability was ready" >&2
  exit 1
fi

echo "[checks] setup fast rerun snapshot and SSH mux"
fake_setup_fast_bin="$(mktemp_dir)"
cat > "$fake_setup_fast_bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_SETUP_FAST_SSH_LOG"
if [ "${1:-}" = "-G" ]; then
  echo "hostname fake-vps.example"
  echo "user fieldwork"
  exit 0
fi
mux_seen=0
mux_master=""
control_path_seen=0
control_persist_seen=0
while [ "${1:-}" = "-o" ]; do
  case "${2:-}" in
    ControlMaster=*) mux_seen=1; mux_master="${2#ControlMaster=}" ;;
    ControlPath=*) control_path_seen=1 ;;
    ControlPersist=*) control_persist_seen=1 ;;
  esac
  shift 2
done
if [ "${1:-}" = "-O" ]; then
  exit 0
fi
args="$*"
emit_snapshot() {
  checkout="${1:-ok}"
  gh_live="${2:-ok}"
  cat <<EOF
remote_user=fieldwork
fieldwork_cli=ok
fieldwork_checkout=$checkout
path_configured=ok
bootstrap_ready=ok
claude_login=ok
gh_cli=ok
gh_hosts=ok
gh_live=$gh_live
verify_runner=ok
prepare_runner=ok
claude_service=ok
broker_socket=ok
broker_pat_tool=ok
broker_thin_client=ok
broker_pat_marker=ok
broker_pat_sudo=ok
temporary_sudo=missing
public_ssh_rule=missing
projects_dir=ok
timing_remote_fingerprint=0.010
timing_remote_gh_auth_status=0.020
timing_remote_broker_checks=0.030
timing_remote_script_total=0.060
EOF
}
probe_count=0
if [ -n "${FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT:-}" ] && [ -f "$FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT" ]; then
  probe_count="$(cat "$FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT")"
fi
case "$args" in
  *"fieldwork-vps true"*)
    if [ "$mux_master" = "auto" ] && [ "${FIELDWORK_FAKE_SETUP_FAST_MUX_FAIL:-0}" = "1" ]; then
      exit 255
    fi
    if [ "$mux_seen" != "1" ] && [ "${FIELDWORK_FAKE_SETUP_FAST_PLAIN_FAIL:-0}" = "1" ]; then
      echo "ssh: connect to host fake-vps port 22: Connection refused" >&2
      exit 255
    fi
    exit 0
    ;;
  *".local/bin/fieldwork-setup-probe"*)
    if [ "$mux_master" = "auto" ] && [ "${FIELDWORK_FAKE_SETUP_FAST_MUX_FAIL:-0}" = "1" ]; then
      exit 255
    fi
    if [ "$mux_seen" != "1" ] && [ "${FIELDWORK_FAKE_SETUP_FAST_PLAIN_FAIL:-0}" = "1" ]; then
      echo "ssh: connect to host fake-vps port 22: Connection refused" >&2
      exit 255
    fi
    probe_count=$((probe_count + 1))
    [ -z "${FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT:-}" ] || printf '%s\n' "$probe_count" > "$FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT"
    case "${FIELDWORK_FAKE_SETUP_FAST_MODE:-ok}" in
      helper-missing) exit 127 ;;
      ok) emit_snapshot ok ok; exit 0 ;;
      gh-timeout) emit_snapshot ok timeout; exit 0 ;;
      dirty-sync)
        if [ "$probe_count" -eq 1 ]; then
          emit_snapshot missing ok
        else
          emit_snapshot ok ok
        fi
        exit 0
        ;;
      partial) echo "remote_user=fieldwork"; exit 0 ;;
      garbage) echo "not a snapshot"; exit 0 ;;
      nonzero) exit 42 ;;
      nonzero-partial) echo "remote_user=fieldwork"; exit 42 ;;
      timeout) sleep 2; exit 0 ;;
      *) emit_snapshot ok ok; exit 0 ;;
    esac
    ;;
  *"bash -s"*)
    if [ "$mux_master" = "auto" ] && [ "${FIELDWORK_FAKE_SETUP_FAST_MUX_FAIL:-0}" = "1" ]; then
      exit 255
    fi
    if [ "$mux_seen" != "1" ] && [ "${FIELDWORK_FAKE_SETUP_FAST_PLAIN_FAIL:-0}" = "1" ]; then
      echo "ssh: connect to host fake-vps port 22: Connection refused" >&2
      exit 255
    fi
    probe_count=$((probe_count + 1))
    [ -z "${FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT:-}" ] || printf '%s\n' "$probe_count" > "$FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT"
    case "${FIELDWORK_FAKE_SETUP_FAST_MODE:-ok}" in
      helper-missing) emit_snapshot ok ok; exit 0 ;;
      ok) emit_snapshot ok ok; exit 0 ;;
      gh-timeout) emit_snapshot ok timeout; exit 0 ;;
      dirty-sync)
        if [ "$probe_count" -eq 1 ]; then
          emit_snapshot missing ok
        else
          emit_snapshot ok ok
        fi
        exit 0
        ;;
      partial) echo "remote_user=fieldwork"; exit 0 ;;
      garbage) echo "not a snapshot"; exit 0 ;;
      nonzero) exit 42 ;;
      nonzero-partial) echo "remote_user=fieldwork"; exit 42 ;;
      timeout) sleep 2; exit 0 ;;
      *) emit_snapshot ok ok; exit 0 ;;
    esac
    ;;
  *"fieldwork-vps id -un"*) echo "fieldwork"; exit 0 ;;
  *"fieldwork-vps test -x ~/.local/bin/fieldwork"*) exit 0 ;;
  *"fieldwork-vps cd ~/fieldwork && cksum "*)
    printf '%s\n' "$FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT"
    exit 0
    ;;
  *"fieldwork-vps case "*) exit 0 ;;
  *"profile=\"\$HOME/.profile\""*) exit 0 ;;
  *"~/.fieldwork/agents"*) exit 0 ;;
  *"cd ~/fieldwork && bash install.sh --quiet"*) exit 0 ;;
  *"command -v claude"*"command -v gh"*"fieldwork-agent@.service"*) exit 0 ;;
  *"test -f ~/.fieldwork/state/claude-login-confirmed"*) exit 0 ;;
	  *"gh auth status"*) exit 0 ;;
	  *"test -f ~/.config/systemd/user/fieldwork-agent@.service"*) exit 0 ;;
	  *"fieldwork-verify-runner.socket"*"bwrap --unshare-user --unshare-net --unshare-pid --unshare-uts --unshare-ipc"*) exit 0 ;;
	  *"test -f ~/.config/systemd/user/fieldwork-verify-runner.socket"*) exit 0 ;;
	  *"test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner.socket"*) exit 0 ;;
  *"test -S /run/fieldwork-pr-broker/fieldwork-pr.sock"*) exit 0 ;;
  *"http://localhost/preflight"*)
    printf '{"ok": false, "request_id": "test", "error": "preflight request missing required field: repo"}\n'
    exit 0
    ;;
  *"test -f /usr/local/sbin/rotate-pat"*) exit 0 ;;
  *"test -e ~/.local/bin/fieldwork-pr-submit"*) exit 0 ;;
  *"test -f ~/.fieldwork/state/broker-pat-confirmed"*) exit 0 ;;
  *"sudo -n stat -c '%U:%G %a' /etc/fieldwork-pr-broker/gh-token"*) exit 0 ;;
  *"test -f '/etc/sudoers.d/fieldwork-fieldwork'"*) exit 1 ;;
  *"sudo -n ufw status"*) exit 1 ;;
  *)
    echo "unexpected fake setup-fast ssh command: $args" >&2
    exit 1
    ;;
esac
SH
cat > "$fake_setup_fast_bin/rsync" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG"
exit 0
SH
chmod +x "$fake_setup_fast_bin/ssh" "$fake_setup_fast_bin/rsync"
tmp_setup_fast_home="$(mktemp_dir)"
HOME="$tmp_setup_fast_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-ok.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-ok.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-ok.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_fast_home" PATH="$fake_setup_fast_bin:$tmp_setup_fast_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-fast-ok.out
grep -q "\\[info\\] Remote state verified" ${TMPDIR:-/tmp}/fieldwork-setup-fast-ok.out
test "$(cat "$fake_setup_fast_bin/probes-ok.count")" = "1"
grep -q "ControlMaster=auto" "$fake_setup_fast_bin/ssh-ok.log"
awk '
  /bash -s/ { seen_probe = 1 }
  /\.local\/bin\/fieldwork-setup-probe/ { seen_probe = 1 }
  !seen_probe && /fieldwork-vps true/ {
    count++
    if ($0 ~ /ControlMaster=auto/ && $0 ~ /ControlPersist=600/ && $0 ~ /ControlPath=/) mux_count++
  }
  END { exit(count == 0 && mux_count == 0 ? 0 : 1) }
' "$fake_setup_fast_bin/ssh-ok.log"
awk '
  /-G fieldwork-vps/ { next }
  first == "" { first = $0 }
  END { exit(first ~ /\.local\/bin\/fieldwork-setup-probe/ ? 0 : 1) }
' "$fake_setup_fast_bin/ssh-ok.log"
awk '
  /bash -s/ { seen_probe = 1; next }
  /\.local\/bin\/fieldwork-setup-probe/ { seen_probe = 1; next }
  seen_probe && /fieldwork-vps true/ { extra_reachability++ }
  END { exit(extra_reachability == 0 ? 0 : 1) }
' "$fake_setup_fast_bin/ssh-ok.log"
awk '
  /\.local\/bin\/fieldwork-setup-probe/ {
    helper_seen = 1
    if ($0 ~ /ControlMaster=auto/ && $0 ~ /ControlPersist=600/ && $0 ~ /ControlPath=/) client_mux_seen = 1
  }
  END { exit(helper_seen == 1 && client_mux_seen == 1 ? 0 : 1) }
' "$fake_setup_fast_bin/ssh-ok.log"
if grep -q "bash -s" "$fake_setup_fast_bin/ssh-ok.log"; then
  echo "setup fast path should use the installed setup probe helper" >&2
  exit 1
fi
if grep -Eq "id -un|test -x ~/.local/bin/fieldwork|gh auth status|test -f ~/.config/systemd/user/fieldwork-agent@.service" "$fake_setup_fast_bin/ssh-ok.log"; then
  echo "setup fast path fell back to one-off checks despite a valid snapshot" >&2
  exit 1
fi
awk 'found { print } /^\[5\/5\] Verify setup$/ { found = 1; print }' ${TMPDIR:-/tmp}/fieldwork-setup-fast-ok.out >${TMPDIR:-/tmp}/fieldwork-setup-fast-stage5.actual
cat > ${TMPDIR:-/tmp}/fieldwork-setup-fast-stage5.expected <<'EOF'
[5/5] Verify setup

Setup map:
  [ready] Server: fieldwork-vps
  [ready] SSH: working
  [ready] Agents: claude
  [ready] GitHub auth: ready
  [ready] Broker: running
  [ready] Broker token: stored
  [ready] Verify runner: ready
  [ready] PR prepare runner: ready

Setup complete.

Next:
  fieldwork onboard <owner>/<repo>

Then test:
  fieldwork smoke <owner>/<repo>

Optional:
  Notifications          fieldwork setup-notify
  Telegram approval bot  fieldwork setup-notify --telegram-bot
  Add/change agents      fieldwork setup --agent claude|codex|both

Useful if something feels off: fieldwork doctor --remote --explain
EOF
diff -u ${TMPDIR:-/tmp}/fieldwork-setup-fast-stage5.expected ${TMPDIR:-/tmp}/fieldwork-setup-fast-stage5.actual
grep -q "Add/change agents .*fieldwork setup --agent claude|codex|both" ${TMPDIR:-/tmp}/fieldwork-setup-fast-ok.out
grep -q "FIELDWORK_SETUP_CODEX_LOGIN_TIMEOUT_SECONDS" "$ROOT/lib/cli/setup.sh"
grep -q "codex login status" "$ROOT/bin/fieldwork"
grep -q "codex_remote_login_snapshot" "$ROOT/lib/cli/setup.sh"
grep -q "Device-code login may keep the SSH prompt open" "$ROOT/lib/cli/setup.sh"
grep -q "Did browser sign-in complete successfully" "$ROOT/lib/cli/setup.sh"
grep -q "mark_codex_login_confirmed || true" "$ROOT/lib/cli/setup.sh"

echo "[checks] setup probe requires real bwrap readiness"
tmp_probe_home="$(mktemp_dir)"
fake_probe_bin="$(mktemp_dir)"
mkdir -p \
  "$tmp_probe_home/.local/bin" \
  "$tmp_probe_home/.fieldwork/scripts" \
  "$tmp_probe_home/.config/systemd/user" \
  "$tmp_probe_home/projects" \
  "$tmp_probe_home/runtime"
for script in fieldwork fieldwork-verify fieldwork-verify-runner; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp_probe_home/.local/bin/$script"
  chmod +x "$tmp_probe_home/.local/bin/$script"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp_probe_home/.fieldwork/scripts/fieldwork-verify-pipeline"
chmod +x "$tmp_probe_home/.fieldwork/scripts/fieldwork-verify-pipeline"
: > "$tmp_probe_home/.config/systemd/user/fieldwork-agent@.service"
: > "$tmp_probe_home/.config/systemd/user/fieldwork-verify-runner.socket"
: > "$tmp_probe_home/.config/systemd/user/fieldwork-verify-runner@.service"
: > "$tmp_probe_home/.config/systemd/user/fieldwork-pr-prepare-runner.socket"
cat > "$fake_probe_bin/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fake_probe_bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "auth status") exit 0 ;;
  *) exit 0 ;;
esac
SH
cat > "$fake_probe_bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "--user is-active --quiet fieldwork-verify-runner.socket") exit 0 ;;
  *) exit 1 ;;
esac
SH
cat > "$fake_probe_bin/bwrap" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$fake_probe_bin/systemd-run" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fake_probe_bin/claude" "$fake_probe_bin/gh" "$fake_probe_bin/systemctl" "$fake_probe_bin/bwrap" "$fake_probe_bin/systemd-run"
HOME="$tmp_probe_home" \
  XDG_RUNTIME_DIR="$tmp_probe_home/runtime" \
  FIELDWORK_PROJECTS_DIR="$tmp_probe_home/projects" \
  PATH="$fake_probe_bin:$tmp_probe_home/.local/bin:$PATH" \
  "$ROOT/lib/scripts/fieldwork-setup-probe" >${TMPDIR:-/tmp}/fieldwork-setup-probe-bwrap-fail.out
grep -q "^verify_runner=missing$" ${TMPDIR:-/tmp}/fieldwork-setup-probe-bwrap-fail.out
if grep -q "^verify_runner=ok$" ${TMPDIR:-/tmp}/fieldwork-setup-probe-bwrap-fail.out; then
  echo "setup probe must not mark verify_runner ok from socket existence or systemd-run alone" >&2
  exit 1
fi
if grep -q "status_for verify_runner test -f" "$ROOT/lib/scripts/fieldwork-setup-probe" "$ROOT/bin/fieldwork"; then
  echo "setup probe regressed to file-only verify_runner readiness" >&2
  exit 1
fi
for probe_source in "$ROOT/lib/scripts/fieldwork-setup-probe" "$ROOT/bin/fieldwork"; do
  if ! awk '/verify_runner_ready\(\)/,/^}/' "$probe_source" | grep -q "bwrap --unshare-user"; then
    echo "verify_runner_ready must require a real bwrap namespace probe in $probe_source" >&2
    exit 1
  fi
  if awk '/verify_runner_ready\(\)/,/^}/' "$probe_source" | grep -q "systemd-run"; then
    echo "verify_runner_ready must not accept systemd-run as equivalent in $probe_source" >&2
    exit 1
  fi
done

echo "[checks] verify dependency readiness messages"
tmp_verify_deps_root="$(mktemp_dir)"
tmp_verify_projects="$tmp_verify_deps_root/projects"
mkdir -p "$tmp_verify_projects"
tmp_verify_projects="$(cd "$tmp_verify_projects" && pwd -P)"
fake_verify_deps_bin="$(mktemp_dir)"
ln -s "$(command -v dirname)" "$fake_verify_deps_bin/dirname"
cat > "$fake_verify_deps_bin/bwrap" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$fake_verify_deps_bin/bwrap"
make_verify_repo() {
  local name="$1"
  local repo="$tmp_verify_projects/$name"
  mkdir -p "$repo/.git"
  printf '%s\n' "$repo"
}
run_verify_expect_30() {
  local repo="$1"
  local out="$2"
  local err="$3"
  local label="$4"
  local rc
  set +e
  FIELDWORK_PROJECTS_ROOT="$tmp_verify_projects" PATH="$fake_verify_deps_bin" /bin/bash "$ROOT/lib/scripts/fieldwork-verify-pipeline" "$repo" >"$out" 2>"$err"
  rc=$?
  set -e
  if [ "$rc" != "30" ]; then
    echo "verify dependency check for $label returned $rc, expected 30" >&2
    exit 1
  fi
}

node_missing_repo="$(make_verify_repo node-missing)"
printf '{"scripts":{"lint":"true"}}\n' > "$node_missing_repo/package.json"
run_verify_expect_30 "$node_missing_repo" "${TMPDIR:-/tmp}/fieldwork-verify-node-missing.out" "${TMPDIR:-/tmp}/fieldwork-verify-node-missing.err" "node toolchain"
grep -q "deps-missing for stack=node" ${TMPDIR:-/tmp}/fieldwork-verify-node-missing.err
grep -q "system-wide Node.js 22 + npm" ${TMPDIR:-/tmp}/fieldwork-verify-node-missing.err
grep -q "bootstrap-vps" ${TMPDIR:-/tmp}/fieldwork-verify-node-missing.err

cat > "$fake_verify_deps_bin/node" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$fake_verify_deps_bin/npm" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$fake_verify_deps_bin/node" "$fake_verify_deps_bin/npm"
node_modules_repo="$(make_verify_repo node-modules-missing)"
printf '{}\n' > "$node_modules_repo/package.json"
printf '{}\n' > "$node_modules_repo/package-lock.json"
run_verify_expect_30 "$node_modules_repo" "${TMPDIR:-/tmp}/fieldwork-verify-node-modules.out" "${TMPDIR:-/tmp}/fieldwork-verify-node-modules.err" "node_modules"
grep -q "node_modules missing for package manager npm" ${TMPDIR:-/tmp}/fieldwork-verify-node-modules.err
grep -q "npm ci" ${TMPDIR:-/tmp}/fieldwork-verify-node-modules.err

cat > "$fake_verify_deps_bin/pnpm" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$fake_verify_deps_bin/pnpm"
pnpm_repo="$(make_verify_repo pnpm-missing)"
printf '{}\n' > "$pnpm_repo/package.json"
printf 'lockfileVersion: 9\n' > "$pnpm_repo/pnpm-lock.yaml"
run_verify_expect_30 "$pnpm_repo" "${TMPDIR:-/tmp}/fieldwork-verify-pnpm.out" "${TMPDIR:-/tmp}/fieldwork-verify-pnpm.err" "pnpm node_modules"
grep -q "node_modules missing for package manager pnpm" ${TMPDIR:-/tmp}/fieldwork-verify-pnpm.err
grep -q "pnpm install --frozen-lockfile" ${TMPDIR:-/tmp}/fieldwork-verify-pnpm.err

go_missing_repo="$(make_verify_repo go-missing)"
printf 'module example.com/fieldwork-test\n' > "$go_missing_repo/go.mod"
run_verify_expect_30 "$go_missing_repo" "${TMPDIR:-/tmp}/fieldwork-verify-go.out" "${TMPDIR:-/tmp}/fieldwork-verify-go.err" "go toolchain"
grep -q "go toolchain not installed" ${TMPDIR:-/tmp}/fieldwork-verify-go.err

rust_missing_repo="$(make_verify_repo rust-missing)"
printf '[package]\nname = "fieldwork-test"\nversion = "0.1.0"\nedition = "2021"\n' > "$rust_missing_repo/Cargo.toml"
run_verify_expect_30 "$rust_missing_repo" "${TMPDIR:-/tmp}/fieldwork-verify-rust.out" "${TMPDIR:-/tmp}/fieldwork-verify-rust.err" "rust toolchain"
grep -q "rust toolchain not installed" ${TMPDIR:-/tmp}/fieldwork-verify-rust.err

tmp_setup_helper_missing_home="$(mktemp_dir)"
HOME="$tmp_setup_helper_missing_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_SETUP_FAST_MODE=helper-missing \
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-helper-missing.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-helper-missing.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-helper-missing.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_helper_missing_home" PATH="$fake_setup_fast_bin:$tmp_setup_helper_missing_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-helper-missing.out
grep -q "\\[info\\] Remote state verified" ${TMPDIR:-/tmp}/fieldwork-setup-helper-missing.out
grep -q "Setup complete" ${TMPDIR:-/tmp}/fieldwork-setup-helper-missing.out
test "$(cat "$fake_setup_fast_bin/probes-helper-missing.count")" = "2"
grep -q "fieldwork-setup-probe" "$fake_setup_fast_bin/ssh-helper-missing.log"
grep -q "bash -s" "$fake_setup_fast_bin/ssh-helper-missing.log"

tmp_sync_direct_home="$(mktemp_dir)"
HOME="$tmp_sync_direct_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-sync-direct.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-sync-direct.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-sync-direct.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_sync_direct_home" PATH="$fake_setup_fast_bin:$tmp_sync_direct_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" sync-vps --yes >${TMPDIR:-/tmp}/fieldwork-sync-direct.out
grep -q "\\[ready\\] checkout synced" ${TMPDIR:-/tmp}/fieldwork-sync-direct.out
grep -q "\\[ready\\] remote Fieldwork assets linked" ${TMPDIR:-/tmp}/fieldwork-sync-direct.out
if grep -q -- "-e ssh" "$fake_setup_fast_bin/rsync-sync-direct.log"; then
  echo "direct sync-vps without a ready mux should not pass rsync -e ssh" >&2
  exit 1
fi
grep -q -- "--exclude .git" "$fake_setup_fast_bin/rsync-sync-direct.log"

tmp_setup_timing_home="$(mktemp_dir)"
HOME="$tmp_setup_timing_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_SETUP_TIMING=1 \
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-timing.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-timing.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-timing.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_timing_home" PATH="$fake_setup_fast_bin:$tmp_setup_timing_home/.local/bin:$PATH" \
  /usr/bin/time -p "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-timing.out 2>${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "Setup complete" ${TMPDIR:-/tmp}/fieldwork-setup-timing.out
grep -q "^real " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] cli init " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] ssh mux active check " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] probe local fingerprint " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] probe temp files " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] probe helper transport " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] probe ssh transport " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] probe snapshot read " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] probe snapshot validation " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] remote fingerprint " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] remote gh auth status " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] remote broker checks " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
grep -q "^\\[fieldwork timing\\] remote script total " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
cat > ${TMPDIR:-/tmp}/fieldwork-setup-timing-labels.expected <<'EOF'
cli init
ssh alias resolution
probe local fingerprint
probe temp files
probe helper transport
probe ssh transport
probe snapshot read
probe snapshot validation
setup snapshot probe total
remote fingerprint
remote gh auth status
remote broker checks
remote script total
vps reachability
ssh mux preflight
ssh mux active check
connect
prepare server
connect github
install pr services
print setup summary
public ssh rule check
verify setup
setup total
EOF
awk '
  FNR == NR { expected[++n] = $0; next }
  BEGIN { want = 1 }
  /^\[fieldwork timing\] / {
    label = $0
    sub(/^\[fieldwork timing\] /, "", label)
    sub(/ [0-9][0-9.]*s$/, "", label)
    if (want <= n && label == expected[want]) {
      want++
    }
  }
  END { exit(want > n ? 0 : 1) }
' ${TMPDIR:-/tmp}/fieldwork-setup-timing-labels.expected ${TMPDIR:-/tmp}/fieldwork-setup-timing.err
if grep -Eq "fake-vps\\.example|94\\.130|ghp_|github_pat_|FIELDWORK_EXPECTED_FINGERPRINT_HASH|FIELDWORK_FINGERPRINT_FILES|raw remote output|token value" ${TMPDIR:-/tmp}/fieldwork-setup-timing.err; then
  echo "setup timing output leaked host details, command text, or secret-looking data" >&2
  exit 1
fi
if grep -Eq "^\\[fieldwork timing\\] probe (script materialization|inline transport) " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err; then
  echo "setup timing happy path should not use inline probe fallback" >&2
  exit 1
fi
if grep -q "^\\[fieldwork timing\\] ssh mux warm noop " ${TMPDIR:-/tmp}/fieldwork-setup-timing.err; then
  echo "setup timing should not run the extra mux noop unless FIELDWORK_SSH_MUX_DIAGNOSTICS=1" >&2
  exit 1
fi

tmp_setup_mux_diag_home="$(mktemp_dir)"
HOME="$tmp_setup_mux_diag_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_SETUP_TIMING=1 \
FIELDWORK_SSH_MUX_DIAGNOSTICS=1 \
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-mux-diagnostics.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-mux-diagnostics.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-mux-diagnostics.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_mux_diag_home" PATH="$fake_setup_fast_bin:$tmp_setup_mux_diag_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-mux-diagnostics.out 2>${TMPDIR:-/tmp}/fieldwork-setup-mux-diagnostics.err
grep -q "Setup complete" ${TMPDIR:-/tmp}/fieldwork-setup-mux-diagnostics.out
grep -q "^\\[fieldwork timing\\] ssh mux active check " ${TMPDIR:-/tmp}/fieldwork-setup-mux-diagnostics.err
grep -q "^\\[fieldwork timing\\] ssh mux warm noop " ${TMPDIR:-/tmp}/fieldwork-setup-mux-diagnostics.err

tmp_setup_mux_off_home="$(mktemp_dir)"
HOME="$tmp_setup_mux_off_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_SSH_MULTIPLEX=0 \
FIELDWORK_SETUP_TIMING=1 \
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-mux-off.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-mux-off.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-mux-off.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_mux_off_home" PATH="$fake_setup_fast_bin:$tmp_setup_mux_off_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-mux-off.out 2>${TMPDIR:-/tmp}/fieldwork-setup-mux-off.err
grep -q "\\[info\\] Remote state verified" ${TMPDIR:-/tmp}/fieldwork-setup-mux-off.out
if grep -q "ControlMaster=" "$fake_setup_fast_bin/ssh-mux-off.log"; then
  echo "FIELDWORK_SSH_MULTIPLEX=0 still passed mux options to ssh" >&2
  exit 1
fi
if grep -Eq "^\\[fieldwork timing\\] ssh mux (active check|warm noop) " ${TMPDIR:-/tmp}/fieldwork-setup-mux-off.err; then
  echo "FIELDWORK_SSH_MULTIPLEX=0 should skip mux-only timing labels" >&2
  exit 1
fi
awk '
  /bash -s/ { seen_probe = 1 }
  /\.local\/bin\/fieldwork-setup-probe/ { seen_probe = 1 }
  !seen_probe && /fieldwork-vps true/ {
    count++
    if ($0 ~ /ControlMaster=auto/) mux_count++
  }
  END { exit(count == 0 && mux_count == 0 ? 0 : 1) }
' "$fake_setup_fast_bin/ssh-mux-off.log"

tmp_setup_mux_fail_home="$(mktemp_dir)"
HOME="$tmp_setup_mux_fail_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_SETUP_FAST_MUX_FAIL=1 \
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-mux-fail.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-mux-fail.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-mux-fail.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_mux_fail_home" PATH="$fake_setup_fast_bin:$tmp_setup_mux_fail_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-mux-fail.out
grep -q "\\[info\\] SSH multiplexing unavailable; using normal SSH" ${TMPDIR:-/tmp}/fieldwork-setup-mux-fail.out
grep -q "\\[info\\] Remote state verified" ${TMPDIR:-/tmp}/fieldwork-setup-mux-fail.out
if grep "bash -s" "$fake_setup_fast_bin/ssh-mux-fail.log" | grep -q "ControlMaster=auto"; then
  echo "setup kept using mux options after mux preflight failed" >&2
  exit 1
fi

tmp_setup_unreachable_home="$(mktemp_dir)"
HOME="$tmp_setup_unreachable_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_SETUP_FAST_MUX_FAIL=1 \
FIELDWORK_FAKE_SETUP_FAST_PLAIN_FAIL=1 \
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-unreachable.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-unreachable.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-unreachable.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_unreachable_home" PATH="$fake_setup_fast_bin:$tmp_setup_unreachable_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-unreachable.out || true
grep -q "VPS is not reachable" ${TMPDIR:-/tmp}/fieldwork-setup-unreachable.out
grep -q "start or fix SSH on the VPS" ${TMPDIR:-/tmp}/fieldwork-setup-unreachable.out
if grep -q "bash -s" "$fake_setup_fast_bin/ssh-unreachable.log"; then
  echo "unreachable setup should not run the inline snapshot fallback" >&2
  exit 1
fi
grep -q "fieldwork-setup-probe" "$fake_setup_fast_bin/ssh-unreachable.log"

tmp_setup_dirty_home="$(mktemp_dir)"
HOME="$tmp_setup_dirty_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_SETUP_FAST_MODE=dirty-sync \
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-dirty.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-dirty.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-dirty.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_dirty_home" PATH="$fake_setup_fast_bin:$tmp_setup_dirty_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup >${TMPDIR:-/tmp}/fieldwork-setup-dirty.out <<'EOF'
y
EOF
test "$(cat "$fake_setup_fast_bin/probes-dirty.count")" = "2"
grep -q "remote Fieldwork checkout differs from this copy" ${TMPDIR:-/tmp}/fieldwork-setup-dirty.out
grep -q "remote Fieldwork checkout matches this copy" ${TMPDIR:-/tmp}/fieldwork-setup-dirty.out
grep -q "\\[ready\\] checkout synced" ${TMPDIR:-/tmp}/fieldwork-setup-dirty.out
grep -q -- "-e ssh -o ControlMaster=auto" "$fake_setup_fast_bin/rsync-dirty.log"

tmp_setup_gh_timeout_home="$(mktemp_dir)"
HOME="$tmp_setup_gh_timeout_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_SETUP_FAST_MODE=gh-timeout \
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-gh-timeout.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-gh-timeout.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-gh-timeout.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_gh_timeout_home" PATH="$fake_setup_fast_bin:$tmp_setup_gh_timeout_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-gh-timeout.out
grep -q "GitHub auth live check timed out; using saved gh config for setup" ${TMPDIR:-/tmp}/fieldwork-setup-gh-timeout.out
grep -q "Setup complete" ${TMPDIR:-/tmp}/fieldwork-setup-gh-timeout.out
if grep -q "gh auth status" "$fake_setup_fast_bin/ssh-gh-timeout.log"; then
  echo "gh auth timeout snapshot should not fall back to an unbounded live gh check" >&2
  exit 1
fi

tmp_setup_partial_home="$(mktemp_dir)"
HOME="$tmp_setup_partial_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_SETUP_FAST_MODE=partial \
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-partial.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-partial.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-partial.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_partial_home" PATH="$fake_setup_fast_bin:$tmp_setup_partial_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-partial.out
grep -q "Setup complete" ${TMPDIR:-/tmp}/fieldwork-setup-partial.out
if grep -q "\\[info\\] Remote state verified" ${TMPDIR:-/tmp}/fieldwork-setup-partial.out; then
  echo "partial setup snapshot should not be trusted" >&2
  exit 1
fi
grep -q "\\[info\\] Remote snapshot unavailable; using fallback checks" ${TMPDIR:-/tmp}/fieldwork-setup-partial.out
grep -q "id -un" "$fake_setup_fast_bin/ssh-partial.log"
grep -q "gh auth status" "$fake_setup_fast_bin/ssh-partial.log"

tmp_setup_garbage_home="$(mktemp_dir)"
HOME="$tmp_setup_garbage_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_SETUP_FAST_MODE=garbage \
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-garbage.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-garbage.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-garbage.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_garbage_home" PATH="$fake_setup_fast_bin:$tmp_setup_garbage_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-garbage.out
grep -q "Setup complete" ${TMPDIR:-/tmp}/fieldwork-setup-garbage.out
if grep -q "\\[info\\] Remote state verified" ${TMPDIR:-/tmp}/fieldwork-setup-garbage.out; then
  echo "garbage setup snapshot should not be trusted" >&2
  exit 1
fi
grep -q "\\[info\\] Remote snapshot unavailable; using fallback checks" ${TMPDIR:-/tmp}/fieldwork-setup-garbage.out
grep -q "id -un" "$fake_setup_fast_bin/ssh-garbage.log"

for fallback_case in "nonzero nonzero" "nonzero-partial partial"; do
  set -- $fallback_case
  fallback_mode="$1"
  fallback_reason="$2"
  tmp_setup_fallback_home="$(mktemp_dir)"
  HOME="$tmp_setup_fallback_home" "$ROOT/install.sh" >/dev/null
  FIELDWORK_SETUP_TIMING=1 \
  FIELDWORK_FAKE_SETUP_FAST_MODE="$fallback_mode" \
  FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-$fallback_mode.log" \
  FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-$fallback_mode.log" \
  FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-$fallback_mode.count" \
  FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
  HOME="$tmp_setup_fallback_home" PATH="$fake_setup_fast_bin:$tmp_setup_fallback_home/.local/bin:$PATH" \
    "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >"${TMPDIR:-/tmp}/fieldwork-setup-$fallback_mode.out" 2>"${TMPDIR:-/tmp}/fieldwork-setup-$fallback_mode.err"
  grep -q "Setup complete" "${TMPDIR:-/tmp}/fieldwork-setup-$fallback_mode.out"
  if grep -q "\\[info\\] Remote state verified" "${TMPDIR:-/tmp}/fieldwork-setup-$fallback_mode.out"; then
    echo "$fallback_mode setup snapshot should not be trusted" >&2
    exit 1
  fi
  grep -q "\\[info\\] Remote snapshot unavailable; using fallback checks" "${TMPDIR:-/tmp}/fieldwork-setup-$fallback_mode.out"
  grep -q "^\\[fieldwork timing\\] setup snapshot fallback $fallback_reason 0.000s" "${TMPDIR:-/tmp}/fieldwork-setup-$fallback_mode.err"
  if grep -Ev "^\\[fieldwork timing\\] setup snapshot fallback (helper-missing|malformed|partial|nonzero|timeout|transport) 0\\.000s$" "${TMPDIR:-/tmp}/fieldwork-setup-$fallback_mode.err" | grep -q "^\\[fieldwork timing\\] setup snapshot fallback "; then
    echo "$fallback_mode emitted an unknown setup snapshot fallback reason" >&2
    exit 1
  fi
done

tmp_setup_probe_timeout_home="$(mktemp_dir)"
HOME="$tmp_setup_probe_timeout_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_SETUP_PROBE_TIMEOUT_SECONDS=1 \
FIELDWORK_FAKE_SETUP_FAST_MODE=timeout \
FIELDWORK_FAKE_SETUP_FAST_SSH_LOG="$fake_setup_fast_bin/ssh-probe-timeout.log" \
FIELDWORK_FAKE_SETUP_FAST_RSYNC_LOG="$fake_setup_fast_bin/rsync-probe-timeout.log" \
FIELDWORK_FAKE_SETUP_FAST_PROBE_COUNT="$fake_setup_fast_bin/probes-timeout.count" \
FIELDWORK_FAKE_SETUP_FAST_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_setup_probe_timeout_home" PATH="$fake_setup_fast_bin:$tmp_setup_probe_timeout_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-probe-timeout.out
grep -q "Setup complete" ${TMPDIR:-/tmp}/fieldwork-setup-probe-timeout.out
if grep -q "\\[info\\] Remote state verified" ${TMPDIR:-/tmp}/fieldwork-setup-probe-timeout.out; then
  echo "timed-out setup snapshot should not be trusted" >&2
  exit 1
fi
grep -q "\\[info\\] Remote snapshot unavailable; using fallback checks" ${TMPDIR:-/tmp}/fieldwork-setup-probe-timeout.out
grep -q "id -un" "$fake_setup_fast_bin/ssh-probe-timeout.log"
test "$(cat "$fake_setup_fast_bin/probes-timeout.count")" = "1"
grep -q "fieldwork-vps true" "$fake_setup_fast_bin/ssh-probe-timeout.log"

echo "[checks] setup gives concrete timeout guidance"
fake_timeout_bin="$(mktemp_dir)"
cat > "$fake_timeout_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  echo "hostname 203.0.113.10"
  echo "user fieldwork"
  exit 0
fi
echo "ssh: connect to host 203.0.113.10 port 22: Operation timed out" >&2
exit 255
SH
chmod +x "$fake_timeout_bin/ssh"
tmp_timeout_home="$(mktemp_dir)"
HOME="$tmp_timeout_home" "$ROOT/install.sh" >/dev/null
HOME="$tmp_timeout_home" PATH="$fake_timeout_bin:$tmp_timeout_home/.local/bin:$PATH" "$ROOT/bin/fieldwork" setup --skip-sync </dev/null >${TMPDIR:-/tmp}/fieldwork-setup-timeout.out || true
grep -q "Operation timed out" ${TMPDIR:-/tmp}/fieldwork-setup-timeout.out
grep -q "VPS public IP is not accepting SSH on port 22" ${TMPDIR:-/tmp}/fieldwork-setup-timeout.out
grep -q "provider firewall/security-group rules allow inbound TCP 22" ${TMPDIR:-/tmp}/fieldwork-setup-timeout.out
grep -q "make port 22 reachable on the VPS public IP" ${TMPDIR:-/tmp}/fieldwork-setup-timeout.out
grep -q "verify ssh fieldwork-vps and rerun fieldwork setup" ${TMPDIR:-/tmp}/fieldwork-setup-timeout.out

echo "[checks] setup guides missing SSH alias interactively"
fake_missing_ssh_bin="$(mktemp_dir)"
cat > "$fake_missing_ssh_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  config="$HOME/.ssh/config"
  if [ -f "$config" ] && grep -Eq '^[[:space:]]*Host[[:space:]]+fieldwork-vps([[:space:]]|$)' "$config"; then
    awk '
      /^[[:space:]]*Host[[:space:]]+fieldwork-vps([[:space:]]|$)/ { in_block=1; next }
      /^[[:space:]]*Host[[:space:]]+/ { in_block=0 }
      in_block && $1 == "HostName" { host=$2 }
      in_block && $1 == "User" { user=$2 }
      END {
        print "hostname " (host ? host : "fieldwork-vps")
        print "user " (user ? user : "local-user")
      }
    ' "$config"
  else
    echo "hostname ${2:-fieldwork-vps}"
    echo "user local-user"
  fi
  exit 0
fi
emit_ready_snapshot() {
  cat <<'EOF'
remote_user=fieldwork
fieldwork_cli=ok
fieldwork_checkout=ok
path_configured=ok
bootstrap_ready=ok
claude_login=ok
gh_cli=ok
gh_hosts=ok
gh_live=ok
verify_runner=ok
prepare_runner=ok
claude_service=ok
broker_socket=ok
broker_pat_tool=ok
broker_thin_client=ok
broker_pat_marker=ok
broker_pat_sudo=ok
temporary_sudo=missing
public_ssh_rule=missing
projects_dir=ok
EOF
}
case "$*" in
  *"fieldwork-setup-probe"*) emit_ready_snapshot; exit 0 ;;
  *"bash -s"*) emit_ready_snapshot; exit 0 ;;
  *"fieldwork-vps true"*) exit 0 ;;
  *"fieldwork-vps id -un"*) echo "fieldwork"; exit 0 ;;
esac
exit 255
SH
chmod +x "$fake_missing_ssh_bin/ssh"
tmp_wizard_home="$(mktemp_dir)"
HOME="$tmp_wizard_home" "$ROOT/install.sh" >/dev/null
printf '203.0.113.10\ny\ny\n' | HOME="$tmp_wizard_home" PATH="$fake_missing_ssh_bin:$tmp_wizard_home/.local/bin:$PATH" "$ROOT/bin/fieldwork" setup --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out || true
grep -q "No SSH alias named fieldwork-vps found" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out
grep -q "Let's set that up now" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out
grep -q "VPS hostname or IP:" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out
grep -q "Does this VPS already have the 'fieldwork' Linux user that you can SSH into" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out
grep -q "We can add this SSH alias for you" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out
grep -q "HostName 203.0.113.10" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out
grep -q "Append this managed block to ~/.ssh/config" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out
grep -q "Added SSH alias: fieldwork-vps" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out
grep -q "Tested: ssh fieldwork-vps true" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out
grep -q "SSH alias 'fieldwork-vps' resolves" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out
grep -q "remote user is fieldwork" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out
grep -q "# BEGIN FIELDWORK SSH CONFIG: fieldwork-vps" "$tmp_wizard_home/.ssh/config"
grep -q "# END FIELDWORK SSH CONFIG: fieldwork-vps" "$tmp_wizard_home/.ssh/config"
grep -q "Host fieldwork-vps" "$tmp_wizard_home/.ssh/config"
grep -q "HostName 203.0.113.10" "$tmp_wizard_home/.ssh/config"
grep -q "User fieldwork" "$tmp_wizard_home/.ssh/config"
grep -q "IdentityFile ~/.ssh/id_ed25519" "$tmp_wizard_home/.ssh/config"
if grep -q "VPS is not reachable" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-wizard.out; then
  echo "missing-alias setup also reported unreachable VPS" >&2
  exit 1
fi

echo "[checks] setup diagnoses existing SSH alias mismatch without editing"
fake_mismatch_ssh_bin="$(mktemp_dir)"
cat > "$fake_mismatch_ssh_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  echo "hostname old.example.com"
  echo "user ubuntu"
  exit 0
fi
exit 255
SH
chmod +x "$fake_mismatch_ssh_bin/ssh"
tmp_mismatch_home="$(mktemp_dir)"
mkdir -p "$tmp_mismatch_home/.ssh"
cat > "$tmp_mismatch_home/.ssh/config" <<'EOF'
Host fieldwork-vps
  HostName old.example.com
  User ubuntu
EOF
chmod 600 "$tmp_mismatch_home/.ssh/config"
HOME="$tmp_mismatch_home" "$ROOT/install.sh" >/dev/null
printf '203.0.113.10\n' | HOME="$tmp_mismatch_home" PATH="$fake_mismatch_ssh_bin:$tmp_mismatch_home/.local/bin:$PATH" "$ROOT/bin/fieldwork" setup --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-alias-mismatch.out || true
grep -q "Host fieldwork-vps already exists, but it does not appear to match this VPS" ${TMPDIR:-/tmp}/fieldwork-setup-alias-mismatch.out
grep -q "Current:" ${TMPDIR:-/tmp}/fieldwork-setup-alias-mismatch.out
grep -q "HostName old.example.com" ${TMPDIR:-/tmp}/fieldwork-setup-alias-mismatch.out
grep -q "User ubuntu" ${TMPDIR:-/tmp}/fieldwork-setup-alias-mismatch.out
grep -q "Expected:" ${TMPDIR:-/tmp}/fieldwork-setup-alias-mismatch.out
grep -q "HostName 203.0.113.10" ${TMPDIR:-/tmp}/fieldwork-setup-alias-mismatch.out
grep -q "User fieldwork" ${TMPDIR:-/tmp}/fieldwork-setup-alias-mismatch.out
grep -q "Fieldwork will not overwrite your SSH config automatically" ${TMPDIR:-/tmp}/fieldwork-setup-alias-mismatch.out
if grep -q "FIELDWORK SSH CONFIG" "$tmp_mismatch_home/.ssh/config"; then
  echo "setup modified an existing user-authored SSH alias" >&2
  exit 1
fi

echo "[checks] setup refreshes a stale Fieldwork-managed SSH alias in place"
tmp_managed_home="$(mktemp_dir)"
mkdir -p "$tmp_managed_home/.ssh"
cat > "$tmp_managed_home/.ssh/config" <<'EOF'
# BEGIN FIELDWORK SSH CONFIG: fieldwork-vps
Host fieldwork-vps
  HostName old.example.com
  User fieldwork
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
# END FIELDWORK SSH CONFIG: fieldwork-vps
EOF
chmod 600 "$tmp_managed_home/.ssh/config"
HOME="$tmp_managed_home" "$ROOT/install.sh" >/dev/null
printf '203.0.113.11\n' | HOME="$tmp_managed_home" PATH="$fake_mismatch_ssh_bin:$tmp_managed_home/.local/bin:$PATH" "$ROOT/bin/fieldwork" setup --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-alias-managed.out 2>&1 || true
grep -q "Refreshed managed SSH alias" ${TMPDIR:-/tmp}/fieldwork-setup-alias-managed.out
grep -q "HostName 203.0.113.11" "$tmp_managed_home/.ssh/config"
test "$(grep -c '203.0.113.11' "$tmp_managed_home/.ssh/config")" = "1"
test "$(grep -c '^# BEGIN FIELDWORK SSH CONFIG: fieldwork-vps$' "$tmp_managed_home/.ssh/config")" = "1"
ls "$tmp_managed_home/.ssh/"config.fieldwork.*.bak >/dev/null 2>&1

echo "[checks] setup guides users without a VPS"
tmp_no_vps_home="$(mktemp_dir)"
HOME="$tmp_no_vps_home" "$ROOT/install.sh" >/dev/null
printf '\n' | HOME="$tmp_no_vps_home" PATH="$fake_missing_ssh_bin:$tmp_no_vps_home/.local/bin:$PATH" "$ROOT/bin/fieldwork" setup --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-no-vps.out || true
grep -q "create a small Ubuntu 24.04 VPS" ${TMPDIR:-/tmp}/fieldwork-setup-no-vps.out
grep -q "confirm you can run: ssh root@<vps-public-ip> or ssh <sudo-user>@<vps-public-ip>" ${TMPDIR:-/tmp}/fieldwork-setup-no-vps.out
grep -q "setup will connect the VPS" ${TMPDIR:-/tmp}/fieldwork-setup-no-vps.out
grep -q "Reference only: file://" ${TMPDIR:-/tmp}/fieldwork-setup-no-vps.out
grep -q "verify root SSH or sudo-user SSH works, then rerun fieldwork setup" ${TMPDIR:-/tmp}/fieldwork-setup-no-vps.out
grep -q "first-time-infrastructure.md" ${TMPDIR:-/tmp}/fieldwork-setup-no-vps.out

echo "[checks] setup can assist agent user bootstrap"
fake_assist_ssh_bin="$(mktemp_dir)"
cat > "$fake_assist_ssh_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  config="$HOME/.ssh/config"
  if [ -f "$config" ] && grep -Eq '^[[:space:]]*Host[[:space:]]+fieldwork-vps([[:space:]]|$)' "$config"; then
    awk '
      /^[[:space:]]*Host[[:space:]]+fieldwork-vps([[:space:]]|$)/ { in_block=1; next }
      /^[[:space:]]*Host[[:space:]]+/ { in_block=0 }
      in_block && $1 == "HostName" { host=$2 }
      in_block && $1 == "User" { user=$2 }
      END {
        print "hostname " (host ? host : "fieldwork-vps")
        print "user " (user ? user : "local-user")
      }
    ' "$config"
  else
    echo "hostname ${2:-fieldwork-vps}"
    echo "user local-user"
  fi
  exit 0
fi
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_ASSIST_SSH_LOG"
case "$*" in
  *"root@203.0.113.10 bash -s"*)
    cat > "$FIELDWORK_FAKE_ROOT_SCRIPT"
    exit 0
    ;;
  *"fieldwork@203.0.113.10 id -un"*)
    echo "fieldwork"
    exit 0
    ;;
  *"fieldwork@203.0.113.10 sudo -n true"*)
    exit 0
    ;;
  *"fieldwork-vps true"*) exit 0 ;;
  *"fieldwork-vps id -un"*) echo "fieldwork"; exit 0 ;;
  *)
    echo "unexpected fake assist ssh command: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$fake_assist_ssh_bin/ssh"
tmp_assist_home="$(mktemp_dir)"
mkdir -p "$tmp_assist_home/.ssh"
printf 'fake private key\n' > "$tmp_assist_home/.ssh/id_ed25519"
printf 'ssh-ed25519 AAAAFIELDWORKTEST fieldwork\n' > "$tmp_assist_home/.ssh/id_ed25519.pub"
chmod 600 "$tmp_assist_home/.ssh/id_ed25519"
HOME="$tmp_assist_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_ASSIST_SSH_LOG="$fake_assist_ssh_bin/ssh.log" FIELDWORK_FAKE_ROOT_SCRIPT="$fake_assist_ssh_bin/root-script.sh" \
  HOME="$tmp_assist_home" PATH="$fake_assist_ssh_bin:$tmp_assist_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out <<'EOF' || true
203.0.113.10
n

y
EOF
grep -q "No problem. Fieldwork can create/update the 'fieldwork' user using root SSH or another sudo-capable VPS account" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "connect to an existing VPS admin login at 203.0.113.10" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "add the fieldwork-vps SSH alias" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
if grep -q "Continue? \\[Y/n\\]" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out; then
  echo "user setup should use one final confirmation, not a duplicate Continue prompt" >&2
  exit 1
fi
grep -q "Existing VPS admin login that can create/update 'fieldwork' \\[root\\]:" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "^VPS user setup confirmation$" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "Target: root@203.0.113.10" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "Privilege path: root SSH" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "verified SSH as 'fieldwork'" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "verified passwordless sudo for setup" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "Created/updated fieldwork user" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "Installed SSH key" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "Added SSH alias: fieldwork-vps" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "Tested: ssh fieldwork-vps true" ${TMPDIR:-/tmp}/fieldwork-setup-assisted-user.out
grep -q "root@203.0.113.10 bash -s" "$fake_assist_ssh_bin/ssh.log"
grep -q "fieldwork@203.0.113.10 id -un" "$fake_assist_ssh_bin/ssh.log"
grep -q "fieldwork@203.0.113.10 sudo -n true" "$fake_assist_ssh_bin/ssh.log"
grep -q "fieldwork-vps true" "$fake_assist_ssh_bin/ssh.log"
grep -q "fieldwork-vps id -un" "$fake_assist_ssh_bin/ssh.log"
grep -q "# BEGIN FIELDWORK SSH CONFIG: fieldwork-vps" "$tmp_assist_home/.ssh/config"
grep -q "# END FIELDWORK SSH CONFIG: fieldwork-vps" "$tmp_assist_home/.ssh/config"
grep -q "HostName 203.0.113.10" "$tmp_assist_home/.ssh/config"
grep -q "IdentityFile ~/.ssh/id_ed25519" "$tmp_assist_home/.ssh/config"
test -f "$tmp_assist_home/.config/fieldwork/authorized-key.env"
grep -q "host=203.0.113.10" "$tmp_assist_home/.config/fieldwork/authorized-key.env"
grep -q "remote_user=fieldwork" "$tmp_assist_home/.config/fieldwork/authorized-key.env"
grep -q "public_key=ssh-ed25519 AAAAFIELDWORKTEST fieldwork" "$tmp_assist_home/.config/fieldwork/authorized-key.env"
grep -q "adduser --disabled-password --gecos" "$fake_assist_ssh_bin/root-script.sh"
grep -q "usermod -aG sudo" "$fake_assist_ssh_bin/root-script.sh"
grep -q "NOPASSWD:ALL" "$fake_assist_ssh_bin/root-script.sh"
grep -q "visudo -cf" "$fake_assist_ssh_bin/root-script.sh"
grep -q "AAAAFIELDWORKTEST" "$fake_assist_ssh_bin/root-script.sh"
if grep -Eq '\$USER|\$HOME|~/' "$fake_assist_ssh_bin/root-script.sh"; then
  echo "admin setup script should not depend on invoking user identity" >&2
  exit 1
fi

echo "[checks] setup can assist agent user bootstrap through a sudo admin"
fake_sudo_assist_bin="$(mktemp_dir)"
cat > "$fake_sudo_assist_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  config="$HOME/.ssh/config"
  if [ -f "$config" ] && grep -Eq '^[[:space:]]*Host[[:space:]]+fieldwork-vps([[:space:]]|$)' "$config"; then
    awk '
      /^[[:space:]]*Host[[:space:]]+fieldwork-vps([[:space:]]|$)/ { in_block=1; next }
      /^[[:space:]]*Host[[:space:]]+/ { in_block=0 }
      in_block && $1 == "HostName" { host=$2 }
      in_block && $1 == "User" { user=$2 }
      END {
        print "hostname " (host ? host : "fieldwork-vps")
        print "user " (user ? user : "local-user")
      }
    ' "$config"
  else
    echo "hostname ${2:-fieldwork-vps}"
    echo "user local-user"
  fi
  exit 0
fi
args="$*"
printf '%s\n' "$args" >> "$FIELDWORK_FAKE_SUDO_ASSIST_SSH_LOG"
case "$args" in
  *"prateek@203.0.113.30 umask 077 && mktemp -d /tmp/fieldwork-user-setup."*)
    printf '/tmp/fieldwork-user-setup.ABC123\n'
    exit 0
    ;;
  *"prateek@203.0.113.30 chmod 600 "*"/tmp/fieldwork-user-setup.ABC123/setup.sh"*)
    printf 'chmod\n' >> "$FIELDWORK_FAKE_SUDO_ASSIST_ORDER"
    exit 0
    ;;
  *"prateek@203.0.113.30 sudo -S -p '' bash "*"/tmp/fieldwork-user-setup.ABC123/setup.sh"*)
    printf 'sudo\n' >> "$FIELDWORK_FAKE_SUDO_ASSIST_ORDER"
    touch "$FIELDWORK_FAKE_SUDO_ASSIST_STATE"
    exit 0
    ;;
  *"prateek@203.0.113.30 rm -rf -- "*"/tmp/fieldwork-user-setup.ABC123"*)
    printf 'cleanup\n' >> "$FIELDWORK_FAKE_SUDO_ASSIST_ORDER"
    exit 0
    ;;
  *"fieldwork@203.0.113.30 id -un"*)
    test -f "$FIELDWORK_FAKE_SUDO_ASSIST_STATE" || exit 1
    printf 'verify-user\n' >> "$FIELDWORK_FAKE_SUDO_ASSIST_ORDER"
    exit 0
    ;;
  *"fieldwork@203.0.113.30 sudo -n true"*)
    test -f "$FIELDWORK_FAKE_SUDO_ASSIST_STATE" || exit 1
    printf 'verify-sudo\n' >> "$FIELDWORK_FAKE_SUDO_ASSIST_ORDER"
    exit 0
    ;;
  *"fieldwork-vps true"*) exit 0 ;;
  *"fieldwork-vps id -un"*) echo "fieldwork"; exit 0 ;;
  *)
    echo "unexpected fake sudo assist ssh command: $args" >&2
    exit 1
    ;;
esac
SH
cat > "$fake_sudo_assist_bin/scp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_SUDO_ASSIST_SCP_LOG"
for arg in "$@"; do
  if [ -f "$arg" ]; then
    cp "$arg" "$FIELDWORK_FAKE_SUDO_ASSIST_SCRIPT"
  fi
done
case "$*" in
  *"prateek@203.0.113.30:/tmp/fieldwork-user-setup.ABC123/setup.sh"*)
    printf 'scp\n' >> "$FIELDWORK_FAKE_SUDO_ASSIST_ORDER"
    exit 0
    ;;
  *)
    echo "unexpected fake sudo assist scp command: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$fake_sudo_assist_bin/ssh" "$fake_sudo_assist_bin/scp"
tmp_sudo_assist_home="$(mktemp_dir)"
mkdir -p "$tmp_sudo_assist_home/.ssh"
printf 'fake private key\n' > "$tmp_sudo_assist_home/.ssh/id_ed25519"
printf 'ssh-ed25519 AAAAFIELDWORKSUDO fieldwork\n' > "$tmp_sudo_assist_home/.ssh/id_ed25519.pub"
chmod 600 "$tmp_sudo_assist_home/.ssh/id_ed25519"
HOME="$tmp_sudo_assist_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_SUDO_ASSIST_SSH_LOG="$fake_sudo_assist_bin/ssh.log" \
FIELDWORK_FAKE_SUDO_ASSIST_SCP_LOG="$fake_sudo_assist_bin/scp.log" \
FIELDWORK_FAKE_SUDO_ASSIST_ORDER="$fake_sudo_assist_bin/order.log" \
FIELDWORK_FAKE_SUDO_ASSIST_STATE="$fake_sudo_assist_bin/repaired" \
FIELDWORK_FAKE_SUDO_ASSIST_SCRIPT="$fake_sudo_assist_bin/admin-script.sh" \
  HOME="$tmp_sudo_assist_home" PATH="$fake_sudo_assist_bin:$tmp_sudo_assist_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-sudo-assisted-user.out <<'EOF' || true
203.0.113.30
n
prateek
y
EOF
grep -q "Target: prateek@203.0.113.30" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-assisted-user.out
grep -q "Privilege path: sudo on the VPS as 'prateek'" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-assisted-user.out
grep -q "VPS Linux password for 'prateek'" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-assisted-user.out
grep -q "verified SSH as 'fieldwork'" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-assisted-user.out
grep -q "Created/updated fieldwork user" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-assisted-user.out
grep -q "mktemp -d /tmp/fieldwork-user-setup" "$fake_sudo_assist_bin/ssh.log"
grep -q -- "-o ServerAliveInterval=20" "$fake_sudo_assist_bin/ssh.log"
grep -q "chmod 600 .*tmp/fieldwork-user-setup.ABC123/setup.sh" "$fake_sudo_assist_bin/ssh.log"
grep -q "sudo -S -p '' bash .*tmp/fieldwork-user-setup.ABC123/setup.sh" "$fake_sudo_assist_bin/ssh.log"
grep -q "rm -rf -- .*tmp/fieldwork-user-setup.ABC123" "$fake_sudo_assist_bin/ssh.log"
grep -Fq "read_admin_sudo_password()" "$ROOT/lib/cli/setup.sh"
grep -Fq "fieldwork_status_stop_renderer" "$ROOT/lib/cli/setup.sh"
grep -Fq "sudo -S -p '' bash" "$ROOT/lib/cli/setup.sh"
if grep -Fq "tee -a" "$ROOT/lib/cli/setup.sh"; then
  echo "admin sudo password handoff should not pipe interactive ssh through tee" >&2
  exit 1
fi
grep -q "prateek@203.0.113.30:/tmp/fieldwork-user-setup.ABC123/setup.sh" "$fake_sudo_assist_bin/scp.log"
grep -q "AAAAFIELDWORKSUDO" "$fake_sudo_assist_bin/admin-script.sh"
if grep -Eq '\$USER|\$HOME|~/' "$fake_sudo_assist_bin/admin-script.sh"; then
  echo "sudo admin setup script should not depend on invoking user identity" >&2
  exit 1
fi
printf 'scp\nchmod\nsudo\ncleanup\nverify-user\nverify-sudo\n' > "$fake_sudo_assist_bin/expected-order.log"
cmp "$fake_sudo_assist_bin/expected-order.log" "$fake_sudo_assist_bin/order.log"
awk '
  /verified SSH as '\''fieldwork'\''/ { verified = NR }
  /Created\/updated fieldwork user/ { ready = NR }
  END { exit !(verified && ready && verified < ready) }
' ${TMPDIR:-/tmp}/fieldwork-setup-sudo-assisted-user.out

echo "[checks] setup explains admin bootstrap failures"
fake_admin_fail_bin="$(mktemp_dir)"
cat > "$fake_admin_fail_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  echo "hostname ${2:-fieldwork-vps}"
  echo "user local-user"
  exit 0
fi
args="$*"
printf '%s\n' "$args" >> "$FIELDWORK_FAKE_ADMIN_FAIL_SSH_LOG"
case "${FIELDWORK_FAKE_ADMIN_FAIL_MODE:-}" in
  root-denied)
    case "$args" in
      *"root@203.0.113.40 bash -s"*)
        echo "root@203.0.113.40: Permission denied (publickey)." >&2
        exit 255
        ;;
    esac
    ;;
  sudo-notsudoer|sudo-badpass|sudo-nopassword)
    case "$args" in
      *"prateek@203.0.113.41 umask 077 && mktemp -d /tmp/fieldwork-user-setup."*)
        printf '/tmp/fieldwork-user-setup.FAIL41\n'
        exit 0
        ;;
      *"prateek@203.0.113.41 chmod 600 "*"/tmp/fieldwork-user-setup.FAIL41/setup.sh"*)
        exit 0
        ;;
      *"prateek@203.0.113.41 rm -rf -- "*"/tmp/fieldwork-user-setup.FAIL41"*)
        printf 'cleanup\n' >> "$FIELDWORK_FAKE_ADMIN_FAIL_ORDER"
        exit 0
        ;;
      *"prateek@203.0.113.41 sudo -S -p '' bash "*"/tmp/fieldwork-user-setup.FAIL41/setup.sh"*)
        if [ "${FIELDWORK_FAKE_ADMIN_FAIL_MODE:-}" = sudo-notsudoer ]; then
          echo "prateek is not in the sudoers file." >&2
        elif [ "${FIELDWORK_FAKE_ADMIN_FAIL_MODE:-}" = sudo-nopassword ]; then
          echo "sudo: a password is required" >&2
        else
          echo "Sorry, try again." >&2
          echo "sudo: 3 incorrect password attempts" >&2
        fi
        exit 1
        ;;
    esac
    ;;
esac
echo "unexpected fake admin failure ssh command: $args" >&2
exit 1
SH
cat > "$fake_admin_fail_bin/scp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_ADMIN_FAIL_SCP_LOG"
case "$*" in
  *"prateek@203.0.113.41:/tmp/fieldwork-user-setup.FAIL41/setup.sh"*) exit 0 ;;
  *) echo "unexpected fake admin failure scp command: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$fake_admin_fail_bin/ssh" "$fake_admin_fail_bin/scp"
tmp_admin_fail_home="$(mktemp_dir)"
mkdir -p "$tmp_admin_fail_home/.ssh"
printf 'fake private key\n' > "$tmp_admin_fail_home/.ssh/id_ed25519"
printf 'ssh-ed25519 AAAAFIELDWORKFAIL fieldwork\n' > "$tmp_admin_fail_home/.ssh/id_ed25519.pub"
chmod 600 "$tmp_admin_fail_home/.ssh/id_ed25519"
HOME="$tmp_admin_fail_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_ADMIN_FAIL_MODE=root-denied \
FIELDWORK_FAKE_ADMIN_FAIL_SSH_LOG="$fake_admin_fail_bin/root-denied-ssh.log" \
FIELDWORK_FAKE_ADMIN_FAIL_SCP_LOG="$fake_admin_fail_bin/root-denied-scp.log" \
FIELDWORK_FAKE_ADMIN_FAIL_ORDER="$fake_admin_fail_bin/root-denied-order.log" \
  HOME="$tmp_admin_fail_home" PATH="$fake_admin_fail_bin:$tmp_admin_fail_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-root-denied.out <<'EOF' || true
203.0.113.40
n

y
EOF
grep -q "root SSH was rejected" ${TMPDIR:-/tmp}/fieldwork-setup-root-denied.out
grep -q "existing sudo-capable VPS user" ${TMPDIR:-/tmp}/fieldwork-setup-root-denied.out
grep -q "provider console or rescue mode" ${TMPDIR:-/tmp}/fieldwork-setup-root-denied.out
grep -q "root@203.0.113.40 bash -s" "$fake_admin_fail_bin/root-denied-ssh.log"

FIELDWORK_FAKE_ADMIN_FAIL_MODE=sudo-notsudoer \
FIELDWORK_FAKE_ADMIN_FAIL_SSH_LOG="$fake_admin_fail_bin/notsudoer-ssh.log" \
FIELDWORK_FAKE_ADMIN_FAIL_SCP_LOG="$fake_admin_fail_bin/notsudoer-scp.log" \
FIELDWORK_FAKE_ADMIN_FAIL_ORDER="$fake_admin_fail_bin/notsudoer-order.log" \
  HOME="$tmp_admin_fail_home" PATH="$fake_admin_fail_bin:$tmp_admin_fail_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-sudo-notsudoer.out <<'EOF' || true
203.0.113.41
n
prateek
y
EOF
grep -q "admin user 'prateek' is not sudo-capable" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-notsudoer.out
grep -q "Choose another sudo-capable account" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-notsudoer.out
grep -q "provider console/rescue mode" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-notsudoer.out
grep -q "rm -rf -- .*tmp/fieldwork-user-setup.FAIL41" "$fake_admin_fail_bin/notsudoer-ssh.log"
grep -q "^cleanup$" "$fake_admin_fail_bin/notsudoer-order.log"

FIELDWORK_FAKE_ADMIN_FAIL_MODE=sudo-badpass \
FIELDWORK_FAKE_ADMIN_FAIL_SSH_LOG="$fake_admin_fail_bin/badpass-ssh.log" \
FIELDWORK_FAKE_ADMIN_FAIL_SCP_LOG="$fake_admin_fail_bin/badpass-scp.log" \
FIELDWORK_FAKE_ADMIN_FAIL_ORDER="$fake_admin_fail_bin/badpass-order.log" \
  HOME="$tmp_admin_fail_home" PATH="$fake_admin_fail_bin:$tmp_admin_fail_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-sudo-badpass.out <<'EOF' || true
203.0.113.41
n
prateek
y
EOF
grep -q "sudo authentication failed for 'prateek'" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-badpass.out
grep -q "VPS Linux password for 'prateek'" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-badpass.out
grep -q "rm -rf -- .*tmp/fieldwork-user-setup.FAIL41" "$fake_admin_fail_bin/badpass-ssh.log"
grep -q "^cleanup$" "$fake_admin_fail_bin/badpass-order.log"

FIELDWORK_FAKE_ADMIN_FAIL_MODE=sudo-nopassword \
FIELDWORK_FAKE_ADMIN_FAIL_SSH_LOG="$fake_admin_fail_bin/nopassword-ssh.log" \
FIELDWORK_FAKE_ADMIN_FAIL_SCP_LOG="$fake_admin_fail_bin/nopassword-scp.log" \
FIELDWORK_FAKE_ADMIN_FAIL_ORDER="$fake_admin_fail_bin/nopassword-order.log" \
  HOME="$tmp_admin_fail_home" PATH="$fake_admin_fail_bin:$tmp_admin_fail_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-sudo-nopassword.out <<'EOF' || true
203.0.113.41
n
prateek
y
EOF
grep -q "sudo password prompt could not read from your terminal" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-nopassword.out
grep -q "Rerun setup from an interactive terminal" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-nopassword.out
if grep -q "sudo authentication failed for 'prateek'" ${TMPDIR:-/tmp}/fieldwork-setup-sudo-nopassword.out; then
  echo "no-password sudo failure should not be reported as a bad password" >&2
  exit 1
fi
grep -q "rm -rf -- .*tmp/fieldwork-user-setup.FAIL41" "$fake_admin_fail_bin/nopassword-ssh.log"
grep -q "^cleanup$" "$fake_admin_fail_bin/nopassword-order.log"

echo "[checks] setup can repair rejected fieldwork SSH user"
fake_repair_ssh_bin="$(mktemp_dir)"
cat > "$fake_repair_ssh_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  echo "hostname 203.0.113.20"
  echo "user fieldwork"
  exit 0
fi
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_REPAIR_SSH_LOG"
emit_ready_snapshot() {
  cat <<'EOF'
remote_user=fieldwork
fieldwork_cli=ok
fieldwork_checkout=ok
path_configured=ok
bootstrap_ready=ok
claude_login=ok
gh_cli=ok
gh_hosts=ok
gh_live=ok
verify_runner=ok
prepare_runner=ok
claude_service=ok
broker_socket=ok
broker_pat_tool=ok
broker_thin_client=ok
broker_pat_marker=ok
broker_pat_sudo=ok
temporary_sudo=missing
public_ssh_rule=missing
projects_dir=ok
EOF
}
case "$*" in
  *"root@203.0.113.20 bash -s"*)
    cat > "$FIELDWORK_FAKE_ROOT_SCRIPT"
    touch "$FIELDWORK_FAKE_REPAIR_STATE"
    exit 0
    ;;
  *"fieldwork-setup-probe"*|*"fieldwork-vps "*"bash -s"*)
    if [ -f "$FIELDWORK_FAKE_REPAIR_STATE" ]; then
      emit_ready_snapshot
      exit 0
    fi
    echo "fieldwork@203.0.113.20: Permission denied (publickey,password)." >&2
    exit 255
    ;;
  *"fieldwork@203.0.113.20 id -un"*)
    echo "fieldwork"
    exit 0
    ;;
  *"fieldwork@203.0.113.20 sudo -n true"*)
    exit 0
    ;;
  *"fieldwork-vps true"*)
    if [ -f "$FIELDWORK_FAKE_REPAIR_STATE" ]; then
      exit 0
    fi
    echo "fieldwork@203.0.113.20: Permission denied (publickey,password)." >&2
    exit 255
    ;;
  *"fieldwork-vps id -un"*)
    echo "fieldwork"
    exit 0
    ;;
  *)
    echo "unexpected fake repair ssh command: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$fake_repair_ssh_bin/ssh"
tmp_repair_home="$(mktemp_dir)"
mkdir -p "$tmp_repair_home/.ssh"
printf 'fake private key\n' > "$tmp_repair_home/.ssh/id_ed25519"
printf 'ssh-ed25519 AAAAFIELDWORKREPAIR fieldwork\n' > "$tmp_repair_home/.ssh/id_ed25519.pub"
chmod 600 "$tmp_repair_home/.ssh/id_ed25519"
cat > "$tmp_repair_home/.ssh/config" <<'EOF'
Host fieldwork-vps
  HostName 203.0.113.20
  User fieldwork
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
chmod 600 "$tmp_repair_home/.ssh/config"
HOME="$tmp_repair_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_REPAIR_SSH_LOG="$fake_repair_ssh_bin/ssh.log" FIELDWORK_FAKE_REPAIR_STATE="$fake_repair_ssh_bin/repaired" FIELDWORK_FAKE_ROOT_SCRIPT="$fake_repair_ssh_bin/root-script.sh" \
  HOME="$tmp_repair_home" PATH="$fake_repair_ssh_bin:$tmp_repair_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-repair-user.out <<'EOF' || true

y
EOF
grep -q "SSH rejected the configured user or key" ${TMPDIR:-/tmp}/fieldwork-setup-repair-user.out
grep -q "literal 'fieldwork' user" ${TMPDIR:-/tmp}/fieldwork-setup-repair-user.out
grep -q "the 'fieldwork' user may not exist yet" ${TMPDIR:-/tmp}/fieldwork-setup-repair-user.out
grep -q "No problem. Fieldwork can create/update the 'fieldwork' user using root SSH or another sudo-capable VPS account" ${TMPDIR:-/tmp}/fieldwork-setup-repair-user.out
grep -q "SSH alias already exists: fieldwork-vps" ${TMPDIR:-/tmp}/fieldwork-setup-repair-user.out
grep -q "Tested: ssh fieldwork-vps true" ${TMPDIR:-/tmp}/fieldwork-setup-repair-user.out
grep -q "VPS reachable over SSH" ${TMPDIR:-/tmp}/fieldwork-setup-repair-user.out
grep -q "remote user is fieldwork" ${TMPDIR:-/tmp}/fieldwork-setup-repair-user.out
grep -q "root@203.0.113.20 bash -s" "$fake_repair_ssh_bin/ssh.log"
grep -q "AAAAFIELDWORKREPAIR" "$fake_repair_ssh_bin/root-script.sh"

echo "[checks] setup --yes keeps missing SSH alias non-interactive"
tmp_yes_home="$(mktemp_dir)"
HOME="$tmp_yes_home" "$ROOT/install.sh" >/dev/null
HOME="$tmp_yes_home" PATH="$fake_missing_ssh_bin:$tmp_yes_home/.local/bin:$PATH" "$ROOT/bin/fieldwork" setup --yes --skip-sync >${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-yes.out || true
grep -q "^SSH config snippet$" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-yes.out
grep -q "Use when: you have the VPS host ready" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-yes.out
grep -q "Guide if you still need a VPS: file://" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-yes.out
grep -q "first-time-infrastructure.md" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-yes.out
test ! -e "$tmp_yes_home/.ssh/config"
if grep -q "VPS hostname or IP:" ${TMPDIR:-/tmp}/fieldwork-setup-missing-alias-yes.out; then
  echo "setup --yes asked the VPS wizard question" >&2
  exit 1
fi

echo "[checks] setup syncs remote Fieldwork as a phase"
fake_remote_phase_bin="$(mktemp_dir)"
cat > "$fake_remote_phase_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  echo "hostname fake-vps"
  echo "user fieldwork"
  exit 0
fi
args="$*"
printf '%s\n' "$args" >> "$FIELDWORK_FAKE_REMOTE_PHASE_SSH_LOG"
case "$args" in
  *"fieldwork-vps true"*) exit 0 ;;
  *"fieldwork-vps id -un"*) echo "fieldwork"; exit 0 ;;
  *"fieldwork-vps test -x ~/.local/bin/fieldwork"*)
    test -f "$FIELDWORK_FAKE_REMOTE_PHASE_CLI"
    exit $?
    ;;
  *"fieldwork-vps cd ~/fieldwork && bash install.sh --quiet"*)
    touch "$FIELDWORK_FAKE_REMOTE_PHASE_CLI"
    exit 0
    ;;
  *"profile=\"\$HOME/.profile\""*)
    touch "$FIELDWORK_FAKE_REMOTE_PHASE_PATH"
    exit 0
    ;;
  *"~/.fieldwork/agents"*) exit 0 ;;
  *"fieldwork-vps case "*) test -f "$FIELDWORK_FAKE_REMOTE_PHASE_PATH"; exit $? ;;
  *"agents='claude'; export PATH="*) exit 1 ;;
  *"fieldwork-vps export PATH="*) exit 1 ;;
  *)
    echo "unexpected fake remote phase ssh command: $args" >&2
    exit 1
    ;;
esac
SH
cat > "$fake_remote_phase_bin/rsync" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_REMOTE_PHASE_RSYNC_LOG"
SH
chmod +x "$fake_remote_phase_bin/ssh" "$fake_remote_phase_bin/rsync"
tmp_remote_phase_home="$(mktemp_dir)"
HOME="$tmp_remote_phase_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_REMOTE_PHASE_SSH_LOG="$fake_remote_phase_bin/ssh.log" \
FIELDWORK_FAKE_REMOTE_PHASE_RSYNC_LOG="$fake_remote_phase_bin/rsync.log" \
FIELDWORK_FAKE_REMOTE_PHASE_CLI="$fake_remote_phase_bin/remote-cli-ready" \
FIELDWORK_FAKE_REMOTE_PHASE_PATH="$fake_remote_phase_bin/remote-path-ready" \
HOME="$tmp_remote_phase_home" PATH="$fake_remote_phase_bin:$tmp_remote_phase_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup >${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out <<'EOF' || true
y
n
EOF
grep -q "^\\[2/5\\] Prepare server$" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "^Remote Fieldwork install" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "bash install.sh --quiet" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "VPS shell profile can find ~/.local/bin" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "^VPS bootstrap$" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "VPS bootstrap will prepare the server runtime" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "Some steps after this require your approval" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "saves the full command log on the VPS" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "bootstrap-vps --verbose" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "Run VPS bootstrap now" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "\\[ready\\] checkout synced" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "\\[ready\\] remote Fieldwork assets linked" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "ssh -t fieldwork-vps 'cd ~/fieldwork && ./bin/fieldwork bootstrap-vps'" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out
grep -q "bash install.sh --quiet" "$fake_remote_phase_bin/ssh.log"
grep -q -- "--delete" "$fake_remote_phase_bin/rsync.log"
grep -q -- "--exclude .git" "$fake_remote_phase_bin/rsync.log"
grep -q -- "-e ssh -o ControlMaster=auto" "$fake_remote_phase_bin/rsync.log"
if grep -q "\\[fieldwork sync-vps\\] done" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out; then
  echo "setup kept old sync/bootstrap copy" >&2
  exit 1
fi
if grep -q "^Fieldwork install$" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out; then
  echo "setup exposed nested install UI during remote sync" >&2
  exit 1
fi
if grep -q "Claude Code CLI missing\\|GitHub CLI missing\\|^Notifications" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out; then
  echo "setup dumped downstream checks before bootstrap phase completed" >&2
  exit 1
fi
if grep -qi "tailscale" ${TMPDIR:-/tmp}/fieldwork-setup-remote-phase.out; then
  echo "setup output mentioned Tailscale" >&2
  exit 1
fi

echo "[checks] setup passes Codex agent selection into bootstrap"
fake_codex_bootstrap_bin="$(mktemp_dir)"
cat > "$fake_codex_bootstrap_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  echo "hostname fake-vps"
  echo "user fieldwork"
  exit 0
fi
args="$*"
printf '%s\n' "$args" >> "$FIELDWORK_FAKE_CODEX_BOOTSTRAP_SSH_LOG"
case "$args" in
  *"fieldwork-vps true"*) exit 0 ;;
  *"fieldwork-vps id -un"*) echo "fieldwork"; exit 0 ;;
  *"fieldwork-vps test -x ~/.local/bin/fieldwork"*) exit 0 ;;
  *"fieldwork-vps cd ~/fieldwork && cksum "*)
    printf '%s\n' "$FIELDWORK_FAKE_CODEX_BOOTSTRAP_LOCAL_FINGERPRINT"
    exit 0
    ;;
  *"profile=\"\$HOME/.profile\""*) exit 0 ;;
  *"~/.fieldwork/agents"*) exit 0 ;;
  *"fieldwork-vps case "*) exit 0 ;;
  *"agents='codex'; export PATH="*) exit 1 ;;
  *"FIELDWORK_SETUP_CONTEXT=guided FIELDWORK_SETUP_AGENTS='codex' ./bin/fieldwork bootstrap-vps"*)
    touch "$FIELDWORK_FAKE_CODEX_BOOTSTRAP_RAN"
    exit 0
    ;;
  *)
    echo "unexpected fake codex bootstrap ssh command: $args" >&2
    exit 1
    ;;
esac
SH
cat > "$fake_codex_bootstrap_bin/rsync" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_CODEX_BOOTSTRAP_RSYNC_LOG"
SH
chmod +x "$fake_codex_bootstrap_bin/ssh" "$fake_codex_bootstrap_bin/rsync"
tmp_codex_bootstrap_home="$(mktemp_dir)"
HOME="$tmp_codex_bootstrap_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_CODEX_BOOTSTRAP_SSH_LOG="$fake_codex_bootstrap_bin/ssh.log" \
FIELDWORK_FAKE_CODEX_BOOTSTRAP_RSYNC_LOG="$fake_codex_bootstrap_bin/rsync.log" \
FIELDWORK_FAKE_CODEX_BOOTSTRAP_RAN="$fake_codex_bootstrap_bin/bootstrap-ran" \
FIELDWORK_FAKE_CODEX_BOOTSTRAP_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_codex_bootstrap_home" PATH="$fake_codex_bootstrap_bin:$tmp_codex_bootstrap_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup --agent codex >${TMPDIR:-/tmp}/fieldwork-setup-codex-bootstrap.out <<'EOF' || true
y
EOF
test -f "$fake_codex_bootstrap_bin/bootstrap-ran"
grep -q "configured agents recorded: codex" ${TMPDIR:-/tmp}/fieldwork-setup-codex-bootstrap.out
grep -q "install GitHub CLI, Docker support, and Fieldwork runner sockets" ${TMPDIR:-/tmp}/fieldwork-setup-codex-bootstrap.out
grep -q "FIELDWORK_SETUP_CONTEXT=guided FIELDWORK_SETUP_AGENTS='codex' ./bin/fieldwork bootstrap-vps" "$fake_codex_bootstrap_bin/ssh.log"
if grep -q "FIELDWORK_SETUP_AGENTS='claude'" "$fake_codex_bootstrap_bin/ssh.log"; then
  echo "Codex-only setup passed claude agents into bootstrap" >&2
  exit 1
fi
if grep -q "install GitHub CLI, Docker support, and Claude Code" ${TMPDIR:-/tmp}/fieldwork-setup-codex-bootstrap.out; then
  echo "Codex-only bootstrap prompt should not advertise Claude Code install" >&2
  exit 1
fi

echo "[checks] setup syncs stale remote Fieldwork before bootstrap"
fake_stale_remote_bin="$(mktemp_dir)"
cat > "$fake_stale_remote_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  echo "hostname fake-vps"
  echo "user fieldwork"
  exit 0
fi
args="$*"
printf '%s\n' "$args" >> "$FIELDWORK_FAKE_STALE_REMOTE_SSH_LOG"
case "$args" in
  *"fieldwork-vps true"*) exit 0 ;;
  *"fieldwork-vps id -un"*) echo "fieldwork"; exit 0 ;;
  *"fieldwork-vps test -x ~/.local/bin/fieldwork"*) exit 0 ;;
  *"fieldwork-vps cd ~/fieldwork && cksum "*)
    if [ -f "$FIELDWORK_FAKE_STALE_REMOTE_SYNCED" ]; then
      printf '%s\n' "$FIELDWORK_FAKE_STALE_REMOTE_LOCAL_FINGERPRINT"
    else
      printf '%s\n' "0 0 bin/fieldwork"
    fi
    exit 0
    ;;
	  *"fieldwork-vps cd ~/fieldwork && bash install.sh --quiet"*)
	    touch "$FIELDWORK_FAKE_STALE_REMOTE_SYNCED"
	    exit 0
	    ;;
	  *"profile=\"\$HOME/.profile\""*)
	    touch "$FIELDWORK_FAKE_STALE_REMOTE_PATH"
	    exit 0
	    ;;
	  *"~/.fieldwork/agents"*) exit 0 ;;
	  *"fieldwork-vps case "*) test -f "$FIELDWORK_FAKE_STALE_REMOTE_PATH"; exit $? ;;
	  *"fieldwork-vps export PATH="*) exit 1 ;;
  *)
    echo "unexpected fake stale remote ssh command: $args" >&2
    exit 1
    ;;
esac
SH
cat > "$fake_stale_remote_bin/rsync" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_STALE_REMOTE_RSYNC_LOG"
SH
chmod +x "$fake_stale_remote_bin/ssh" "$fake_stale_remote_bin/rsync"
tmp_stale_remote_home="$(mktemp_dir)"
HOME="$tmp_stale_remote_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_STALE_REMOTE_SSH_LOG="$fake_stale_remote_bin/ssh.log" \
FIELDWORK_FAKE_STALE_REMOTE_RSYNC_LOG="$fake_stale_remote_bin/rsync.log" \
FIELDWORK_FAKE_STALE_REMOTE_SYNCED="$fake_stale_remote_bin/synced" \
FIELDWORK_FAKE_STALE_REMOTE_PATH="$fake_stale_remote_bin/path-ready" \
FIELDWORK_FAKE_STALE_REMOTE_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
HOME="$tmp_stale_remote_home" PATH="$fake_stale_remote_bin:$tmp_stale_remote_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup >${TMPDIR:-/tmp}/fieldwork-setup-stale-remote.out <<'EOF' || true
y
n
EOF
grep -q "remote Fieldwork CLI installed" ${TMPDIR:-/tmp}/fieldwork-setup-stale-remote.out
grep -q "remote Fieldwork checkout differs from this copy" ${TMPDIR:-/tmp}/fieldwork-setup-stale-remote.out
grep -q "remote Fieldwork checkout matches this copy" ${TMPDIR:-/tmp}/fieldwork-setup-stale-remote.out
grep -q "Run VPS bootstrap now" ${TMPDIR:-/tmp}/fieldwork-setup-stale-remote.out
grep -q -- "--delete" "$fake_stale_remote_bin/rsync.log"
grep -q -- "--exclude .git" "$fake_stale_remote_bin/rsync.log"
grep -q -- "-e ssh -o ControlMaster=auto" "$fake_stale_remote_bin/rsync.log"
grep -q "cksum $FIELDWORK_TEST_FINGERPRINT_FILES" "$fake_stale_remote_bin/ssh.log"

echo "[checks] setup guides manual account follow-ups in one phase"
fake_manual_phase_bin="$(mktemp_dir)"
cat > "$fake_manual_phase_bin/ssh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then
  echo "hostname fake-vps"
  echo "user fieldwork"
  exit 0
fi
args="$*"
printf '%s\n' "$args" >> "$FIELDWORK_FAKE_MANUAL_PHASE_SSH_LOG"
case "$args" in
  *"fieldwork-vps true"*) exit 0 ;;
  *"fieldwork-vps id -un"*) echo "fieldwork"; exit 0 ;;
  *"fieldwork-vps test -x ~/.local/bin/fieldwork"*) exit 0 ;;
  *"fieldwork-vps cd ~/fieldwork && cksum "*)
    printf '%s\n' "$FIELDWORK_FAKE_MANUAL_PHASE_LOCAL_FINGERPRINT"
    exit 0
    ;;
  *"fieldwork-vps case "*) exit 0 ;;
  *"command -v claude"*"command -v gh"*"fieldwork-agent@.service"*) exit 0 ;;
  *"sudo -n ufw status"*) exit 1 ;;
  *"test -f ~/.fieldwork/state/claude-login-confirmed"*)
    test -f "$FIELDWORK_FAKE_MANUAL_PHASE_CLAUDE"
    exit $?
    ;;
  *"-t fieldwork-vps ~/.local/bin/claude login"*)
    touch "$FIELDWORK_FAKE_MANUAL_PHASE_CLAUDE_LOGIN_RAN"
    exit 0
    ;;
  *"mkdir -p ~/.fieldwork/state && chmod 700 ~/.fieldwork && touch ~/.fieldwork/state/claude-login-confirmed"*)
    touch "$FIELDWORK_FAKE_MANUAL_PHASE_CLAUDE"
    exit 0
    ;;
  *"gh auth status"*)
    test -f "$FIELDWORK_FAKE_MANUAL_PHASE_GH"
    exit $?
    ;;
  *"-t fieldwork-vps gh auth login"*)
    touch "$FIELDWORK_FAKE_MANUAL_PHASE_GH"
    if [ "${FIELDWORK_FAKE_MANUAL_PHASE_GH_DISCONNECT:-0}" = "1" ]; then
      exit 255
    fi
    exit 0
    ;;
	  *"mkdir -p ~/.fieldwork/state && chmod 700 ~/.fieldwork && touch ~/.fieldwork/state/broker-pat-confirmed"*)
	    touch "$FIELDWORK_FAKE_MANUAL_PHASE_BROKER_PAT"
	    exit 0
	    ;;
	  *"~/.fieldwork/agents"*) exit 0 ;;
	  *"mkdir -p ~/.fieldwork && chmod 700 ~/.fieldwork"*) exit 0 ;;
  *"chmod 600 ~/.fieldwork/notify.env"*) exit 0 ;;
  *"curl -fsS --connect-timeout 5 --max-time 20"*"https://ntfy.sh/\$NTFY_TOPIC"*) exit 0 ;;
	  *"test -f ~/.fieldwork/notify.env"*)
	    test -f "$FIELDWORK_FAKE_MANUAL_PHASE_REMOTE_NOTIFY"
	    exit $?
	    ;;
	  *"test -f ~/.config/systemd/user/fieldwork-agent@.service"*) exit 0 ;;
	  *"fieldwork-verify-runner.socket"*"bwrap --unshare-user --unshare-net --unshare-pid --unshare-uts --unshare-ipc"*) exit 0 ;;
	  *"test -f ~/.config/systemd/user/fieldwork-verify-runner.socket"*) exit 0 ;;
	  *"test -f ~/.config/systemd/user/fieldwork-pr-prepare-runner.socket"*) exit 0 ;;
  *"test -S /run/fieldwork-pr-broker/fieldwork-pr.sock"*)
    test -f "$FIELDWORK_FAKE_MANUAL_PHASE_BROKER_SOCKET"
    exit $?
    ;;
  *"http://localhost/preflight"*)
    printf '{"ok": false, "request_id": "test", "error": "preflight request missing required field: repo"}\n'
    exit 0
    ;;
  *"test -f /usr/local/sbin/rotate-pat"*)
    test -f "$FIELDWORK_FAKE_MANUAL_PHASE_BROKER_INSTALLED"
    exit $?
    ;;
  *"test -e ~/.local/bin/fieldwork-pr-submit"*)
    test -f "$FIELDWORK_FAKE_MANUAL_PHASE_BROKER_INSTALLED"
    exit $?
    ;;
  *"test -f ~/.fieldwork/state/broker-pat-confirmed"*)
    test -f "$FIELDWORK_FAKE_MANUAL_PHASE_BROKER_PAT"
    exit $?
    ;;
  *"sudo -n stat -c '%U:%G %a' /etc/fieldwork-pr-broker/gh-token"*)
    test -f "$FIELDWORK_FAKE_MANUAL_PHASE_BROKER_PAT"
    exit $?
    ;;
  *"-t fieldwork-vps sudo -p "*"bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh"*)
    touch "$FIELDWORK_FAKE_MANUAL_PHASE_BROKER_INSTALLED"
    touch "$FIELDWORK_FAKE_MANUAL_PHASE_BROKER_SOCKET"
    exit 0
    ;;
  *"sudo -p "*" env FIELDWORK_ROTATE_PAT_TTY=1 "*"/usr/local/sbin/rotate-pat"*)
    printf '\nVPS sudo authentication\n'
    printf "  If sudo asks for a password, enter the VPS Linux password for 'fieldwork'.\n"
    printf '  This is not your Claude account password and not the GitHub PAT.\n'
    printf '\nBroker token paste\n'
    printf '  After sudo succeeds, rotate-pat will ask for the GitHub PAT with hidden input.\n'
    touch "$FIELDWORK_FAKE_MANUAL_PHASE_BROKER_PAT"
    exit 0
    ;;
  *"test -f '/etc/sudoers.d/fieldwork-fieldwork'"*) exit 1 ;;
  *)
    echo "unexpected fake manual phase ssh command: $args" >&2
    exit 1
    ;;
esac
SH
cat > "$fake_manual_phase_bin/scp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_MANUAL_PHASE_SCP_LOG"
touch "$FIELDWORK_FAKE_MANUAL_PHASE_REMOTE_NOTIFY"
SH
cat > "$fake_manual_phase_bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_MANUAL_PHASE_CURL_LOG"
SH
chmod +x "$fake_manual_phase_bin/ssh" "$fake_manual_phase_bin/scp" "$fake_manual_phase_bin/curl"
tmp_manual_phase_home="$(mktemp_dir)"
HOME="$tmp_manual_phase_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_MANUAL_PHASE_SSH_LOG="$fake_manual_phase_bin/ssh.log" \
FIELDWORK_FAKE_MANUAL_PHASE_SCP_LOG="$fake_manual_phase_bin/scp.log" \
FIELDWORK_FAKE_MANUAL_PHASE_CURL_LOG="$fake_manual_phase_bin/curl.log" \
FIELDWORK_FAKE_MANUAL_PHASE_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
FIELDWORK_FAKE_MANUAL_PHASE_CLAUDE="$fake_manual_phase_bin/claude-confirmed" \
FIELDWORK_FAKE_MANUAL_PHASE_CLAUDE_LOGIN_RAN="$fake_manual_phase_bin/claude-login-ran" \
FIELDWORK_FAKE_MANUAL_PHASE_GH="$fake_manual_phase_bin/gh-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_REMOTE_NOTIFY="$fake_manual_phase_bin/remote-notify-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_INSTALLED="$fake_manual_phase_bin/broker-installed" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_SOCKET="$fake_manual_phase_bin/broker-socket" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_PAT="$fake_manual_phase_bin/broker-pat" \
FIELDWORK_FAKE_MANUAL_PHASE_GH_DISCONNECT=1 \
HOME="$tmp_manual_phase_home" PATH="$fake_manual_phase_bin:$tmp_manual_phase_home/.local/bin:$PATH" \
  "$tmp_manual_phase_home/.local/bin/fieldwork" setup >${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out 2>${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.err <<'EOF'
y
y
y
n
n
EOF
if [ -s ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.err ]; then
  echo "setup decline-broker flow wrote unexpected stderr" >&2
  cat ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.err >&2
  exit 1
fi
grep -q "^\\[3/5\\] Connect GitHub$" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "^\\[4/5\\] Install PR services$" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "Purpose: Authenticate Claude Code on the VPS" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "If Claude opens an auth or device-code flow" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "If Claude already shows 'Welcome back'" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "type exit to return to Fieldwork" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "\\[ready\\] Claude Code login confirmed" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "Purpose: Authenticate gh for repo-resolution preflights" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "Git protocol: SSH" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "Do not paste the broker token here" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "Browser hint: the VPS has no desktop browser" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "Credential note: gh may warn that credentials were saved in plain text" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "GitHub CLI's browser-login token" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "not the broker PAT" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "The SSH session disconnected after browser auth. That is okay." ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "Claude Code login confirmed" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "GitHub CLI authenticated" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
if grep -q "Send mobile pushes\|Configure local ntfy\|local ntfy topic\|Ntfy mobile subscription" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out; then
  echo "setup default path should not run the notification subsection" >&2
  exit 1
fi
grep -q "^Install PR services pending:$" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "Purpose: Verify the VPS service template that runs Claude sessions" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "^PR broker$" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "^PR broker setup$" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "Install the broker daemon, socket, and rotate-pat helper" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "Install PR broker now" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
line_pr_overview="$(grep -n -m1 "^PR broker setup$" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out | cut -d: -f1)"
line_pr_install_prompt="$(grep -n -m1 "Install PR broker now" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out | cut -d: -f1)"
if sed -n "${line_pr_overview},${line_pr_install_prompt}p" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out | grep -q "Repository access:"; then
  echo "setup should not show GitHub PAT permissions before the PAT step" >&2
  exit 1
fi
grep -q "^Install PR services pending:$" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "  - PR broker install$" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -q "Setup has .* remaining action" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
grep -Fq 'ssh -t fieldwork-vps "sudo -p '\''[sudo] VPS Linux password for fieldwork: '\'' bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh"' ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out
if grep -q "then sudo /usr/local/sbin/rotate-pat, then reconnect" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out; then
  echo "setup should not present broker setup as one compound command" >&2
  exit 1
fi
if grep -q "syntax error" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.err ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out; then
  echo "setup decline-broker flow should not end with a syntax error" >&2
  exit 1
fi
if grep -q "Continuing to check later phases" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out; then
  echo "setup should not print confusing continuation wording" >&2
  exit 1
fi
if grep -qi "tailscale" ${TMPDIR:-/tmp}/fieldwork-setup-manual-phase.out; then
  echo "setup manual-phase output mentioned Tailscale" >&2
  exit 1
fi
grep -q -- "-t fieldwork-vps ~/.local/bin/claude login" "$fake_manual_phase_bin/ssh.log"
grep -q -- "-t fieldwork-vps gh auth login" "$fake_manual_phase_bin/ssh.log"

echo "[checks] setup-notify resolves local then remote stages in order"
tmp_notify_flow_home="$(mktemp_dir)"
HOME="$tmp_notify_flow_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_MANUAL_PHASE_SSH_LOG="$fake_manual_phase_bin/notify-ssh.log" \
FIELDWORK_FAKE_MANUAL_PHASE_SCP_LOG="$fake_manual_phase_bin/notify-scp.log" \
FIELDWORK_FAKE_MANUAL_PHASE_CURL_LOG="$fake_manual_phase_bin/notify-curl.log" \
FIELDWORK_FAKE_MANUAL_PHASE_REMOTE_NOTIFY="$fake_manual_phase_bin/notify-remote-ready" \
HOME="$tmp_notify_flow_home" PATH="$fake_manual_phase_bin:$tmp_notify_flow_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup-notify --remote >${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out <<'EOF' || true


EOF
grep -q "local notification config written" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out
grep -q "^Ntfy mobile subscription$" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out
grep -q "Purpose: subscribe your phone before Fieldwork sends the test notification" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out
grep -q "Command: ntfy mobile app -> Subscribe to topic -> fieldwork-" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out
grep -q "Press Enter after subscribing" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out
grep -q "local ntfy test push sent" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out
grep -q "you should see the test notification now" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out
grep -q "remote notification config copied" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out
grep -q "remote ntfy test push sent" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out
grep -q "you should see the VPS test notification now" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out
grep -q -- "--connect-timeout 5 --max-time 20" "$fake_manual_phase_bin/notify-curl.log"
grep -q -- "--connect-timeout 5 --max-time 20" "$fake_manual_phase_bin/notify-ssh.log"
line_write="$(grep -n -m1 "local notification config written" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out | cut -d: -f1)"
line_subscribe="$(grep -n -m1 "Ntfy mobile subscription" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out | cut -d: -f1)"
line_local_test="$(grep -n -m1 "local ntfy test push sent" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out | cut -d: -f1)"
line_local_hint="$(grep -n -m1 "you should see the test notification now" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out | cut -d: -f1)"
line_remote_copy="$(grep -n -m1 "remote notification config copied" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out | cut -d: -f1)"
line_remote_test="$(grep -n -m1 "remote ntfy test push sent" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out | cut -d: -f1)"
line_remote_hint="$(grep -n -m1 "you should see the VPS test notification now" ${TMPDIR:-/tmp}/fieldwork-setup-notify-flow.out | cut -d: -f1)"
test "$line_write" -lt "$line_subscribe"
test "$line_subscribe" -lt "$line_local_test"
test "$line_local_test" -lt "$line_local_hint"
test "$line_local_hint" -lt "$line_remote_copy"
test "$line_remote_copy" -lt "$line_remote_test"
test "$line_remote_test" -lt "$line_remote_hint"

echo "[checks] setup guides PR broker setup interactively"
tmp_broker_flow_home="$(mktemp_dir)"
HOME="$tmp_broker_flow_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_MANUAL_PHASE_SSH_LOG="$fake_manual_phase_bin/broker-ssh.log" \
FIELDWORK_FAKE_MANUAL_PHASE_SCP_LOG="$fake_manual_phase_bin/broker-scp.log" \
FIELDWORK_FAKE_MANUAL_PHASE_CURL_LOG="$fake_manual_phase_bin/broker-curl.log" \
FIELDWORK_FAKE_MANUAL_PHASE_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
FIELDWORK_FAKE_MANUAL_PHASE_CLAUDE="$fake_manual_phase_bin/broker-claude-confirmed" \
FIELDWORK_FAKE_MANUAL_PHASE_CLAUDE_LOGIN_RAN="$fake_manual_phase_bin/broker-claude-login-ran" \
FIELDWORK_FAKE_MANUAL_PHASE_GH="$fake_manual_phase_bin/broker-gh-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_REMOTE_NOTIFY="$fake_manual_phase_bin/broker-remote-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_INSTALLED="$fake_manual_phase_bin/broker-installed-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_SOCKET="$fake_manual_phase_bin/broker-socket-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_PAT="$fake_manual_phase_bin/broker-pat-ready" \
HOME="$tmp_broker_flow_home" PATH="$fake_manual_phase_bin:$tmp_broker_flow_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup >${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out <<'EOF' || true
y
y
y
y
y
ready

y
EOF
grep -q "^PR broker setup$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "Fieldwork will walk through three steps" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "Install PR broker now" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "PR broker installer completed" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "^Broker GitHub token$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "The broker needs a GitHub token to" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "push setup branches" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "^PR broker progress$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "^\\[02/03\\] Add GitHub token$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "Step %02d/%02d .*Add GitHub token" "$ROOT/lib/cli/setup.sh"
grep -q "Do you already have a fine-grained GitHub PAT" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "^Secure handoff$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "Linux sudo password for user 'fieldwork'" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "GitHub PAT at a hidden token prompt" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "The token paste is requested only after sudo" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "Start broker PAT handoff" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "^VPS sudo authentication$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "This is not your Claude account password and not the GitHub PAT" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "^Broker token paste$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "Broker token stored" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
grep -q "broker socket writable" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out
line_broker_overview="$(grep -n -m1 "^PR broker setup$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out | cut -d: -f1)"
line_broker_install_prompt="$(grep -n -m1 "Install PR broker now" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out | cut -d: -f1)"
if sed -n "${line_broker_overview},${line_broker_install_prompt}p" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out | grep -q "Repository access:"; then
  echo "broker overview should not show GitHub PAT permissions before the PAT step" >&2
  exit 1
fi
grep -q -- "-t fieldwork-vps sudo -p .*bash ~/.fieldwork/infra/fieldwork-pr-broker/install.sh" "$fake_manual_phase_bin/broker-ssh.log"
grep -q -- "sudo -p .* env FIELDWORK_ROTATE_PAT_TTY=1 .*/usr/local/sbin/rotate-pat" "$fake_manual_phase_bin/broker-ssh.log"
if grep -q "then sudo /usr/local/sbin/rotate-pat, then reconnect" ${TMPDIR:-/tmp}/fieldwork-setup-broker-flow.out; then
  echo "broker flow should not print the old compound next action" >&2
  exit 1
fi

echo "[checks] setup explains broker PAT creation when asked"
tmp_broker_help_home="$(mktemp_dir)"
HOME="$tmp_broker_help_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_MANUAL_PHASE_SSH_LOG="$fake_manual_phase_bin/broker-help-ssh.log" \
FIELDWORK_FAKE_MANUAL_PHASE_SCP_LOG="$fake_manual_phase_bin/broker-help-scp.log" \
FIELDWORK_FAKE_MANUAL_PHASE_CURL_LOG="$fake_manual_phase_bin/broker-help-curl.log" \
FIELDWORK_FAKE_MANUAL_PHASE_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
FIELDWORK_FAKE_MANUAL_PHASE_CLAUDE="$fake_manual_phase_bin/broker-help-claude-confirmed" \
FIELDWORK_FAKE_MANUAL_PHASE_CLAUDE_LOGIN_RAN="$fake_manual_phase_bin/broker-help-claude-login-ran" \
FIELDWORK_FAKE_MANUAL_PHASE_GH="$fake_manual_phase_bin/broker-help-gh-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_REMOTE_NOTIFY="$fake_manual_phase_bin/broker-help-remote-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_INSTALLED="$fake_manual_phase_bin/broker-help-installed-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_SOCKET="$fake_manual_phase_bin/broker-help-socket-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_PAT="$fake_manual_phase_bin/broker-help-pat-ready" \
HOME="$tmp_broker_help_home" PATH="$fake_manual_phase_bin:$tmp_broker_help_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup >${TMPDIR:-/tmp}/fieldwork-setup-broker-help.out <<'EOF' || true
y
y
y
y
?
ready

y
EOF
grep -q "A GitHub PAT lets the broker push branches" ${TMPDIR:-/tmp}/fieldwork-setup-broker-help.out
grep -q "^Recommended token:$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-help.out
grep -q "Type: Fine-grained personal access token" ${TMPDIR:-/tmp}/fieldwork-setup-broker-help.out
grep -q "Repository access: selected repositories only" ${TMPDIR:-/tmp}/fieldwork-setup-broker-help.out
grep -q "^Required permissions:$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-help.out
grep -q "Normal 'fieldwork onboard' adds template files under .github/workflows/" ${TMPDIR:-/tmp}/fieldwork-setup-broker-help.out
grep -q "fieldwork onboard --no-workflows" ${TMPDIR:-/tmp}/fieldwork-setup-broker-help.out
grep -q "^Create a fine-grained GitHub PAT now$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-help.out
grep -q "\\[fieldwork setup\\] Type 'ready' to continue, or 'skip' to do this later:" ${TMPDIR:-/tmp}/fieldwork-setup-broker-help.out
grep -q "Broker token stored" ${TMPDIR:-/tmp}/fieldwork-setup-broker-help.out
grep -q -- "sudo -p .* env FIELDWORK_ROTATE_PAT_TTY=1 .*/usr/local/sbin/rotate-pat" "$fake_manual_phase_bin/broker-help-ssh.log"

echo "[checks] setup can defer broker PAT without opening sudo"
tmp_broker_skip_home="$(mktemp_dir)"
HOME="$tmp_broker_skip_home" "$ROOT/install.sh" >/dev/null
FIELDWORK_FAKE_MANUAL_PHASE_SSH_LOG="$fake_manual_phase_bin/broker-skip-ssh.log" \
FIELDWORK_FAKE_MANUAL_PHASE_SCP_LOG="$fake_manual_phase_bin/broker-skip-scp.log" \
FIELDWORK_FAKE_MANUAL_PHASE_CURL_LOG="$fake_manual_phase_bin/broker-skip-curl.log" \
FIELDWORK_FAKE_MANUAL_PHASE_LOCAL_FINGERPRINT="$(cd "$ROOT" && cksum $FIELDWORK_TEST_FINGERPRINT_FILES)" \
FIELDWORK_FAKE_MANUAL_PHASE_CLAUDE="$fake_manual_phase_bin/broker-skip-claude-confirmed" \
FIELDWORK_FAKE_MANUAL_PHASE_CLAUDE_LOGIN_RAN="$fake_manual_phase_bin/broker-skip-claude-login-ran" \
FIELDWORK_FAKE_MANUAL_PHASE_GH="$fake_manual_phase_bin/broker-skip-gh-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_REMOTE_NOTIFY="$fake_manual_phase_bin/broker-skip-remote-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_INSTALLED="$fake_manual_phase_bin/broker-skip-installed-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_SOCKET="$fake_manual_phase_bin/broker-skip-socket-ready" \
FIELDWORK_FAKE_MANUAL_PHASE_BROKER_PAT="$fake_manual_phase_bin/broker-skip-pat-ready" \
HOME="$tmp_broker_skip_home" PATH="$fake_manual_phase_bin:$tmp_broker_skip_home/.local/bin:$PATH" \
  "$ROOT/bin/fieldwork" setup >${TMPDIR:-/tmp}/fieldwork-setup-broker-skip.out <<'EOF' || true
y
y
y
y
n
skip
EOF
grep -q "^Create a fine-grained GitHub PAT now$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-skip.out
grep -q "Skipped for now; setup will keep the broker token pending" ${TMPDIR:-/tmp}/fieldwork-setup-broker-skip.out
grep -q "\\[manual\\] Broker token not installed" ${TMPDIR:-/tmp}/fieldwork-setup-broker-skip.out
grep -q "^Install PR services pending:$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-skip.out
grep -q "  - Broker token not installed$" ${TMPDIR:-/tmp}/fieldwork-setup-broker-skip.out
if grep -q -- "FIELDWORK_ROTATE_PAT_TTY=1 .*/usr/local/sbin/rotate-pat" "$fake_manual_phase_bin/broker-skip-ssh.log"; then
  echo "broker PAT skip path should not open sudo" >&2
  exit 1
fi

echo "[checks] setup-notify help"
"$ROOT/bin/fieldwork" setup-notify --help >${TMPDIR:-/tmp}/fieldwork-setup-notify-help.out
grep -q "setup-notify .*--yes" ${TMPDIR:-/tmp}/fieldwork-setup-notify-help.out

echo "[checks] sync-vps dry run"
"$ROOT/bin/fieldwork" sync-vps --dry-run >${TMPDIR:-/tmp}/fieldwork-sync-dry-run.out
grep -q "^Remote Fieldwork install" ${TMPDIR:-/tmp}/fieldwork-sync-dry-run.out
grep -q "^This will:" ${TMPDIR:-/tmp}/fieldwork-sync-dry-run.out
grep -q "bash install.sh --quiet" ${TMPDIR:-/tmp}/fieldwork-sync-dry-run.out
grep -q "dry run only" ${TMPDIR:-/tmp}/fieldwork-sync-dry-run.out
grep -q "rsync -a --delete --exclude .git" ${TMPDIR:-/tmp}/fieldwork-sync-dry-run.out

echo "[checks] setup rerun speed docs and cache safety"
grep -q "FIELDWORK_SSH_MULTIPLEX=0" "$ROOT/docs/cli-reference.md"
grep -q "FIELDWORK_SSH_CONTROL_PERSIST=<seconds>" "$ROOT/docs/cli-reference.md"
grep -q "0.*closes the master when the last session exits" "$ROOT/docs/cli-reference.md"
grep -q "FIELDWORK_SSH_DEBUG=1" "$ROOT/docs/cli-reference.md"
grep -q "FIELDWORK_SETUP_PROBE_TIMEOUT_SECONDS=<seconds>" "$ROOT/docs/cli-reference.md"
grep -q "Bash 3.2-compatible" "$ROOT/docs/cli-reference.md"
grep -q "rm -rf ~/.cache/fieldwork/ssh-control" "$ROOT/docs/cli-reference.md"
grep -q "rm -rf ~/.cache/fieldwork/ssh-control" "$ROOT/docs/setup.md"
grep -q "does not write a setup state cache" "$ROOT/docs/cli-reference.md"
grep -q "sleep 3" "$ROOT/bin/fieldwork"
grep -q "FIELDWORK_SETUP_SNAPSHOT_DIRTY=1" "$ROOT/bin/fieldwork"
grep -q "FIELDWORK_SETUP_SNAPSHOT_FAILED=1" "$ROOT/bin/fieldwork"
if grep -R "setup-state\\.json\\|last_verified_at\\|PAT valid" "$ROOT/bin" "$ROOT/lib" "$ROOT/docs" >/dev/null; then
  echo "setup rerun speed V1 should not introduce a persistent auth/setup cache" >&2
  exit 1
fi

echo "[checks] bootstrap output uses checklist rows"
"$ROOT/bin/fieldwork" bootstrap-vps --help >${TMPDIR:-/tmp}/fieldwork-bootstrap-help.out
grep -q -- "--verbose" ${TMPDIR:-/tmp}/fieldwork-bootstrap-help.out
grep -q -- "--log-file" ${TMPDIR:-/tmp}/fieldwork-bootstrap-help.out
grep -q "sudo may prompt for the Linux password" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "not your Claude/Codex account password or GitHub token" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "bootstrap disables root SSH and password SSH login" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "keep a non-Fieldwork sudo account for recovery" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "normalize_bootstrap_agents()" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "bootstrap_agent_enabled()" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "FIELDWORK_BOOTSTRAP_AGENTS" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "Claude Code install skipped for Codex-only setup" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "if bootstrap_agent_enabled claude; then" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -Fq 'FIELDWORK_SETUP_AGENTS=$agents_q ./bin/fieldwork bootstrap-vps' "$ROOT/lib/cli/setup.sh"
grep -q "sudo_ready_without_prompt()" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "SUDO -n true" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "step \"system packages and GitHub CLI\"" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "TOTAL_PHASES=10" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "progress_dots()" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "NodeSource signing key" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "https://deb.nodesource.com/node_22.x" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "/etc/apt/keyrings/nodesource.gpg" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "/etc/apt/sources.list.d/nodesource.sources" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "nodejs" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q 'show_version "node" node --version' "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q 'show_version "npm" npm --version' "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "run_quiet \"System packages installed\"" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "run_optional \"Claude Code stable channel selected\"" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "Still working... %ss" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "running_mark()" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "FIELDWORK_PROGRESS_HEARTBEAT_SECONDS" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "progress_wait()" "$ROOT/bin/fieldwork"
grep -q "status_running_mark()" "$ROOT/bin/fieldwork"
grep -q "checking remote Fieldwork checkout" "$ROOT/lib/cli/setup.sh"
grep -q "lib/broker/server.py schema/pr-request.schema.json" "$ROOT/bin/fieldwork"
grep -q "broker_preflight_contract_ok()" "$ROOT/bin/fieldwork"
grep -q "validate_runtime_config()" "$ROOT/bin/fieldwork"
grep -q "shell_quote()" "$ROOT/bin/fieldwork"
grep -q "temporary_passwordless_sudo_present()" "$ROOT/bin/fieldwork"
grep -q "Remove temporary passwordless sudo" "$ROOT/lib/cli/setup.sh"
grep -q "FIELDWORK_ACTIVE_PID" "$ROOT/bin/fieldwork"
grep -q "cleanup_active_child()" "$ROOT/bin/fieldwork"
grep -q "hide_cursor()" "$ROOT/bin/fieldwork"
grep -q "show_cursor()" "$ROOT/bin/fieldwork"
grep -Fq "033[?25l" "$ROOT/bin/fieldwork"
grep -Fq "033[?25h" "$ROOT/bin/fieldwork"
grep -Fq "033[?25l" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -Fq "033[?25h" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "install -d -m 700" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q 'chmod 600 "$LOG_FILE"' "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "refusing to write bootstrap log through symlink" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "BOOTSTRAP_ACTIVE_PID" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "gitleaks archive checksum verified" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "gitleaks_8.21.2_checksums.txt" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "acl" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "BWRAP_PROFILE=/etc/apparmor.d/fieldwork-bwrap" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "AppArmor bwrap profile installed" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q 'apparmor_parser -r "$BWRAP_PROFILE"' "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "lib/apparmor/fieldwork-bwrap" "$ROOT/bin/fieldwork"
grep -q "lib/apparmor/fieldwork-bwrap" "$ROOT/tests/static-checks.sh"
grep -q "Fieldwork bwrap AppArmor profile" "$ROOT/lib/cli/uninstall.sh"
grep -q "/etc/apparmor.d/fieldwork-bwrap" "$ROOT/lib/cli/uninstall.sh"
grep -q 'install -d -m 755 "$HOME/projects"' "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "Firewall defaults and private network rules applied" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "Full log saved" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "ok \"bootstrap complete\"" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "Run fieldwork setup again" "$ROOT/lib/systemd/bootstrap-vps.sh"
grep -q "FIELDWORK_SETUP_CONTEXT" "$ROOT/lib/systemd/bootstrap-vps.sh"
if grep -R "apparmor_restrict_unprivileged_userns=0" "$ROOT/bin" "$ROOT/lib" "$ROOT/docs" >/dev/null; then
  echo "must not globally relax AppArmor unprivileged-userns restriction" >&2
  exit 1
fi
if grep -R "sysctl -w kernel.unprivileged_userns_clone=1" "$ROOT/bin" "$ROOT/lib" "$ROOT/docs" >/dev/null; then
  echo "must not prescribe global userns sysctl relaxation" >&2
  exit 1
fi
if grep -Eq "nvm|fnm" "$ROOT/lib/systemd/bootstrap-vps.sh"; then
  echo "bootstrap must install a system-visible Node runtime, not shell-profile-only Node managers" >&2
  exit 1
fi
if grep -q "systemd-run" "$ROOT/lib/scripts/fieldwork-verify-pipeline"; then
  echo "verify pipeline must not include a systemd-run runtime fallback" >&2
  exit 1
fi
if grep -q "ufw --force reset" "$ROOT/lib/systemd/bootstrap-vps.sh"; then
  echo "bootstrap should not reset ufw and re-open removed public SSH rules" >&2
  exit 1
fi
if grep -q "printf '\\\\b" "$ROOT/lib/systemd/bootstrap-vps.sh" "$ROOT/bin/fieldwork"; then
  echo "terminal progress should not use backspace spinners" >&2
  exit 1
fi
if grep -q "tput colors" "$ROOT/lib/systemd/bootstrap-vps.sh" "$ROOT/bin/fieldwork" "$ROOT/install.sh" "$ROOT/lib/scripts/fieldwork-onboard"; then
  echo "interactive checkmark color should not depend on tput" >&2
  exit 1
fi
grep -q 'FIELDWORK_UI_COLOR=0' "$ROOT/bin/fieldwork"
grep -q 'use_color()' "$ROOT/bin/fieldwork"
grep -q '\[ "$FIELDWORK_UI_COLOR" = "1" \]' "$ROOT/bin/fieldwork"
grep -q 'yellow()' "$ROOT/bin/fieldwork"
grep -q 'blue()' "$ROOT/bin/fieldwork"
grep -q 'red()' "$ROOT/bin/fieldwork"
grep -q 'cyan()' "$ROOT/bin/fieldwork"
grep -q 'bold()' "$ROOT/bin/fieldwork"
grep -q 'doctor_row ok' "$ROOT/bin/fieldwork"
grep -q 'doctor_row needs' "$ROOT/bin/fieldwork"
grep -q 'setup_status_line needs "remote Fieldwork is not installed"' "$ROOT/lib/cli/setup.sh"
grep -q 'openssl rand -hex 16' "$ROOT/lib/cli/setup.sh"
grep -q 'Skipped for now; setup will keep this as a manual action' "$ROOT/lib/cli/setup.sh"
grep -q "http://localhost/preflight" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "missing required field: request_id" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q -- "--prepare-deploy-key" "$ROOT/lib/scripts/fieldwork-clone"
grep -q -- "--clone-after-deploy-key" "$ROOT/lib/scripts/fieldwork-clone"
grep -q "grant_broker_read_access()" "$ROOT/lib/scripts/fieldwork-clone"
grep -q "setfacl -R -m" "$ROOT/lib/scripts/fieldwork-clone"
grep -q -- "--prepare-deploy-key" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q -- "--clone-after-deploy-key" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "grant_broker_checkout_read_access()" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "broker can read checkout" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "Open now" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "Mark .* complete" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "manual_step_marker_exists" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "remote_service_active" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "Claude may take a moment to draw its UI" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q -- "--name 'vps-\$SLUG' --remote-control-session-name-prefix 'vps-\$SLUG' --sandbox --spawn=worktree --capacity=2" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX" "$ROOT/lib/agents/claude-remote-control"
grep -q -- "--remote-control-session-name-prefix" "$ROOT/lib/agents/claude-remote-control"
grep -q 'FIELDWORK_AGENT_CAPACITY_DEFAULT=2' "$ROOT/lib/scripts/fieldwork-agent-session"
grep -q 'FIELDWORK_AGENT_CAPACITY_MAX=4' "$ROOT/lib/scripts/fieldwork-agent-session"
grep -q 'FIELDWORK_AGENT_CAPACITY' "$ROOT/lib/agents/claude-remote-control"
if grep -q "pick 2 for worktree" "$ROOT/lib/scripts/fieldwork-onboard"; then
  echo "remote-control consent should preselect worktree mode instead of asking users to choose 2" >&2
  exit 1
fi
grep -q 'phase_section "Onboarding Complete"' "$ROOT/lib/scripts/fieldwork-onboard"
grep -q 'phase_section "After Merge"' "$ROOT/lib/scripts/fieldwork-onboard"
grep -q 'phase_section "Work Session Ready"' "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "Fieldwork prepared both agent surfaces for this repo" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "Open Claude mobile or claude.ai/code" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "Session: vps-\$SLUG" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "SSH host: \$SSH_HOST" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "Repo: \$REMOTE_REPO_DIR" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q 'Available from signed-in devices' "$ROOT/lib/scripts/fieldwork-onboard"
grep -q 'Open \$REMOTE_REPO_DIR on mobile or desktop and start building' "$ROOT/lib/scripts/fieldwork-onboard"
grep -q 'VPS SSH connection' "$ROOT/lib/scripts/fieldwork-onboard"
grep -q 'server display name' "$ROOT/lib/scripts/fieldwork-onboard"
grep -q "Important: Do not use Claude and Codex concurrently in the same checkout" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q 'Available from signed-in devices' "$ROOT/bin/fieldwork"
grep -q 'Open \$FIELDWORK_PROJECTS_DIR/\$slug on mobile or desktop and start building' "$ROOT/bin/fieldwork"
grep -q 'VPS SSH connection' "$ROOT/bin/fieldwork"
grep -q 'server display name' "$ROOT/bin/fieldwork"
grep -q 'Available from signed-in devices' "$ROOT/docs/quickstart.md"
grep -q 'configured VPS SSH' "$ROOT/docs/quickstart.md"
grep -q 'may display as the server name' "$ROOT/docs/quickstart.md"
grep -q "fieldwork quickstart <owner>/<repo>" "$ROOT/docs/quickstart.md"
grep -q "fieldwork quickstart" "$ROOT/docs/cli-reference.md"
if grep -q 'phase_section "Manual checkpoints"' "$ROOT/lib/scripts/fieldwork-onboard"; then
  echo "onboard should not dump a separate manual-checkpoints phase" >&2
  exit 1
fi
if grep -q "~/.fieldwork/scripts/fieldwork-clone '\$OWNER_REPO'" "$ROOT/lib/scripts/fieldwork-onboard"; then
  echo "onboard should use quiet fieldwork-clone orchestration subcommands" >&2
  exit 1
fi
grep -q "broker sockets reopened" "$ROOT/lib/broker/install.sh"
grep -q "resolve_socket_group_for_display()" "$ROOT/lib/broker/install.sh"
grep -q "systemctl stop fieldwork-pr-broker.service fieldwork-pr-broker.socket fieldwork-pr-approve.socket" "$ROOT/lib/broker/install.sh"
grep -q 'install -o "$AGENT_USER" -g "$AGENT_USER" -m 755 -d "$PROJECTS_ROOT"' "$ROOT/lib/broker/install.sh"
grep -q 'setfacl -m "u:$AGENT_USER:--x" "$STATE_DIR"' "$ROOT/lib/broker/install.sh"
grep -q 'setfacl -m "u:$AGENT_USER:r--" "$audit_path"' "$ROOT/lib/broker/install.sh"
grep -q 'setfacl -m "u:$BROKER_USER:rwx" "$STATE_DIR/notifications"' "$ROOT/lib/broker/install.sh"
grep -q "def preflight" "$ROOT/lib/broker/server.py"
grep -q "FIELDWORK_FORGE" "$ROOT/lib/broker/server.py"
grep -q "FIELDWORK_GITHUB_CREDENTIAL_MODE" "$ROOT/lib/broker/server.py"
grep -q "FIELDWORK_GITHUB_APP_PRIVATE_KEY_PATH" "$ROOT/lib/broker/server.py"
grep -q "class AppCredentialProvider" "$ROOT/lib/broker/server.py"
grep -q "class CredentialProvider" "$ROOT/lib/broker/server.py"
grep -q "class PatCredentialProvider" "$ROOT/lib/broker/server.py"
grep -q "class ForgeBackend" "$ROOT/lib/broker/server.py"
grep -q "class GitHubBackend" "$ROOT/lib/broker/server.py"
grep -q "github_credential_provider" "$ROOT/lib/broker/server.py"
grep -q "write_request_token_file" "$ROOT/lib/broker/server.py"
grep -q "FIELDWORK_BROKER_TOKEN_PATH" "$ROOT/lib/broker/git-askpass"
grep -q "EnvironmentFile=-/etc/fieldwork-pr-broker/credential.env" "$ROOT/lib/broker/fieldwork-pr-broker.service"
grep -q "FIELDWORK_GITHUB_CREDENTIAL_MODE" "$ROOT/lib/broker/rotate-pat"
grep -q "github-app-private-key.pem" "$ROOT/lib/broker/rotate-pat"
grep -q "GitHub App private key" "$ROOT/lib/cli/verify-security.sh"
grep -q "GIT_CONFIG_KEY_0.*safe.directory" "$ROOT/lib/broker/server.py"
grep -q "GIT_CONFIG_KEY_1.*core.hooksPath" "$ROOT/lib/broker/server.py"
grep -q '"push", "--no-verify"' "$ROOT/lib/broker/server.py"
grep -q "broker cannot read repo checkout" "$ROOT/lib/broker/server.py"
grep -q "FIELDWORK_GITHUB_CREDENTIAL_MODE=pat" "$ROOT/docs/broker-standalone.md"
grep -q "FIELDWORK_GITHUB_CREDENTIAL_MODE=app" "$ROOT/docs/broker-standalone.md"
grep -q "one-hour installation tokens" "$ROOT/docs/broker-standalone.md"
grep -q "The credential provider chooses the GitHub token source" "$ROOT/docs/threat-model.md"
grep -q "FIELDWORK_GITHUB_CREDENTIAL_MODE=app" "$ROOT/docs/setup.md"
if grep -v '^[[:space:]]*#' "$ROOT/lib/scripts/fieldwork-onboard" | grep -Eq 'sudo([[:space:]]+-[^[:space:]]+)*[[:space:]]+-u[[:space:]]+fieldwork-pr-broker'; then
  echo "onboard must not require sudo to impersonate the broker after setup hardening" >&2
  exit 1
fi
if grep -v '^[[:space:]]*#' "$ROOT/lib/scripts/fieldwork-init" | grep -Eq '(^|[;&|[:space:]])sudo([[:space:]]|$)'; then
  echo "fieldwork-init must not require sudo during post-hardening onboarding" >&2
  exit 1
fi

echo "[checks] verify-security help"
"$ROOT/bin/fieldwork" verify-security --help >${TMPDIR:-/tmp}/fieldwork-verify-security-help.out
grep -q "usage: fieldwork verify-security" ${TMPDIR:-/tmp}/fieldwork-verify-security-help.out
grep -q -- "--remote" ${TMPDIR:-/tmp}/fieldwork-verify-security-help.out
"$ROOT/bin/fieldwork" verify-security --remote --help >${TMPDIR:-/tmp}/fieldwork-verify-security-remote-help.out
grep -q "usage: fieldwork verify-security" ${TMPDIR:-/tmp}/fieldwork-verify-security-remote-help.out

echo "[checks] report help"
"$ROOT/bin/fieldwork" report --help >${TMPDIR:-/tmp}/fieldwork-report-help.out
grep -q "usage: fieldwork report" ${TMPDIR:-/tmp}/fieldwork-report-help.out
grep -q "secret-redacted" ${TMPDIR:-/tmp}/fieldwork-report-help.out

echo "[checks] smoke help"
"$ROOT/bin/fieldwork" smoke --help >${TMPDIR:-/tmp}/fieldwork-smoke-help.out
grep -q "usage: fieldwork smoke" ${TMPDIR:-/tmp}/fieldwork-smoke-help.out
grep -q "does not use Claude" ${TMPDIR:-/tmp}/fieldwork-smoke-help.out

"$ROOT/bin/fieldwork" refresh --help >${TMPDIR:-/tmp}/fieldwork-refresh-help.out
grep -q "usage: fieldwork refresh <repo-slug>" ${TMPDIR:-/tmp}/fieldwork-refresh-help.out
grep -q "Refresh the VPS checkout after a PR merges" ${TMPDIR:-/tmp}/fieldwork-refresh-help.out

"$ROOT/bin/fieldwork" start --help >${TMPDIR:-/tmp}/fieldwork-start-help.out
grep -q "usage: fieldwork start" ${TMPDIR:-/tmp}/fieldwork-start-help.out
"$ROOT/bin/fieldwork" status --help >${TMPDIR:-/tmp}/fieldwork-status-help.out
grep -q "usage: fieldwork status" ${TMPDIR:-/tmp}/fieldwork-status-help.out
grep -Fq 'phase_section "Codex status (verbose)"' "$ROOT/bin/fieldwork"
if grep -Fq "no Fieldwork systemd service exists for Codex" "$ROOT/bin/fieldwork"; then
  echo "Codex-only status --verbose must show readiness probes, not return early" >&2
  exit 1
fi
"$ROOT/bin/fieldwork" bot-status --help >${TMPDIR:-/tmp}/fieldwork-bot-status-help.out
grep -q "usage: fieldwork bot-status" ${TMPDIR:-/tmp}/fieldwork-bot-status-help.out
grep -q "Telegram approval bot pipeline" ${TMPDIR:-/tmp}/fieldwork-bot-status-help.out
"$ROOT/bin/fieldwork" --help | grep -q "bot-status"
"$ROOT/bin/fieldwork" eval up --help >${TMPDIR:-/tmp}/fieldwork-eval-up-help.out
grep -q "usage: fieldwork eval up" ${TMPDIR:-/tmp}/fieldwork-eval-up-help.out
"$ROOT/bin/fieldwork" eval down --help >${TMPDIR:-/tmp}/fieldwork-eval-down-help.out
grep -q "usage: fieldwork eval down" ${TMPDIR:-/tmp}/fieldwork-eval-down-help.out
"$ROOT/bin/fieldwork" eval clean --help >${TMPDIR:-/tmp}/fieldwork-eval-clean-help.out
grep -q "usage: fieldwork eval clean" ${TMPDIR:-/tmp}/fieldwork-eval-clean-help.out
"$ROOT/bin/fieldwork" adapter list --help >${TMPDIR:-/tmp}/fieldwork-adapter-list-help.out
grep -q "usage: fieldwork adapter list" ${TMPDIR:-/tmp}/fieldwork-adapter-list-help.out
"$ROOT/bin/fieldwork" adapter doctor --help >${TMPDIR:-/tmp}/fieldwork-adapter-doctor-help.out
grep -q "usage: fieldwork adapter doctor" ${TMPDIR:-/tmp}/fieldwork-adapter-doctor-help.out
"$ROOT/bin/fieldwork" bootstrap-vps --verbose --print-path >${TMPDIR:-/tmp}/fieldwork-bootstrap-print-path.out
grep -q "lib/systemd/bootstrap-vps.sh" ${TMPDIR:-/tmp}/fieldwork-bootstrap-print-path.out
"$ROOT/bin/fieldwork" install-broker --verbose --print-path >${TMPDIR:-/tmp}/fieldwork-install-broker-print-path.out
grep -q "lib/broker/install.sh" ${TMPDIR:-/tmp}/fieldwork-install-broker-print-path.out

echo "[checks] refresh command uses safe VPS update flow"
fake_refresh_bin="$(mktemp_dir)"
cat > "$fake_refresh_bin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" > "$FIELDWORK_FAKE_REFRESH_LOG"
case "$*" in
  *"cat ~/.fieldwork/agents"*) printf 'claude\n'; exit 0 ;;
  *"fake-vps bash -s -- /home/fieldwork/projects/whichonetho whichonetho main claude"*)
    script="$(cat)"
    printf '%s\n' "$script" > "$FIELDWORK_FAKE_REFRESH_SCRIPT"
    exit 0
    ;;
  *)
    echo "unexpected fake refresh ssh command: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$fake_refresh_bin/ssh"
FIELDWORK_FAKE_REFRESH_LOG="$fake_refresh_bin/ssh.log" \
FIELDWORK_FAKE_REFRESH_SCRIPT="$fake_refresh_bin/remote-script.sh" \
FIELDWORK_SSH_HOST=fake-vps \
PATH="$fake_refresh_bin:$PATH" \
  "$ROOT/bin/fieldwork" refresh whichonetho >${TMPDIR:-/tmp}/fieldwork-refresh.out
grep -q "^Refresh VPS checkout$" ${TMPDIR:-/tmp}/fieldwork-refresh.out
grep -q "VPS checkout refreshed and Claude session restarted" ${TMPDIR:-/tmp}/fieldwork-refresh.out
grep -q "open Claude mobile and use session vps-whichonetho" ${TMPDIR:-/tmp}/fieldwork-refresh.out
grep -q "older manually named sessions are unmanaged consent runs" ${TMPDIR:-/tmp}/fieldwork-refresh.out
grep -q "git status --short" "$fake_refresh_bin/remote-script.sh"
grep -q "checkout has uncommitted changes" "$fake_refresh_bin/remote-script.sh"
grep -q ".fieldwork/expected-origin" "$fake_refresh_bin/remote-script.sh"
grep -q ".fieldwork/default-branch" "$fake_refresh_bin/remote-script.sh"
grep -q "git fetch --prune origin" "$fake_refresh_bin/remote-script.sh"
grep -q 'git checkout "$default_branch"' "$fake_refresh_bin/remote-script.sh"
grep -q 'git pull --ff-only origin "$default_branch" || git pull --ff-only' "$fake_refresh_bin/remote-script.sh"
grep -q 'systemctl --user stop "fieldwork-agent@$slug" || true' "$fake_refresh_bin/remote-script.sh"
grep -q "bridge-pointer.json" "$fake_refresh_bin/remote-script.sh"
grep -q "fieldwork-refresh-" "$fake_refresh_bin/remote-script.sh"
grep -q 'systemctl --user start "fieldwork-agent@$slug"' "$fake_refresh_bin/remote-script.sh"
grep -q 'systemctl --user is-active --quiet "fieldwork-agent@$slug"' "$fake_refresh_bin/remote-script.sh"

fake_refresh_codex_bin="$(mktemp_dir)"
cat > "$fake_refresh_codex_bin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" > "$FIELDWORK_FAKE_REFRESH_CODEX_LOG"
case "$*" in
  *"cat ~/.fieldwork/agents"*) printf 'codex\n'; exit 0 ;;
  *"fake-vps bash -s -- /home/fieldwork/projects/codexthing codexthing main codex"*)
    script="$(cat)"
    printf '%s\n' "$script" > "$FIELDWORK_FAKE_REFRESH_CODEX_SCRIPT"
    exit 0
    ;;
  *)
    echo "unexpected fake refresh codex ssh command: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$fake_refresh_codex_bin/ssh"
FIELDWORK_FAKE_REFRESH_CODEX_LOG="$fake_refresh_codex_bin/ssh.log" \
FIELDWORK_FAKE_REFRESH_CODEX_SCRIPT="$fake_refresh_codex_bin/remote-script.sh" \
FIELDWORK_SSH_HOST=fake-vps \
PATH="$fake_refresh_codex_bin:$PATH" \
  "$ROOT/bin/fieldwork" refresh codexthing >${TMPDIR:-/tmp}/fieldwork-refresh-codex.out
grep -q "^Refresh VPS checkout$" ${TMPDIR:-/tmp}/fieldwork-refresh-codex.out
grep -q "VPS checkout refreshed" ${TMPDIR:-/tmp}/fieldwork-refresh-codex.out
grep -q "open or continue /home/fieldwork/projects/codexthing in Codex Desktop or mobile" ${TMPDIR:-/tmp}/fieldwork-refresh-codex.out
if grep -Eq "Codex Desktop connection is not managed by Fieldwork|no Fieldwork Codex service was restarted" ${TMPDIR:-/tmp}/fieldwork-refresh-codex.out; then
  echo "Codex-only refresh should describe checkout sync, not absent service restarts" >&2
  exit 1
fi
grep -q "fieldwork refresh <slug>" "$ROOT/docs/quickstart.md"
grep -q "fieldwork refresh <slug>" "$ROOT/docs/setup.md"
grep -q "fieldwork refresh <slug>" "$ROOT/docs/runbook.md"
grep -q 'fieldwork refresh $SLUG' "$ROOT/lib/scripts/fieldwork-onboard"

echo "[checks] invalid setup/sync args reject"
if "$ROOT/bin/fieldwork" quickstart --wat >${TMPDIR:-/tmp}/fieldwork-invalid-quickstart.out 2>&1; then
  echo "invalid quickstart argument unexpectedly succeeded" >&2
  exit 1
fi
grep -q "unknown quickstart argument" ${TMPDIR:-/tmp}/fieldwork-invalid-quickstart.out
if "$ROOT/bin/fieldwork" setup --wat >${TMPDIR:-/tmp}/fieldwork-invalid-setup.out 2>&1; then
  echo "invalid setup argument unexpectedly succeeded" >&2
  exit 1
fi
grep -q "unknown setup argument" ${TMPDIR:-/tmp}/fieldwork-invalid-setup.out
if "$ROOT/bin/fieldwork" sync-vps --wat >${TMPDIR:-/tmp}/fieldwork-invalid-sync.out 2>&1; then
  echo "invalid sync-vps argument unexpectedly succeeded" >&2
  exit 1
fi
grep -q "unknown sync-vps argument" ${TMPDIR:-/tmp}/fieldwork-invalid-sync.out
if "$ROOT/bin/fieldwork" doctor --wat >${TMPDIR:-/tmp}/fieldwork-invalid-doctor.out 2>&1; then
  echo "invalid doctor argument unexpectedly succeeded" >&2
  exit 1
fi
grep -q "unknown doctor argument" ${TMPDIR:-/tmp}/fieldwork-invalid-doctor.out
if "$ROOT/bin/fieldwork" verify-security --wat >${TMPDIR:-/tmp}/fieldwork-invalid-verify-security.out 2>&1; then
  echo "invalid verify-security argument unexpectedly succeeded" >&2
  exit 1
fi
grep -q "unknown verify-security argument" ${TMPDIR:-/tmp}/fieldwork-invalid-verify-security.out
if "$ROOT/bin/fieldwork" report --wat >${TMPDIR:-/tmp}/fieldwork-invalid-report.out 2>&1; then
  echo "invalid report argument unexpectedly succeeded" >&2
  exit 1
fi
grep -q "unknown report argument" ${TMPDIR:-/tmp}/fieldwork-invalid-report.out
if "$ROOT/bin/fieldwork" smoke owner/repo --wat >${TMPDIR:-/tmp}/fieldwork-invalid-smoke.out 2>&1; then
  echo "invalid smoke argument unexpectedly succeeded" >&2
  exit 1
fi
grep -q "unknown smoke argument" ${TMPDIR:-/tmp}/fieldwork-invalid-smoke.out
if "$ROOT/bin/fieldwork" onboard owner/repo --wat >${TMPDIR:-/tmp}/fieldwork-invalid-onboard.out 2>&1; then
  echo "invalid onboard argument unexpectedly succeeded" >&2
  exit 1
fi
grep -q "unknown flag" ${TMPDIR:-/tmp}/fieldwork-invalid-onboard.out
if "$ROOT/bin/fieldwork" onboard owner/repo owner/other --status >${TMPDIR:-/tmp}/fieldwork-invalid-onboard-paths.out 2>&1; then
  echo "onboard accepted multiple repo arguments" >&2
  exit 1
fi
grep -q "fieldwork onboard accepts exactly one" ${TMPDIR:-/tmp}/fieldwork-invalid-onboard-paths.out
if "$ROOT/bin/fieldwork" eval up --wat >${TMPDIR:-/tmp}/fieldwork-invalid-eval-up.out 2>&1; then
  echo "eval up accepted an unknown argument" >&2
  exit 1
fi
grep -q "unknown eval up argument" ${TMPDIR:-/tmp}/fieldwork-invalid-eval-up.out
if "$ROOT/bin/fieldwork" eval down stray >${TMPDIR:-/tmp}/fieldwork-invalid-eval-down.out 2>&1; then
  echo "eval down accepted a positional argument" >&2
  exit 1
fi
grep -q "fieldwork eval down accepts no positional" ${TMPDIR:-/tmp}/fieldwork-invalid-eval-down.out
if "$ROOT/bin/fieldwork" eval clean --wat >${TMPDIR:-/tmp}/fieldwork-invalid-eval-clean.out 2>&1; then
  echo "eval clean accepted an unknown argument" >&2
  exit 1
fi
grep -q "unknown eval clean argument" ${TMPDIR:-/tmp}/fieldwork-invalid-eval-clean.out
if "$ROOT/bin/fieldwork" adapter list stray >${TMPDIR:-/tmp}/fieldwork-invalid-adapter-list.out 2>&1; then
  echo "adapter list accepted a positional argument" >&2
  exit 1
fi
grep -q "fieldwork adapter list accepts no positional" ${TMPDIR:-/tmp}/fieldwork-invalid-adapter-list.out
if "$ROOT/bin/fieldwork" adapter doctor claude-remote-control stray >${TMPDIR:-/tmp}/fieldwork-invalid-adapter-doctor.out 2>&1; then
  echo "adapter doctor accepted multiple adapter arguments" >&2
  exit 1
fi
grep -q "fieldwork adapter doctor accepts at most one" ${TMPDIR:-/tmp}/fieldwork-invalid-adapter-doctor.out
if "$ROOT/bin/fieldwork" bootstrap-vps --print-path --wat >${TMPDIR:-/tmp}/fieldwork-invalid-bootstrap-print-path.out 2>&1; then
  echo "bootstrap-vps --print-path accepted an unknown trailing argument" >&2
  exit 1
fi
grep -q "unknown bootstrap-vps argument" ${TMPDIR:-/tmp}/fieldwork-invalid-bootstrap-print-path.out
if "$ROOT/bin/fieldwork" install-broker --print-path --wat >${TMPDIR:-/tmp}/fieldwork-invalid-install-broker-print-path.out 2>&1; then
  echo "install-broker --print-path accepted an unknown trailing argument" >&2
  exit 1
fi
grep -q "unknown install-broker argument" ${TMPDIR:-/tmp}/fieldwork-invalid-install-broker-print-path.out
if "$ROOT/bin/fieldwork" status --verbose >${TMPDIR:-/tmp}/fieldwork-invalid-status-verbose.out 2>&1; then
  echo "status --verbose without a slug unexpectedly succeeded" >&2
  exit 1
fi
grep -q "status --verbose requires a repo slug" ${TMPDIR:-/tmp}/fieldwork-invalid-status-verbose.out
if "$ROOT/bin/fieldwork" setup-notify --telegram-bot --topic fieldwork-topic >${TMPDIR:-/tmp}/fieldwork-invalid-telegram-ntfy-mix.out 2>&1; then
  echo "setup-notify mixed Telegram and ntfy flags" >&2
  exit 1
fi
grep -q "setup-notify --telegram-bot accepts only --yes" ${TMPDIR:-/tmp}/fieldwork-invalid-telegram-ntfy-mix.out

echo "[checks] unsafe config rejects before remote commands"
bad_config_dir="$(mktemp_dir)"
cat > "$bad_config_dir/fieldwork.toml" <<'EOF'
projects_dir = "/home/fieldwork/projects;bad"
EOF
if FIELDWORK_CONFIG="$bad_config_dir/fieldwork.toml" "$ROOT/bin/fieldwork" report >${TMPDIR:-/tmp}/fieldwork-invalid-config.out 2>&1; then
  echo "invalid projects_dir unexpectedly succeeded" >&2
  exit 1
fi
grep -q "invalid projects_dir" ${TMPDIR:-/tmp}/fieldwork-invalid-config.out
FIELDWORK_CONFIG="$bad_config_dir/fieldwork.toml" "$ROOT/bin/fieldwork" --help >${TMPDIR:-/tmp}/fieldwork-invalid-config-help.out
grep -q "setup .*install and configure Fieldwork locally" ${TMPDIR:-/tmp}/fieldwork-invalid-config-help.out
FIELDWORK_CONFIG="$bad_config_dir/fieldwork.toml" "$ROOT/bin/fieldwork" verify-security --remote --help >${TMPDIR:-/tmp}/fieldwork-invalid-config-verify-help.out
grep -q "usage: fieldwork verify-security" ${TMPDIR:-/tmp}/fieldwork-invalid-config-verify-help.out
FIELDWORK_CONFIG="$bad_config_dir/fieldwork.toml" "$ROOT/bin/fieldwork" eval up --help >${TMPDIR:-/tmp}/fieldwork-invalid-config-eval-help.out
grep -q "usage: fieldwork eval up" ${TMPDIR:-/tmp}/fieldwork-invalid-config-eval-help.out

echo "[checks] verify-security catches temporary passwordless sudo"
fake_sudoers_bin="$(mktemp_dir)"
cat > "$fake_sudoers_bin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"fieldwork-vps true"*) exit 0 ;;
  *"test -f '/etc/sudoers.d/fieldwork-fieldwork'"*) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_sudoers_bin/ssh"
if PATH="$fake_sudoers_bin:$PATH" "$ROOT/bin/fieldwork" verify-security >${TMPDIR:-/tmp}/fieldwork-verify-sudoers.out 2>&1; then
  echo "verify-security unexpectedly passed with temporary passwordless sudo present" >&2
  exit 1
fi
grep -q "temporary passwordless sudo is still enabled" ${TMPDIR:-/tmp}/fieldwork-verify-sudoers.out

echo "[checks] verify-security accepts default agent-primary broker socket group"
fake_verify_socket_bin="$(mktemp_dir)"
cat > "$fake_verify_socket_bin/ssh" <<'SH'
#!/usr/bin/env bash
socket_group="${FIELDWORK_FAKE_SOCKET_GROUP:-fieldwork}"
socket_unit_group="${FIELDWORK_FAKE_SOCKET_UNIT_GROUP:-}"
case "$*" in
  *"fieldwork-vps true"*) exit 0 ;;
  *"test -f '/etc/sudoers.d/fieldwork-fieldwork'"*) exit 1 ;;
  *"stat -c '%U:%G %a' /etc/fieldwork-pr-broker/gh-token"*) printf '%s\n' "fieldwork-pr-broker:fieldwork-pr-broker 600" ;;
  *"test ! -r /etc/fieldwork-pr-broker/gh-token"*) exit 0 ;;
  *"id -gn 'fieldwork'"*) printf '%s\n' "fieldwork" ;;
  *"sed -n 's/^SocketGroup=//p' /etc/systemd/system/fieldwork-pr-broker.socket"*) [ -n "$socket_unit_group" ] && printf '%s\n' "$socket_unit_group" ;;
  *"stat -c '%U:%G %a' /run/fieldwork-pr-broker/fieldwork-pr.sock"*) printf 'fieldwork-pr-broker:%s 660\n' "$socket_group" ;;
  *"test -w /run/fieldwork-pr-broker/fieldwork-pr.sock"*) exit 0 ;;
  *"stat -c '%U:%G %a' /var/lib/fieldwork-pr-broker/requests"*) printf '%s\n' "fieldwork-pr-broker:fieldwork-pr-broker 700" ;;
  *"systemctl cat fieldwork-pr-broker.service"*) exit 0 ;;
  *"test -f /etc/systemd/system/fieldwork-bot.service"*) exit 1 ;;
  *"sudo -n ufw status"*) printf '%s\n' "Status: inactive" ;;
  *"notify\\.env|NTFY_TOPIC|TG_BOT_TOKEN"*) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_verify_socket_bin/ssh"
PATH="$fake_verify_socket_bin:$PATH" "$ROOT/bin/fieldwork" verify-security >${TMPDIR:-/tmp}/fieldwork-verify-primary-socket.out
grep -q "broker socket owner/mode is fieldwork-pr-broker:fieldwork 660" ${TMPDIR:-/tmp}/fieldwork-verify-primary-socket.out
FIELDWORK_FAKE_SOCKET_GROUP=pr-submitters FIELDWORK_FAKE_SOCKET_UNIT_GROUP=pr-submitters PATH="$fake_verify_socket_bin:$PATH" \
  "$ROOT/bin/fieldwork" verify-security >${TMPDIR:-/tmp}/fieldwork-verify-custom-socket.out
grep -q "broker socket owner/mode is fieldwork-pr-broker:pr-submitters 660" ${TMPDIR:-/tmp}/fieldwork-verify-custom-socket.out
grep -q "custom groups must remain visible inside the agent sandbox" ${TMPDIR:-/tmp}/fieldwork-verify-custom-socket.out

echo "[checks] verify-security accepts GitHub App credential mode"
fake_verify_app_bin="$(mktemp_dir)"
cat > "$fake_verify_app_bin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"fieldwork-vps true"*) exit 0 ;;
  *"test -f '/etc/sudoers.d/fieldwork-fieldwork'"*) exit 1 ;;
  *"FIELDWORK_GITHUB_CREDENTIAL_MODE"*) printf '%s' "app" ;;
  *"FIELDWORK_GITHUB_APP_PRIVATE_KEY_PATH"*) printf '%s' "/etc/fieldwork-pr-broker/github-app-private-key.pem" ;;
  *"stat -c '%U:%G %a'"*"github-app-private-key.pem"*) printf '%s\n' "fieldwork-pr-broker:fieldwork-pr-broker 600" ;;
  *"test ! -r"*"github-app-private-key.pem"*) exit 0 ;;
  *"test ! -e /etc/fieldwork-pr-broker/gh-token || test ! -r /etc/fieldwork-pr-broker/gh-token"*) exit 0 ;;
  *"id -gn 'fieldwork'"*) printf '%s\n' "fieldwork" ;;
  *"sed -n 's/^SocketGroup=//p' /etc/systemd/system/fieldwork-pr-broker.socket"*) exit 0 ;;
  *"stat -c '%U:%G %a' /run/fieldwork-pr-broker/fieldwork-pr.sock"*) printf '%s\n' "fieldwork-pr-broker:fieldwork 660" ;;
  *"test -w /run/fieldwork-pr-broker/fieldwork-pr.sock"*) exit 0 ;;
  *"stat -c '%U:%G %a' /var/lib/fieldwork-pr-broker/requests"*) printf '%s\n' "fieldwork-pr-broker:fieldwork-pr-broker 700" ;;
  *"systemctl cat fieldwork-pr-broker.service"*) exit 0 ;;
  *"test -f /etc/systemd/system/fieldwork-bot.service"*) exit 1 ;;
  *"sudo -n ufw status"*) printf '%s\n' "Status: inactive" ;;
  *"notify\\.env|NTFY_TOPIC|TG_BOT_TOKEN"*) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$fake_verify_app_bin/ssh"
PATH="$fake_verify_app_bin:$PATH" "$ROOT/bin/fieldwork" verify-security >${TMPDIR:-/tmp}/fieldwork-verify-app-mode.out
grep -q "broker credential mode is GitHub App" ${TMPDIR:-/tmp}/fieldwork-verify-app-mode.out
grep -q "GitHub App private key owner/mode is fieldwork-pr-broker:fieldwork-pr-broker 600" ${TMPDIR:-/tmp}/fieldwork-verify-app-mode.out
grep -q "stale broker PAT is absent or unreadable by the agent" ${TMPDIR:-/tmp}/fieldwork-verify-app-mode.out

echo "[checks] verify-security UFW filter recognises public vs private 22/tcp rules"
ufw_filter() {
  grep -Ei '^[[:space:]]*22/tcp[[:space:]]+ALLOW' \
    | grep -Eiv '(on[[:space:]]+(tailscale|wg|tun)[0-9]*|(^|[^0-9.])(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.))'
}
printf '22/tcp                     ALLOW       Anywhere\n' | ufw_filter | grep -q . || { echo "ufw filter missed public Anywhere"; exit 1; }
printf '22/tcp on tailscale0       ALLOW       Anywhere\n' | ufw_filter | grep -q . && { echo "ufw filter let tailscale0 through"; exit 1; } || true
printf '22/tcp on wg0              ALLOW       Anywhere\n' | ufw_filter | grep -q . && { echo "ufw filter let wg0 through"; exit 1; } || true
printf '22/tcp on tun0             ALLOW       Anywhere\n' | ufw_filter | grep -q . && { echo "ufw filter let tun0 through"; exit 1; } || true
printf '22/tcp                     ALLOW       10.0.0.0/24\n' | ufw_filter | grep -q . && { echo "ufw filter let RFC1918 10.x through"; exit 1; } || true
printf '22/tcp                     ALLOW       192.168.1.0/24\n' | ufw_filter | grep -q . && { echo "ufw filter let 192.168 through"; exit 1; } || true
printf '22/tcp                     ALLOW       172.20.0.0/16\n' | ufw_filter | grep -q . && { echo "ufw filter let 172.16-31 through"; exit 1; } || true
printf '22/tcp                     ALLOW       100.64.0.0/10\n' | ufw_filter | grep -q . && { echo "ufw filter let CGNAT through"; exit 1; } || true
printf '22/tcp                     ALLOW       100.127.0.1\n'    | ufw_filter | grep -q . && { echo "ufw filter let CGNAT high through"; exit 1; } || true
printf '22/tcp                     ALLOW       110.20.30.40\n'   | ufw_filter | grep -q . || { echo "ufw filter false-positive on 110.x"; exit 1; }
printf '22/tcp                     ALLOW       100.128.0.1\n'    | ufw_filter | grep -q . || { echo "ufw filter false-positive on 100.128.x"; exit 1; }
unset -f ufw_filter

echo "[checks] report with fake ssh is redacted and non-mutating"
fake_report_bin="$(mktemp_dir)"
cat > "$fake_report_bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_REPORT_SSH_LOG"
if [ "${1:-}" = "-G" ]; then
  echo "hostname fake-vps"
  echo "user fieldwork"
  exit 0
fi
last=""
for arg in "$@"; do
  last="$arg"
done
case "$last" in
  true) exit 0 ;;
  *"command -v claude"*) exit 0 ;;
  *"command -v gh"*) exit 0 ;;
  *"gh auth status"*) exit 0 ;;
  *"test -d '/home/fieldwork/projects'"*) exit 0 ;;
  *"test -s ~/.fieldwork/notify.env"*) exit 0 ;;
  *"test -f ~/.config/systemd/user/fieldwork-agent@.service"*) exit 0 ;;
  *"test -S /run/fieldwork-pr-broker/fieldwork-pr.sock"*) exit 0 ;;
  *"test -d '/home/fieldwork/projects/fieldwork-smoke/.git'"*) exit 0 ;;
  *"test -f '/home/fieldwork/projects/fieldwork-smoke/.fieldwork/expected-origin'"*) exit 0 ;;
  *"git status --short"*) exit 0 ;;
  *"fieldwork-onboard-state.json"*)
    cat <<'JSON'
{
  "version": 1,
  "repo": "owner/fieldwork-smoke",
  "slug": "fieldwork-smoke",
  "branch": "fieldwork/init",
  "workflows_included": true,
  "completed_steps": ["preflight_passed", "init_pr_opened"],
  "updated_at": "2026-01-01T00:00:00Z"
}
JSON
    exit 0
    ;;
  *) echo "unexpected fake report ssh command: $last" >&2; exit 1 ;;
esac
SH
chmod +x "$fake_report_bin/ssh"
FIELDWORK_FAKE_REPORT_SSH_LOG="$fake_report_bin/ssh.log" FIELDWORK_SSH_HOST=fake-vps PATH="$fake_report_bin:$PATH" "$ROOT/bin/fieldwork" report fieldwork-smoke >${TMPDIR:-/tmp}/fieldwork-report.out
grep -q "^Fieldwork report" ${TMPDIR:-/tmp}/fieldwork-report.out
grep -q "Secrets: omitted" ${TMPDIR:-/tmp}/fieldwork-report.out
grep -q "resolved_host: fake-vps" ${TMPDIR:-/tmp}/fieldwork-report.out
grep -q "completed_steps: preflight_passed, init_pr_opened" ${TMPDIR:-/tmp}/fieldwork-report.out
grep -q "Next action:" ${TMPDIR:-/tmp}/fieldwork-report.out
if grep -Eq 'NTFY_TOPIC|GH_TOKEN|github_pat_|ghp_|gho_' ${TMPDIR:-/tmp}/fieldwork-report.out; then
  echo "fieldwork report printed secret-shaped output" >&2
  exit 1
fi
if grep -Eq 'fieldwork-pr-submit|git push|gh pr create|rotate-pat' "$fake_report_bin/ssh.log"; then
  echo "fieldwork report performed mutating-looking remote commands" >&2
  exit 1
fi

echo "[checks] smoke fake ssh/scp script generation"
fake_smoke_bin="$(mktemp_dir)"
cat > "$fake_smoke_bin/scp" <<'SH'
#!/usr/bin/env bash
src=""
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *:*) ;;
    *) src="$arg" ;;
  esac
done
cp "$src" "$FIELDWORK_FAKE_SMOKE_SCRIPT"
SH
cat > "$fake_smoke_bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_SMOKE_SSH_LOG"
printf '{"ok": true, "request_id": "00000000-0000-4000-8000-000000000000", "url": "https://github.com/owner/fieldwork-smoke/pull/1"}\n'
SH
chmod +x "$fake_smoke_bin/scp" "$fake_smoke_bin/ssh"
FIELDWORK_FAKE_SMOKE_SCRIPT="$fake_smoke_bin/smoke.sh" FIELDWORK_FAKE_SMOKE_SSH_LOG="$fake_smoke_bin/ssh.log" FIELDWORK_SSH_HOST=fake-vps PATH="$fake_smoke_bin:$PATH" "$ROOT/bin/fieldwork" smoke owner/fieldwork-smoke --yes >${TMPDIR:-/tmp}/fieldwork-smoke-fake.out
grep -q "fieldwork-pr-submit" "$fake_smoke_bin/smoke.sh"
grep -q "request_id=" "$fake_smoke_bin/smoke.sh"
grep -q "created_at=" "$fake_smoke_bin/smoke.sh"
grep -q "fieldwork/smoke-" "$fake_smoke_bin/smoke.sh"
grep -q "https://github.com/owner/fieldwork-smoke/pull/1" ${TMPDIR:-/tmp}/fieldwork-smoke-fake.out

cat > "$fake_smoke_bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIELDWORK_FAKE_SMOKE_SSH_LOG"
printf '{"ok": true, "queued": true, "request_id": "11111111-1111-4111-8111-111111111111", "expires_at": "2026-05-24T03:02:51Z"}\n'
printf '[fieldwork-pr-submit] queued for human approval; expires at 2026-05-24T03:02:51Z\n'
SH
chmod +x "$fake_smoke_bin/ssh"
FIELDWORK_FAKE_SMOKE_SCRIPT="$fake_smoke_bin/smoke-queued.sh" FIELDWORK_FAKE_SMOKE_SSH_LOG="$fake_smoke_bin/ssh-queued.log" FIELDWORK_SSH_HOST=fake-vps PATH="$fake_smoke_bin:$PATH" "$ROOT/bin/fieldwork" smoke owner/fieldwork-smoke --yes >${TMPDIR:-/tmp}/fieldwork-smoke-queued.out
grep -q "broker queued smoke PR for Telegram approval" ${TMPDIR:-/tmp}/fieldwork-smoke-queued.out
grep -q "approve the queued smoke request in Telegram" ${TMPDIR:-/tmp}/fieldwork-smoke-queued.out
if grep -q "smoke PR was not opened" ${TMPDIR:-/tmp}/fieldwork-smoke-queued.out; then
  echo "queued smoke request should not be reported as blocked" >&2
  exit 1
fi

echo "[checks] install has clean default output in temp HOME"
tmp_home="$(mktemp_dir)"
HOME="$tmp_home" PATH="$tmp_home/.local/bin:$PATH" "$ROOT/install.sh" >${TMPDIR:-/tmp}/fieldwork-install.out
test -L "$tmp_home/.local/bin/fieldwork"
grep -q "^Fieldwork install" ${TMPDIR:-/tmp}/fieldwork-install.out
grep -q "No secrets, repos, SSH config, or VPS settings are touched" ${TMPDIR:-/tmp}/fieldwork-install.out
grep -q "^Installing" ${TMPDIR:-/tmp}/fieldwork-install.out
grep -q "fieldwork command" ${TMPDIR:-/tmp}/fieldwork-install.out
grep -q "Claude helpers" ${TMPDIR:-/tmp}/fieldwork-install.out
grep -q "VPS support files" ${TMPDIR:-/tmp}/fieldwork-install.out
grep -q "^Ready" ${TMPDIR:-/tmp}/fieldwork-install.out
grep -q "^Next" ${TMPDIR:-/tmp}/fieldwork-install.out
if grep -q "\[install\] linked:" ${TMPDIR:-/tmp}/fieldwork-install.out; then
  echo "default install output included verbose symlink details" >&2
  exit 1
fi
HOME="$tmp_home" PATH="$tmp_home/.local/bin:$PATH" "$ROOT/install.sh" --verbose >${TMPDIR:-/tmp}/fieldwork-install-verbose.out
grep -Fq "[install] ok: $tmp_home/.local/bin/fieldwork -> $ROOT/bin/fieldwork" ${TMPDIR:-/tmp}/fieldwork-install-verbose.out
HOME="$tmp_home" "$ROOT/install.sh" --quiet >${TMPDIR:-/tmp}/fieldwork-install-quiet.out
if [ -s ${TMPDIR:-/tmp}/fieldwork-install-quiet.out ]; then
  echo "quiet install printed first-run UI" >&2
  exit 1
fi
HOME="$tmp_home" PATH="$tmp_home/.local/bin:$PATH" "$tmp_home/.local/bin/fieldwork" sync-vps --dry-run >${TMPDIR:-/tmp}/fieldwork-symlink-sync-dry-run.out
grep -q "source: $ROOT/" ${TMPDIR:-/tmp}/fieldwork-symlink-sync-dry-run.out
if grep -q "source: $tmp_home/.local/" ${TMPDIR:-/tmp}/fieldwork-symlink-sync-dry-run.out; then
  echo "installed fieldwork symlink resolved FIELDWORK_ROOT to ~/.local" >&2
  exit 1
fi
tmp_path_home="$(mktemp_dir)"
HOME="$tmp_path_home" "$ROOT/install.sh" >${TMPDIR:-/tmp}/fieldwork-install-path-warning.out
grep -q "Installed Fieldwork locally" ${TMPDIR:-/tmp}/fieldwork-install-path-warning.out
grep -q "PATH check" ${TMPDIR:-/tmp}/fieldwork-install-path-warning.out
grep -q "~/.local/bin is not on PATH" ${TMPDIR:-/tmp}/fieldwork-install-path-warning.out
grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' ${TMPDIR:-/tmp}/fieldwork-install-path-warning.out

echo "[checks] install skipped assets give concise guidance"
tmp_block_home="$(mktemp_dir)"
mkdir -p "$tmp_block_home/.claude"
printf 'old settings\n' > "$tmp_block_home/.claude/settings.json"
HOME="$tmp_block_home" PATH="$tmp_block_home/.local/bin:$PATH" "$ROOT/install.sh" >${TMPDIR:-/tmp}/fieldwork-install-skip.out 2>&1
grep -q "Installed the fieldwork command, but some helper files could not be updated" ${TMPDIR:-/tmp}/fieldwork-install-skip.out
grep -q "Claude helpers .*1 file blocked" ${TMPDIR:-/tmp}/fieldwork-install-skip.out
grep -q "Needs attention" ${TMPDIR:-/tmp}/fieldwork-install-skip.out
grep -q "~/.claude/settings.json" ${TMPDIR:-/tmp}/fieldwork-install-skip.out
grep -q "To inspect all details:" ${TMPDIR:-/tmp}/fieldwork-install-skip.out
grep -q "To replace blockers safely:" ${TMPDIR:-/tmp}/fieldwork-install-skip.out
grep -q -- "--force backs up replaced files as <path>.bak-<timestamp>" ${TMPDIR:-/tmp}/fieldwork-install-skip.out
HOME="$tmp_block_home" PATH="$tmp_block_home/.local/bin:$PATH" "$ROOT/install.sh" --verbose >${TMPDIR:-/tmp}/fieldwork-install-skip-verbose.out 2>&1
grep -Fq "[install] skip: $tmp_block_home/.claude/settings.json exists; pass --force to back it up and replace" ${TMPDIR:-/tmp}/fieldwork-install-skip-verbose.out
if HOME="$tmp_block_home" "$ROOT/install.sh" --quiet >${TMPDIR:-/tmp}/fieldwork-install-skip-quiet.out 2>&1; then
  echo "quiet install succeeded despite skipped assets" >&2
  exit 1
fi
grep -q "skipped 1 assets" ${TMPDIR:-/tmp}/fieldwork-install-skip-quiet.out

echo "[checks] install force reports backups in verbose mode"
tmp_force_home="$(mktemp_dir)"
mkdir -p "$tmp_force_home/.claude"
printf 'old settings\n' > "$tmp_force_home/.claude/settings.json"
HOME="$tmp_force_home" PATH="$tmp_force_home/.local/bin:$PATH" "$ROOT/install.sh" --force --verbose >${TMPDIR:-/tmp}/fieldwork-install-force.out
test -L "$tmp_force_home/.claude/settings.json"
grep -Fq "[install] backup: $tmp_force_home/.claude/settings.json ->" ${TMPDIR:-/tmp}/fieldwork-install-force.out
grep -q ".bak-" ${TMPDIR:-/tmp}/fieldwork-install-force.out

echo "[checks] onboard state status with fake ssh"
tmp_clone_home="$(mktemp_dir)"
HOME="$tmp_clone_home" "$ROOT/lib/scripts/fieldwork-clone" --prepare-deploy-key owner/fieldwork-smoke >${TMPDIR:-/tmp}/fieldwork-fieldwork-clone-prepare.out
grep -q '^ssh-ed25519 ' ${TMPDIR:-/tmp}/fieldwork-fieldwork-clone-prepare.out
test -f "$tmp_clone_home/.ssh/id_ed25519_fieldwork-smoke"
if grep -q "Next action" ${TMPDIR:-/tmp}/fieldwork-fieldwork-clone-prepare.out; then
  echo "fieldwork-clone prepare mode should not print standalone guidance" >&2
  exit 1
fi
fake_ssh_bin="$(mktemp_dir)"
cat > "$fake_ssh_bin/ssh" <<'SH'
#!/usr/bin/env bash
last=""
for arg in "$@"; do
  last="$arg"
done
printf '%s\n' "$last" >> "$FIELDWORK_FAKE_SSH_LOG"
case "$last" in
  *"test -d "*"fieldwork-smoke/.git"*) exit 0 ;;
  *"test -f "*"fieldwork-onboard-state.json"*) exit 0 ;;
  *"cat "*"fieldwork-onboard-state.json"*) cat "$FIELDWORK_FAKE_STATE"; exit 0 ;;
  *) echo "unexpected fake ssh command: $last" >&2; exit 1 ;;
esac
SH
chmod +x "$fake_ssh_bin/ssh"
fake_state="$fake_ssh_bin/state.json"
cat > "$fake_state" <<'JSON'
{
  "version": 1,
  "repo": "owner/fieldwork-smoke",
  "slug": "fieldwork-smoke",
  "branch": "fieldwork/init",
  "workflows_included": true,
  "completed_steps": [
    "preflight_passed",
    "clone_deploy_key_completed",
    "workspace_trust_confirmed"
  ],
  "updated_at": "2026-01-01T00:00:00Z"
}
JSON
FIELDWORK_FAKE_SSH_LOG="$fake_ssh_bin/ssh.log" FIELDWORK_FAKE_STATE="$fake_state" FIELDWORK_SSH_HOST=fake-vps PATH="$fake_ssh_bin:$PATH" "$ROOT/bin/fieldwork" onboard owner/fieldwork-smoke --status >${TMPDIR:-/tmp}/fieldwork-onboard-status.out
grep -q "Onboarding: owner/fieldwork-smoke" ${TMPDIR:-/tmp}/fieldwork-onboard-status.out
grep -q "ok      workspace trust completed" ${TMPDIR:-/tmp}/fieldwork-onboard-status.out
grep -q "Claude Remote Control consent pending" ${TMPDIR:-/tmp}/fieldwork-onboard-status.out
if grep -Eq 'fieldwork-clone|fieldwork-init|systemctl|gh repo view|fieldwork-pr-submit' "$fake_ssh_bin/ssh.log"; then
  echo "onboard --status performed mutating or live onboarding commands" >&2
  exit 1
fi
printf '{not-json\n' > "$fake_state"
FIELDWORK_FAKE_SSH_LOG="$fake_ssh_bin/ssh-corrupt.log" FIELDWORK_FAKE_STATE="$fake_state" FIELDWORK_SSH_HOST=fake-vps PATH="$fake_ssh_bin:$PATH" "$ROOT/bin/fieldwork" onboard owner/fieldwork-smoke --status >${TMPDIR:-/tmp}/fieldwork-onboard-corrupt.out
grep -q "checkpoint is corrupt" ${TMPDIR:-/tmp}/fieldwork-onboard-corrupt.out
grep -q -- "--reset-state" ${TMPDIR:-/tmp}/fieldwork-onboard-corrupt.out
cat > "$fake_state" <<'JSON'
{
  "version": 1,
  "repo": "owner/fieldwork-smoke",
  "slug": "fieldwork-smoke",
  "branch": "fieldwork/init",
  "workflows_included": false,
  "completed_steps": ["preflight_passed"],
  "updated_at": "2026-01-01T00:00:00Z"
}
JSON
if FIELDWORK_FAKE_SSH_LOG="$fake_ssh_bin/ssh-mismatch.log" FIELDWORK_FAKE_STATE="$fake_state" FIELDWORK_SSH_HOST=fake-vps PATH="$fake_ssh_bin:$PATH" "$ROOT/bin/fieldwork" onboard owner/fieldwork-smoke >${TMPDIR:-/tmp}/fieldwork-onboard-mismatch.out 2>&1; then
  echo "workflow-mode checkpoint mismatch unexpectedly succeeded" >&2
  exit 1
fi
grep -q -- "--no-workflows" ${TMPDIR:-/tmp}/fieldwork-onboard-mismatch.out

echo "[checks] onboard reset preserves prior manual confirmations"
fake_onboard_infer_bin="$(mktemp_dir)"
cat > "$fake_onboard_infer_bin/ssh" <<'SH'
#!/usr/bin/env bash
last=""
for arg in "$@"; do
  last="$arg"
done
printf '%s\n' "$last" >> "$FIELDWORK_FAKE_ONBOARD_INFER_SSH_LOG"
case "$last" in
  *"rm -f "*"fieldwork-onboard-state.json"*) exit 0 ;;
  *"test -d "*"fieldwork-smoke/.git"*) exit 0 ;;
  *"test -f "*"fieldwork-onboard-state.json"*) exit 1 ;;
  *"test -f "*"fieldwork-workspace_trust_confirmed"*) exit 0 ;;
  *"test -f "*"fieldwork-remote_control_consent_confirmed"*) exit 0 ;;
  *"mkdir -p "*"touch "*"fieldwork-"*) exit 0 ;;
  *"mkdir -p "*"fieldwork-onboard-state.json"*) exit 0 ;;
  *"systemctl --user is-active --quiet 'fieldwork-agent@fieldwork-smoke'"*) exit 1 ;;
  *"gh repo view "*"--json defaultBranchRef,nameWithOwner,visibility"*)
    printf '{"nameWithOwner":"owner/fieldwork-smoke","defaultBranchRef":{"name":"main"},"visibility":"PRIVATE"}\n'
    exit 0
    ;;
  *"http://localhost/preflight"*)
    printf '{"ok":true,"request_id":"test","repo":"owner/fieldwork-smoke"}\n200\n'
    exit 0
    ;;
  *"git rev-parse --verify 'fieldwork/init'"*) exit 0 ;;
  *"git show 'fieldwork/init:.fieldwork/expected-origin'"*)
    printf 'https://github.com/owner/fieldwork-smoke\n'
    exit 0
    ;;
  *"git rev-parse --abbrev-ref HEAD"*) exit 0 ;;
  *"git add -A"*) exit 0 ;;
  *"broker_user='fieldwork-pr-broker'"*"setfacl -R -m"*|*"broker_user='fieldwork-pr-broker'"*"chmod -R o+rX"*) exit 0 ;;
  *"gh pr list"*) printf '7\n'; exit 0 ;;
  *"systemctl --user enable --now 'fieldwork-agent@fieldwork-smoke'"*) printf 'active\n'; exit 0 ;;
  *)
    echo "unexpected fake onboard infer ssh command: $last" >&2
    exit 1
    ;;
esac
SH
cat > "$fake_onboard_infer_bin/scp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fake_onboard_infer_bin/ssh" "$fake_onboard_infer_bin/scp"
FIELDWORK_FAKE_ONBOARD_INFER_SSH_LOG="$fake_onboard_infer_bin/ssh.log" FIELDWORK_SSH_HOST=fake-vps PATH="$fake_onboard_infer_bin:$PATH" "$ROOT/bin/fieldwork" onboard owner/fieldwork-smoke --reset-state --no-workflows </dev/null >${TMPDIR:-/tmp}/fieldwork-onboard-infer.out
grep -q "Workspace Trust already completed" ${TMPDIR:-/tmp}/fieldwork-onboard-infer.out
grep -q "Claude Remote Control Consent already completed" ${TMPDIR:-/tmp}/fieldwork-onboard-infer.out
grep -q "Onboarding Complete" ${TMPDIR:-/tmp}/fieldwork-onboard-infer.out
if grep -q "Open now" ${TMPDIR:-/tmp}/fieldwork-onboard-infer.out; then
  echo "onboard asked for manual Claude confirmations despite durable markers" >&2
  exit 1
fi

echo "[checks] fieldwork-init --no-workflows smoke"
tmp_repo="$(mktemp_dir)"
tmp_bin="$(mktemp_dir)"
cat > "$tmp_bin/sudo" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$tmp_bin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$tmp_bin/sudo" "$tmp_bin/gh"
git init -q "$tmp_repo"
mkdir -p "$tmp_repo/.github/workflows"
printf 'name: existing\n' > "$tmp_repo/.github/workflows/existing.yml"
FIELDWORK_TEMPLATE_DIR="$ROOT/lib/templates/repo" PATH="$tmp_bin:$PATH" "$ROOT/lib/scripts/fieldwork-init" --no-workflows "$tmp_repo" >${TMPDIR:-/tmp}/fieldwork-no-workflows.out
test -f "$tmp_repo/.fieldwork/expected-origin"
test -f "$tmp_repo/CLAUDE.md"
test -f "$tmp_repo/REVIEW.md"
test -f "$tmp_repo/.github/CODEOWNERS"
test -f "$tmp_repo/.github/dependabot.yml"
test -f "$tmp_repo/.github/workflows/existing.yml"
test ! -f "$tmp_repo/.github/workflows/ci.yml"
test ! -f "$tmp_repo/.github/workflows/audit.yml"

echo "[checks] fieldwork-init prunes workflow templates without prerequisites"
tmp_unknown_repo="$(mktemp_dir)"
git init -q "$tmp_unknown_repo"
FIELDWORK_TEMPLATE_DIR="$ROOT/lib/templates/repo" PATH="$tmp_bin:$PATH" "$ROOT/lib/scripts/fieldwork-init" "$tmp_unknown_repo" >${TMPDIR:-/tmp}/fieldwork-unknown-workflows.out
test ! -f "$tmp_unknown_repo/.github/workflows/ci.yml"
test ! -f "$tmp_unknown_repo/.github/workflows/codeql.yml"
test -f "$tmp_unknown_repo/.github/workflows/semgrep.yml"
if grep -Eq -- '--config=p/(typescript|react|golang|rust|python)' "$tmp_unknown_repo/.github/workflows/semgrep.yml"; then
  echo "semgrep template should be pruned to generic configs for unknown stacks" >&2
  exit 1
fi
grep -q "removed template ci.yml" ${TMPDIR:-/tmp}/fieldwork-unknown-workflows.out
grep -q "removed template codeql.yml" ${TMPDIR:-/tmp}/fieldwork-unknown-workflows.out
grep -q "Skip when Claude API key is not configured" "$tmp_unknown_repo/.github/workflows/claude-review.yml"
grep -q "Skip when Claude API key is not configured" "$tmp_unknown_repo/.github/workflows/claude.yml"

echo "[checks] repo template keeps Fieldwork state split from Claude discovery"
test -f "$ROOT/lib/templates/repo/.fieldwork/expected-origin"
test -d "$ROOT/lib/templates/repo/.fieldwork/local"
test ! -e "$ROOT/lib/templates/repo/.claude/expected-origin"
test ! -e "$ROOT/lib/templates/repo/.claude/default-branch"
test ! -e "$ROOT/lib/templates/repo/.claude/approval-gate"
test ! -e "$ROOT/lib/templates/repo/.claude/local"
test -f "$ROOT/lib/templates/repo/.claude/settings.json"
test -d "$ROOT/lib/templates/repo/.claude/hooks"
test -d "$ROOT/lib/templates/repo/.claude/skills"
test -d "$ROOT/lib/templates/repo/.claude/agents"
test -d "$ROOT/lib/templates/repo/.claude/rules"
test ! -e "$ROOT/lib/templates/repo/.agents/skills"
test ! -e "$ROOT/lib/templates/repo/.codex/skills"
test -f "$ROOT/lib/templates/repo/AGENTS.md"
test -f "$ROOT/AGENTS.md"
grep -q "fieldwork-verify" "$ROOT/lib/templates/repo/AGENTS.md"
grep -q ".fieldwork/local/pr-prepare-request.json" "$ROOT/lib/templates/repo/AGENTS.md"
grep -q "fieldwork-pr-submit" "$ROOT/lib/templates/repo/AGENTS.md"
grep -q "fieldwork/..." "$ROOT/lib/templates/repo/AGENTS.md"
grep -q ".fieldwork/approval-gate" "$ROOT/lib/templates/repo/AGENTS.md"

echo "[checks] Codex sandbox profile selects Fieldwork socket allowlist"
grep -Fq 'default_permissions = "%s"' "$ROOT/lib/cli/setup.sh"
grep -Fq 'extends = ":workspace"' "$ROOT/lib/cli/setup.sh"
grep -Fq '[permissions.%s.network.unix_sockets]' "$ROOT/lib/cli/setup.sh"
grep -Fq 'enabled = true' "$ROOT/lib/cli/setup.sh"
grep -Fq 'mode = "limited"' "$ROOT/lib/cli/setup.sh"
grep -Fq 'default_permissions=\":workspace\"' "$ROOT/lib/cli/setup.sh"
grep -Fq 'default_permissions = \"fieldwork\"' "$ROOT/bin/fieldwork"
if grep_regex 'codex sandbox linux --permissions-profile fieldwork|\.agents/skills|\.codex/skills' "$ROOT/bin/fieldwork" "$ROOT/lib/cli/setup.sh" "$ROOT/lib/templates/repo"; then
  echo "Codex path should use the selected default fieldwork profile and no repo-level Codex skills" >&2
  exit 1
fi

echo "[checks] Codex sandbox helper guards invocation drift"
helper_run_count="$(count_fixed_occurrences 'fieldwork-codex-sandbox run' "$ROOT/lib/cli/setup.sh" "$ROOT/bin/fieldwork")"
if [ "$helper_run_count" != "4" ]; then
  echo "expected exactly four routed fieldwork-codex-sandbox run call sites, saw $helper_run_count" >&2
  exit 1
fi
grep -Fq 'fieldwork-codex-sandbox run -- python3' "$ROOT/lib/cli/setup.sh"
grep -Fq 'fieldwork-codex-sandbox run -- python3' "$ROOT/bin/fieldwork"
if grep_regex 'codex sandbox [[:alnum:]_-]+.*(--|-c|python3)' "$ROOT/bin/fieldwork" "$ROOT/lib/cli/setup.sh"; then
  echo "Codex sandbox probes must route through fieldwork-codex-sandbox" >&2
  exit 1
fi
grep -Fq 'add_candidate sandbox' "$ROOT/lib/scripts/fieldwork-codex-sandbox"
grep -Fq 'add_candidate sandbox linux' "$ROOT/lib/scripts/fieldwork-codex-sandbox"
grep -Fq 'codex "${decoded_candidate_words[@]}" "${codex_flags[@]}" -- true' "$ROOT/lib/scripts/fieldwork-codex-sandbox"
if grep -Eq '(^|[[:space:]])eval([[:space:]]|$)' "$ROOT/lib/scripts/fieldwork-codex-sandbox"; then
  echo "fieldwork-codex-sandbox must not use eval" >&2
  exit 1
fi

echo "[checks] Codex sandbox helper adapts to CLI forms"
fake_codex_bin="$(mktemp_dir)"
cat > "$fake_codex_bin/codex" <<'SH'
#!/usr/bin/env bash
mode="${FAKE_CODEX_MODE:-new}"
if [ "${1:-}" = "--version" ]; then
  echo "codex-cli fake"
  exit 0
fi
if [ "${1:-}" = "sandbox" ] && [ "${2:-}" = "--help" ]; then
  case "$mode" in
    help) echo "Usage: codex sandbox portal [OPTIONS] [COMMAND]..." ;;
    *) echo "Usage: codex sandbox [OPTIONS] [COMMAND]..." ;;
  esac
  exit 0
fi
[ "${1:-}" = "sandbox" ] || exit 127
shift
form="sandbox"
case "${1:-}" in
  linux) form="sandbox linux"; shift ;;
  portal) form="sandbox portal"; shift ;;
esac
saw_config=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -c|--config|--config=*) saw_config=1 ;;
  esac
  shift
done
[ "$#" -gt 0 ] || exit 2
case "$mode:$form" in
  old:sandbox\ linux|new:sandbox|help:sandbox\ portal|flagok:sandbox|flagreject:sandbox) ;;
  *) exit 127 ;;
esac
if [ "$mode" = "flagreject" ] && [ "$saw_config" = "1" ]; then
  exit 64
fi
exec "$@"
SH
chmod +x "$fake_codex_bin/codex"
env FAKE_CODEX_MODE=old PATH="$fake_codex_bin:$PATH" "$ROOT/lib/scripts/fieldwork-codex-sandbox" run -- true
env FAKE_CODEX_MODE=new PATH="$fake_codex_bin:$PATH" "$ROOT/lib/scripts/fieldwork-codex-sandbox" run -- true
env FAKE_CODEX_MODE=help PATH="$fake_codex_bin:$PATH" "$ROOT/lib/scripts/fieldwork-codex-sandbox" run -- true
helper_printf_out="$(env FAKE_CODEX_MODE=new PATH="$fake_codex_bin:$PATH" "$ROOT/lib/scripts/fieldwork-codex-sandbox" run -- printf hi)"
[ "$helper_printf_out" = "hi" ]
helper_stdin_out="$(printf X | env FAKE_CODEX_MODE=new PATH="$fake_codex_bin:$PATH" "$ROOT/lib/scripts/fieldwork-codex-sandbox" run -- cat)"
[ "$helper_stdin_out" = "X" ]
env FAKE_CODEX_MODE=flagok PATH="$fake_codex_bin:$PATH" "$ROOT/lib/scripts/fieldwork-codex-sandbox" run -c 'default_permissions=":workspace"' -- true
if env FAKE_CODEX_MODE=broken PATH="$fake_codex_bin:$PATH" "$ROOT/lib/scripts/fieldwork-codex-sandbox" run -- true >${TMPDIR:-/tmp}/fieldwork-codex-helper-broken.out 2>${TMPDIR:-/tmp}/fieldwork-codex-helper-broken.err; then
  echo "fieldwork-codex-sandbox unexpectedly accepted a broken codex sandbox" >&2
  exit 1
fi
grep -q "no working codex sandbox invocation found" ${TMPDIR:-/tmp}/fieldwork-codex-helper-broken.err
if env FAKE_CODEX_MODE=flagreject PATH="$fake_codex_bin:$PATH" "$ROOT/lib/scripts/fieldwork-codex-sandbox" run -c 'default_permissions="do-not-print-this"' -- true >${TMPDIR:-/tmp}/fieldwork-codex-helper-flagreject.out 2>${TMPDIR:-/tmp}/fieldwork-codex-helper-flagreject.err; then
  echo "fieldwork-codex-sandbox unexpectedly accepted rejected caller flags" >&2
  exit 1
fi
grep -q "caller flags rejected" ${TMPDIR:-/tmp}/fieldwork-codex-helper-flagreject.err
if grep -q "do-not-print-this" ${TMPDIR:-/tmp}/fieldwork-codex-helper-flagreject.err; then
  echo "fieldwork-codex-sandbox must not echo raw caller flag values" >&2
  exit 1
fi

echo "[checks] invalid branch rejects before ssh"
if "$ROOT/bin/fieldwork" onboard --branch invalid owner/repo >${TMPDIR:-/tmp}/fieldwork-invalid-branch.out 2>&1; then
  echo "invalid branch unexpectedly succeeded" >&2
  exit 1
fi
grep -q "does not match broker pattern" ${TMPDIR:-/tmp}/fieldwork-invalid-branch.out

echo "[checks] invalid owner/repo rejects before ssh"
if "$ROOT/bin/fieldwork" onboard 'bad;owner/repo' >${TMPDIR:-/tmp}/fieldwork-invalid-owner.out 2>&1; then
  echo "invalid owner unexpectedly succeeded" >&2
  exit 1
fi
grep -q "not a valid GitHub" ${TMPDIR:-/tmp}/fieldwork-invalid-owner.out
if "$ROOT/bin/fieldwork" smoke 'bad;owner/repo' >${TMPDIR:-/tmp}/fieldwork-invalid-smoke-owner.out 2>&1; then
  echo "invalid smoke owner unexpectedly succeeded" >&2
  exit 1
fi
grep -q "invalid GitHub owner/repo" ${TMPDIR:-/tmp}/fieldwork-invalid-smoke-owner.out

echo "[checks] no local macOS home paths"
if grep_repo_regex_excluding_static '/Users/[^/[:space:]]+/'; then
  echo "local macOS home path found" >&2
  exit 1
fi

echo "[checks] setup-first docs posture"
grep -q "is the guided path" "$ROOT/README.md"
grep -q "Run .*fieldwork setup.* first" "$ROOT/docs/quickstart.md"
grep -q "reference manual behind .*fieldwork setup" "$ROOT/docs/first-time-infrastructure.md"
grep -q "root SSH or another sudo-capable VPS account" "$ROOT/docs/quickstart.md"
grep -q "provider console or rescue mode" "$ROOT/docs/first-time-infrastructure.md"
grep -q "restore root SSH or root authorized keys" "$ROOT/docs/uninstall.md"
grep -q "credentials were saved in plain text" "$ROOT/docs/setup.md"
grep -q "credentials were saved in plain text" "$ROOT/docs/quickstart.md"
grep -q "credentials were saved in plain text" "$ROOT/docs/first-time-infrastructure.md"
grep -q "separate from the broker PAT" "$ROOT/docs/setup.md"
grep -q "not the broker PAT" "$ROOT/docs/first-time-infrastructure.md"
if grep -q "Use \\[docs/first-time-infrastructure.md\\].* first" "$ROOT/README.md"; then
  echo "README sends new users to the manual before setup" >&2
  exit 1
fi

echo "[checks] developer preview launch docs"
for f in CONTRIBUTING.md CODE_OF_CONDUCT.md CHANGELOG.md ROADMAP.md SECURITY.md docs/evaluation.md docs/supply-chain.md docs/backup-restore.md docs/versioning.md docs/developer-preview.md .github/dependabot.yml .github/PULL_REQUEST_TEMPLATE.md; do
  test -f "$ROOT/$f" || { echo "missing launch file: $f" >&2; exit 1; }
done
grep -q "Fieldwork has no Fieldwork-operated telemetry" "$ROOT/README.md"
grep -q "Fieldwork has no Fieldwork-operated telemetry" "$ROOT/SECURITY.md"
grep -q "Fieldwork treats the coding agent as adversarial" "$ROOT/docs/threat-model.md"
grep -q "git tag -v" "$ROOT/docs/supply-chain.md"
grep -q "shasum -a 256 -c SHA256SUMS" "$ROOT/docs/supply-chain.md"
grep -q "does not recommend blind \`curl | bash\`" "$ROOT/docs/supply-chain.md"
grep -q "fieldwork eval smoke" "$ROOT/docs/evaluation.md"
grep -q "audit.jsonl" "$ROOT/docs/backup-restore.md"
grep -q "signed Git tags" "$ROOT/README.md" "$ROOT/docs/supply-chain.md" >/dev/null

echo "[checks] eval assets present"
test -x "$ROOT/examples/eval/eval-smoke.sh"
test -x "$ROOT/examples/eval/gh"
test -x "$ROOT/examples/eval/gitleaks"
grep -q "evaluation only" "$ROOT/examples/eval/README.md"

echo "[checks] eval up handles missing Docker daemon cleanly"
fake_eval_bin="$(mktemp_dir)"
cat > "$fake_eval_bin/docker" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "compose version") exit 0 ;;
  "info") exit 1 ;;
  *) echo "unexpected docker command: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$fake_eval_bin/docker"
if PATH="$fake_eval_bin:$PATH" "$ROOT/bin/fieldwork" eval up >${TMPDIR:-/tmp}/fieldwork-eval-no-daemon.out 2>&1; then
  echo "fieldwork eval up unexpectedly passed without Docker daemon" >&2
  exit 1
fi
grep -q "^Fieldwork eval$" ${TMPDIR:-/tmp}/fieldwork-eval-no-daemon.out
grep -q "^Preflight$" ${TMPDIR:-/tmp}/fieldwork-eval-no-daemon.out
grep -q "Docker daemon .*not reachable" ${TMPDIR:-/tmp}/fieldwork-eval-no-daemon.out
grep -q "^Summary$" ${TMPDIR:-/tmp}/fieldwork-eval-no-daemon.out
grep -q "Eval environment not started" ${TMPDIR:-/tmp}/fieldwork-eval-no-daemon.out
grep -q "start Colima or Docker Desktop" ${TMPDIR:-/tmp}/fieldwork-eval-no-daemon.out
if grep -q "Cannot connect to the Docker daemon\\|unable to get image" ${TMPDIR:-/tmp}/fieldwork-eval-no-daemon.out; then
  echo "eval up leaked raw Docker daemon error" >&2
  exit 1
fi

echo "[checks] eval smoke renders human output"
fake_eval_smoke_bin="$(mktemp_dir)"
cat > "$fake_eval_smoke_bin/docker" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "compose version") exit 0 ;;
  "info") exit 0 ;;
  compose*" ps") exit 0 ;;
  compose*" exec -T fieldwork-eval /workspace/examples/eval/eval-smoke.sh")
    cat <<'JSON'
{"branch":"fieldwork/eval-smoke","decision":"approve","events":[{"actor":"eval","base_branch":"main","branch":"fieldwork/eval-smoke","event":"request_received","repo":"eval/throwaway","repo_path_slug":"throwaway","request_id":"bc900029-6841-4e3a-b145-bce0c4bfc996","transport":"docker","ts":"2026-05-20T16:43:11Z"},{"actor":"eval","base_branch":"main","branch":"fieldwork/eval-smoke","event":"request_queued","expires_at":"2026-05-21T16:43:11Z","repo":"eval/throwaway","repo_path_slug":"throwaway","request_id":"bc900029-6841-4e3a-b145-bce0c4bfc996","status":"queued","transport":"docker","ts":"2026-05-20T16:43:11Z"},{"actor":"eval","base_branch":"main","branch":"fieldwork/eval-smoke","decision":"approve","event":"request_approved","repo":"eval/throwaway","repo_path_slug":"throwaway","request_id":"bc900029-6841-4e3a-b145-bce0c4bfc996","transport":"approve-socket","ts":"2026-05-20T16:43:11Z"},{"actor":"broker","base_branch":"main","branch":"fieldwork/eval-smoke","event":"push_attempted","repo":"eval/throwaway","repo_path_slug":"throwaway","request_id":"bc900029-6841-4e3a-b145-bce0c4bfc996","transport":"fake-github","ts":"2026-05-20T16:43:11Z"},{"actor":"broker","base_branch":"main","branch":"fieldwork/eval-smoke","event":"pr_opened","pr_url":"https://github.local/eval/throwaway/pull/1","repo":"eval/throwaway","repo_path_slug":"throwaway","request_id":"bc900029-6841-4e3a-b145-bce0c4bfc996","transport":"fake-github","ts":"2026-05-20T16:43:11Z"}],"mode":"eval","ok":true,"pr_url":"https://github.local/eval/throwaway/pull/1","repo":"eval/throwaway","request_id":"bc900029-6841-4e3a-b145-bce0c4bfc996"}
JSON
    exit 0
    ;;
  *) echo "unexpected docker command: $*" >&2; exit 1 ;;
esac
SH
chmod +x "$fake_eval_smoke_bin/docker"
PATH="$fake_eval_smoke_bin:$PATH" "$ROOT/bin/fieldwork" eval smoke >${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out
grep -q "^Fieldwork eval smoke$" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out
grep -q "^Preparing$" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out
grep -q "throwaway repo ready" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out
grep -q "^Broker flow$" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out
grep -q "approval accepted .*approve" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out
grep -q "push attempted .*fake-github" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out
grep -q "smoke test passed" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out
grep -q "request .*bc900029" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out
grep -q "fieldwork eval smoke --verbose" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out
grep -q "fieldwork eval smoke --json" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out
if grep -q '"event"\\|audit log:' ${TMPDIR:-/tmp}/fieldwork-eval-smoke-human.out; then
  echo "eval smoke default output leaked raw JSON" >&2
  exit 1
fi
PATH="$fake_eval_smoke_bin:$PATH" "$ROOT/bin/fieldwork" eval smoke --verbose >${TMPDIR:-/tmp}/fieldwork-eval-smoke-verbose.out
grep -q "^Timeline$" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-verbose.out
grep -q "16:43:11 .*request received .*docker" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-verbose.out
grep -q "request .*bc900029-6841-4e3a-b145-bce0c4bfc996" ${TMPDIR:-/tmp}/fieldwork-eval-smoke-verbose.out
PATH="$fake_eval_smoke_bin:$PATH" "$ROOT/bin/fieldwork" eval smoke --json >${TMPDIR:-/tmp}/fieldwork-eval-smoke-json.out
grep -q '"ok": true' ${TMPDIR:-/tmp}/fieldwork-eval-smoke-json.out
grep -q '"event": "pr_opened"' ${TMPDIR:-/tmp}/fieldwork-eval-smoke-json.out

echo "[checks] eval smoke when docker is available"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  FIELDWORK_EVAL_PROJECT="fieldwork-static-checks-$$" "$ROOT/bin/fieldwork" eval up >/tmp/fieldwork-eval-up.out
  grep -q "Eval environment is running" /tmp/fieldwork-eval-up.out
  FIELDWORK_EVAL_PROJECT="fieldwork-static-checks-$$" "$ROOT/bin/fieldwork" eval smoke >/tmp/fieldwork-eval-smoke.out
  grep -q "smoke test passed" /tmp/fieldwork-eval-smoke.out
  FIELDWORK_EVAL_PROJECT="fieldwork-static-checks-$$" "$ROOT/bin/fieldwork" eval smoke --json >/tmp/fieldwork-eval-smoke-json.out
  grep -q '"event": "pr_opened"' /tmp/fieldwork-eval-smoke-json.out
  FIELDWORK_EVAL_PROJECT="fieldwork-static-checks-$$" "$ROOT/bin/fieldwork" eval clean >/dev/null
else
  echo "  skip docker eval smoke (docker compose unavailable)"
fi

echo "[checks] no internal W2 wording"
if grep_repo_regex_excluding_static '(^|[^A-Za-z0-9])W2([^A-Za-z0-9]|$)'; then
  echo "internal W2 wording found" >&2
  exit 1
fi
grep -q "remote Claude session service" "$ROOT/lib/scripts/fieldwork-onboard"

echo "[checks] broker service hardening"
for directive in \
  "NoNewPrivileges=true" \
  "PrivateTmp=true" \
  "ProtectSystem=strict" \
  "ProtectHome=read-only" \
  "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6"; do
  grep -Fx "$directive" "$ROOT/lib/broker/fieldwork-pr-broker.service" >/dev/null
done

echo "[checks] approve socket unit + service wiring"
test -f "$ROOT/lib/broker/fieldwork-pr-approve.socket"
grep -Fx "ListenStream=/run/fieldwork-pr-broker/fieldwork-pr-approve.sock" "$ROOT/lib/broker/fieldwork-pr-approve.socket" >/dev/null
grep -Fx "SocketGroup=fieldwork-bot" "$ROOT/lib/broker/fieldwork-pr-approve.socket" >/dev/null
grep -Fx "SocketMode=0660" "$ROOT/lib/broker/fieldwork-pr-approve.socket" >/dev/null
grep -Fx "Sockets=fieldwork-pr-broker.socket fieldwork-pr-approve.socket" "$ROOT/lib/broker/fieldwork-pr-broker.service" >/dev/null
grep -Fx "Environment=FIELDWORK_BROKER_AUDIT_READ_USER=fieldwork" "$ROOT/lib/broker/fieldwork-pr-broker.service" >/dev/null

echo "[checks] fieldwork-pr-submit handles queued response"
grep -q "queued for human approval" "$ROOT/lib/scripts/fieldwork-pr-submit"

echo "[checks] bot daemon syntax + tests"
python3 -m py_compile "$ROOT/lib/scripts/fieldwork-bot"
python3 "$ROOT/tests/bot-tests.py"

echo "[checks] bot service hardening"
test -f "$ROOT/lib/systemd/fieldwork-bot.service"
for directive in \
  "User=fieldwork-bot" \
  "Group=fieldwork-bot" \
  "Environment=FIELDWORK_BOT_HEALTH_PATH=/var/lib/fieldwork-bot/bot-health.json" \
  "NoNewPrivileges=true" \
  "PrivateTmp=true" \
  "ProtectSystem=strict" \
  "ProtectHome=true" \
  "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"; do
  grep -Fx "$directive" "$ROOT/lib/systemd/fieldwork-bot.service" >/dev/null
done
grep -q "/var/lib/fieldwork-bot" "$ROOT/lib/systemd/fieldwork-bot.service"
grep -q "/var/lib/fieldwork-bot" "$ROOT/lib/cli/setup.sh"
grep -q "FIELDWORK_BOT_HEALTH_PATH" "$ROOT/lib/scripts/fieldwork-bot"

echo "[checks] notify.sh hands off to bot when config present"
grep -q "/etc/fieldwork-bot/config.toml" "$ROOT/lib/scripts/notify.sh"
grep -q 'FIELDWORK_NOTIFICATIONS_DIR' "$ROOT/lib/scripts/notify.sh"
grep -q '"schema": 1' "$ROOT/lib/scripts/notify.sh"
grep -q 'json.dump(payload' "$ROOT/lib/scripts/notify.sh"
grep -q "dedupe_key" "$ROOT/lib/scripts/fieldwork-bot"
grep -q "FIELDWORK_BOT_DEDUPE_STORE_PATH" "$ROOT/lib/scripts/fieldwork-bot"

echo "[checks] setup-notify --telegram-bot help + verify-security bot checks"
"$ROOT/bin/fieldwork" setup-notify --help >${TMPDIR:-/tmp}/fieldwork-setup-notify-help.out
grep -q -- "--telegram-bot" ${TMPDIR:-/tmp}/fieldwork-setup-notify-help.out
grep -q "fieldwork-bot.service" ${TMPDIR:-/tmp}/fieldwork-setup-notify-help.out
"$ROOT/bin/fieldwork" --help | grep -q "setup-notify .*configure notification transport"
# verify-security: assert the new bot trust strings are present in the binary.
grep -q "Approval-Gate Bot" "$ROOT/lib/cli/verify-security.sh"
grep -q "bot user is not in the submit socket group" "$ROOT/lib/cli/verify-security.sh"
grep -q "bot user cannot read broker GitHub PAT" "$ROOT/lib/cli/verify-security.sh"
grep -q "expected fieldwork-pr-broker:fieldwork-bot 660" "$ROOT/lib/cli/verify-security.sh"
grep -q "HMAC secret owner/mode is fieldwork-bot:fieldwork-bot 400" "$ROOT/lib/cli/verify-security.sh"
grep -q "submit_socket_group" "$ROOT/lib/cli/setup.sh"
grep -q 'broker_state="/var/lib/fieldwork-pr-broker"' "$ROOT/lib/cli/setup.sh"
grep -q 'install -o "$broker_user" -g fieldwork-bot -m 2770 -d "$broker_state/pending"' "$ROOT/lib/cli/setup.sh"
grep -q 'install -o "$agent_user" -g fieldwork-bot -m 2770 -d "$broker_state/notifications"' "$ROOT/lib/cli/setup.sh"
grep -q 'setfacl -m "u:$broker_user:rwx" "$broker_state/notifications"' "$ROOT/lib/cli/setup.sh"
grep -q "that is the bot ID from the token, not an approver chat ID" "$ROOT/lib/cli/setup.sh"
grep -q "agent user's primary group" "$ROOT/examples/broker-client.py"

echo "[checks] onboard --with-approval-gate help + init flag"
"$ROOT/bin/fieldwork" onboard --help 2>&1 | grep -q -- "--with-approval-gate"
"$ROOT/lib/scripts/fieldwork-init" 2>&1 | grep -q -- "--with-approval-gate" || true
grep -q -- "--with-approval-gate" "$ROOT/lib/scripts/fieldwork-init"
grep -q -- "--with-approval-gate" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q '\.fieldwork/approval-gate' "$ROOT/lib/scripts/fieldwork-init"
# The onboarding init PR body should mention the gate when the flag is on.
grep -q "broker approval gate" "$ROOT/lib/scripts/fieldwork-onboard"

echo "[checks] approval-gate doc present"
test -f "$ROOT/docs/approval-gate.md"
grep -q '\.fieldwork/approval-gate' "$ROOT/docs/approval-gate.md"
grep -q "HMAC" "$ROOT/docs/approval-gate.md"
grep -q "fieldwork setup-notify --telegram-bot" "$ROOT/docs/approval-gate.md"
grep -q "fieldwork bot-status" "$ROOT/docs/approval-gate.md"
grep -q "Control Adapters" "$ROOT/docs/architecture.md"
grep -q "Telegram" "$ROOT/docs/architecture.md"

echo "[checks] fieldwork-init --with-approval-gate smoke"
init_smoke_dir="$(mktemp_dir)"
git init -q "$init_smoke_dir/repo"
cd "$init_smoke_dir/repo"
git config user.email test@example.com
git config user.name "Fieldwork Test"
echo hello > README.md
git add README.md
git commit -q -m init
git checkout -q -b fieldwork/init
FIELDWORK_TEMPLATE_DIR="$ROOT/lib/templates/repo" "$ROOT/lib/scripts/fieldwork-init" --branch fieldwork/init --with-approval-gate --no-workflows "$init_smoke_dir/repo" >${TMPDIR:-/tmp}/fieldwork-init-gate.out 2>&1 || {
  echo "fieldwork-init --with-approval-gate failed:" >&2
  cat ${TMPDIR:-/tmp}/fieldwork-init-gate.out >&2
  exit 1
}
test -f "$init_smoke_dir/repo/.fieldwork/approval-gate"
grep -q "approval gate marker" ${TMPDIR:-/tmp}/fieldwork-init-gate.out
cd "$ROOT"

echo "[checks] guard-bash cage gate"
guard_hook="$ROOT/lib/templates/repo/.claude/hooks/guard-bash.sh"
guard_tmp="$(mktemp_dir)"
mkdir -p "$guard_tmp/home" "$guard_tmp/no-socket"
printf 'NoNewPrivs:\t1\n' > "$guard_tmp/status-nnp1"
printf 'NoNewPrivs:\t0\n' > "$guard_tmp/status-nnp0"
# Sandboxed dev environments can deny AF_UNIX bind; the in-cage assertions
# need a real socket for the hook's -S check, so they skip there. CI runs them.
guard_socket_ok=0
if python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$guard_tmp/fieldwork-verify.sock" 2>/dev/null; then
  guard_socket_ok=1
fi
guard_run() {
  # $1 = command, $2 = uname, $3 = proc status file, $4 = runtime dir
  jq -n --arg c "$1" '{tool_input: {command: $c}}' \
    | FIELDWORK_GUARD_UNAME="$2" FIELDWORK_GUARD_PROC_STATUS="$3" \
      XDG_RUNTIME_DIR="$4" HOME="$guard_tmp/home" bash "$guard_hook"
}
guard_expect_deny() {
  local out
  out="$(guard_run "$@")"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null || {
    echo "guard-bash expected deny for: $1" >&2
    exit 1
  }
  printf '%s' "$out"
}
guard_expect_pass() {
  local out
  out="$(guard_run "$@")"
  [ -z "$out" ] || {
    echo "guard-bash expected pass-through for: $1 (got: $out)" >&2
    exit 1
  }
}
if [ "$guard_socket_ok" = "1" ]; then
  # in-cage plain command: denied, and the reason steers to the skills + clients
  guard_deny_out="$(guard_expect_deny "ls -la" Linux "$guard_tmp/status-nnp1" "$guard_tmp")"
  printf '%s' "$guard_deny_out" | jq -er '.hookSpecificOutput.permissionDecisionReason' | grep -q "/verify-before-pr"
  printf '%s' "$guard_deny_out" | jq -er '.hookSpecificOutput.permissionDecisionReason' | grep -q "fieldwork-pr-prepare"
  # in-cage verbatim client invocations: pass through silently
  guard_expect_pass "$guard_tmp/home/.local/bin/fieldwork-verify /proj" Linux "$guard_tmp/status-nnp1" "$guard_tmp"
  guard_expect_pass "$guard_tmp/home/.local/bin/fieldwork-pr-prepare .fieldwork/local/pr-prepare-request.json" Linux "$guard_tmp/status-nnp1" "$guard_tmp"
  guard_expect_pass "$guard_tmp/home/.local/bin/fieldwork-pr-submit .fieldwork/local/pr-request.json" Linux "$guard_tmp/status-nnp1" "$guard_tmp"
  # in-cage compound prefix: denied (the sandbox exclusion would not match it)
  guard_expect_deny "cd /x && $guard_tmp/home/.local/bin/fieldwork-verify /proj" Linux "$guard_tmp/status-nnp1" "$guard_tmp" >/dev/null
  # NoNewPrivs and uname are each required: drop one, plain command passes
  guard_expect_pass "ls -la" Linux "$guard_tmp/status-nnp0" "$guard_tmp"
  guard_expect_pass "ls -la" Darwin "$guard_tmp/status-nnp1" "$guard_tmp"
  # dangerous patterns still deny first inside the cage
  guard_expect_deny "git reset --hard HEAD~1" Linux "$guard_tmp/status-nnp1" "$guard_tmp" | jq -er '.hookSpecificOutput.permissionDecisionReason' | grep -q "hard reset"
else
  echo "  skip in-cage guard-bash tests (unix socket bind unavailable in this environment)"
fi
# the socket is required: without it, plain commands pass through
guard_expect_pass "ls -la" Linux "$guard_tmp/status-nnp1" "$guard_tmp/no-socket"
# dangerous patterns deny outside the cage
guard_expect_deny "git push --force origin main" Darwin "$guard_tmp/status-nnp1" "$guard_tmp/no-socket" >/dev/null

echo "[checks] agent-session init-branch gate"
gate_home="$(mktemp_dir)"
mkdir -p "$gate_home/projects"
git init -q "$gate_home/projects/smoke"
git -C "$gate_home/projects/smoke" config user.email test@example.com
git -C "$gate_home/projects/smoke" config user.name "Fieldwork Test"
( cd "$gate_home/projects/smoke" && echo hello > README.md && git add README.md && git commit -q -m init && git checkout -q -b fieldwork/init )
gate_rc=0
gate_err="$(HOME="$gate_home" "$ROOT/lib/scripts/fieldwork-agent-session" smoke 2>&1 >/dev/null)" || gate_rc=$?
[ "$gate_rc" = "0" ] || { echo "agent-session gate expected exit 0, got $gate_rc" >&2; exit 1; }
printf '%s\n' "$gate_err" | grep -q "refusing to serve sessions from the init branch"
printf '%s\n' "$gate_err" | grep -q "fieldwork refresh smoke"
git -C "$gate_home/projects/smoke" checkout -q -
mkdir -p "$gate_home/.fieldwork/infra/agents"
printf '#!/usr/bin/env bash\necho ADAPTER_RAN "$@" capacity="$FIELDWORK_AGENT_CAPACITY"\n' > "$gate_home/.fieldwork/infra/agents/claude-remote-control"
chmod +x "$gate_home/.fieldwork/infra/agents/claude-remote-control"
HOME="$gate_home" "$ROOT/lib/scripts/fieldwork-agent-session" smoke | grep -q "ADAPTER_RAN smoke .*capacity=2"
printf 'capacity=9\n' > "$gate_home/.fieldwork/agent.conf"
HOME="$gate_home" "$ROOT/lib/scripts/fieldwork-agent-session" smoke | grep -q "ADAPTER_RAN smoke .*capacity=4"

echo "[checks] bounded capacity and rate-limit docs"
grep -q 'FIELDWORK_BROKER_RATE_LIMIT_PER_HOUR' "$ROOT/lib/broker/server.py"
grep -q 'bounded_env_int("FIELDWORK_BROKER_RATE_LIMIT_PER_HOUR", 12, minimum=1, maximum=120)' "$ROOT/lib/broker/server.py"
grep -q '`~/.fieldwork/agent.conf`' "$ROOT/docs/agent-adapters.md"
grep -q 'clamped to `1..4`' "$ROOT/docs/agent-adapters.md"
grep -q '12 PRs per hour' "$ROOT/docs/broker-standalone.md"
grep -q 'MaxConnections=4' "$ROOT/docs/runner-architecture.md"

echo "[checks] cage flow string pins"
# the gate marker is greped by onboard's remote-service check; keep them in sync
grep -qF "refusing to serve sessions from the init branch" "$ROOT/lib/scripts/fieldwork-agent-session"
grep -qF "refusing to serve sessions from the init branch" "$ROOT/lib/scripts/fieldwork-onboard"
grep -qF "GATED_UNTIL_INIT_MERGE" "$ROOT/lib/scripts/fieldwork-onboard"
grep -q -- "--session-probe" "$ROOT/bin/fieldwork"
grep -qF "parked on fieldwork/init" "$ROOT/bin/fieldwork"
grep -qF "bwrap: No permissions" "$ROOT/lib/templates/repo/.claude/skills/verify-before-pr/SKILL.md"
grep -qF "bwrap: No permissions" "$ROOT/lib/templates/repo/.claude/skills/pr-delivery/SKILL.md"
grep -qF "prefix match" "$ROOT/lib/templates/repo/AGENTS.md"
test -x "$ROOT/lib/scripts/fieldwork-session-probe"
bash -n "$ROOT/lib/scripts/fieldwork-session-probe"
grep -qF "probe=pass" "$ROOT/lib/scripts/fieldwork-session-probe"
grep -qF "probe=fail" "$ROOT/lib/scripts/fieldwork-session-probe"
grep -qF "probe=inconclusive" "$ROOT/lib/scripts/fieldwork-session-probe"

echo "[checks] ok"
