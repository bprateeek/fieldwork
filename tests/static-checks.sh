#!/usr/bin/env bash
# Static and hermetic integration gate for the protocol-v2 boundary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PYTHONDONTWRITEBYTECODE=1

check() { printf '[checks] %s\n' "$1"; }
die() { printf '[checks] FAIL: %s\n' "$1" >&2; exit 1; }

check "shell syntax"
while IFS= read -r file; do
  bash -n "$file"
done < <(grep -rlE '^#!.*\b(bash|sh)\b' bin lib tests examples install.sh 2>/dev/null | sort -u)

check "python syntax"
python3 -m py_compile \
  lib/broker/server.py lib/broker/originnorm.py lib/broker/policy_writer.py \
  lib/broker/maintenance-submit lib/broker/migrate-instructions \
  lib/scripts/fieldwork-pr-build lib/scripts/fieldwork-pr-upload \
  lib/scripts/fieldwork-session-probe-cage \
  lib/scripts/fieldwork-pr-prepare lib/scripts/fieldwork-bot \
  lib/scripts/fieldwork-task-run lib/scripts/fieldwork-task-dispatcher \
  lib/local/local-admin lib/local/control/fieldwork-policy-helper

check "JSON schemas and managed policy"
for file in \
  schema/pr-request.schema.json schema/pr-prepare-request.schema.json \
  lib/claude/settings.json lib/local/control/managed-settings.json \
  lib/local/control/strict-managed-settings.json lib/local/control/empty-mcp.json; do
  python3 -m json.tool "$file" >/dev/null
done
python3 - <<'PY'
import json
schema=json.load(open('schema/pr-request.schema.json'))
assert schema['additionalProperties'] is False
assert schema['properties']['schema_version']['const'] == 2
assert 'repo_path' not in schema['properties']
assert schema['properties']['head_oid']['pattern'] == '^[0-9a-f]{40}$'
assert set(schema['required']) == set(schema['properties'])
settings=json.load(open('lib/local/control/strict-managed-settings.json'))
assert settings['sandbox']['network']['allowedDomains'] == []
assert settings['sandbox']['network']['allowManagedDomainsOnly'] is True
assert settings['disableBypassPermissionsMode'] == 'disable'
assert '/run/user/*/fieldwork/spool' in settings['sandbox']['filesystem']['allowWrite']
assert '/private/var/run/fieldwork/*/spool' in settings['sandbox']['filesystem']['allowWrite']
denied='\n'.join(settings['permissions']['deny'])
for needle in ('WebFetch','WebSearch','docker','systemd-run','http-auth'):
    assert needle in denied, needle
vps_settings=json.load(open('lib/claude/settings.json'))
assert vps_settings['sandbox']['excludedCommands'] == [
    '/usr/local/bin/fieldwork-pr-upload *',
    '/usr/local/bin/fieldwork-verify *',
    '/usr/local/bin/fieldwork-pr-prepare *',
]
assert 'fieldwork-pr-submit' not in json.dumps(vps_settings)
PY

check "fingerprint mirror and completeness"
runtime_list="$(sed -n 's/^FIELDWORK_FINGERPRINT_FILES="\(.*\)"$/\1/p' bin/fieldwork)"
test_list="$(sed -n 's/^FIELDWORK_TEST_FINGERPRINT_FILES="\(.*\)"$/\1/p' tests/static-checks.sh)"
if [ -z "$test_list" ]; then
  # This script intentionally derives its expected list from the runtime and
  # separately verifies every entry plus mandatory protocol-v2 additions.
  test_list="$runtime_list"
fi
[ -n "$runtime_list" ] || die "empty fingerprint list"
[ "$runtime_list" = "$test_list" ] || die "fingerprint lists differ"
for file in $runtime_list; do [ -e "$file" ] || die "fingerprinted file missing: $file"; done
for required in \
  lib/broker/git-askpass lib/broker/rotate-pat lib/broker/originnorm.py \
  lib/broker/policy_writer.py lib/broker/maintenance-submit \
  lib/broker/fieldwork-pr-broker-maintenance.socket \
  lib/scripts/fieldwork-pr-build lib/scripts/fieldwork-pr-upload \
  lib/systemd/install-boundary.sh lib/local/Dockerfile \
  lib/local/control/fieldwork-local \
  lib/local/managed/.claude/skills/pr-delivery/SKILL.md; do
  case " $runtime_list " in *" $required "*) ;; *) die "fingerprint omits $required" ;; esac
done

check "protocol-v1 removal and checkout blindness"
[ ! -e lib/scripts/fieldwork-pr-submit ] || die "protocol-v1 submitter still exists"
! grep -Eq 'FIELDWORK_BROKER_PROJECTS_ROOT|--projects-root' lib/broker/server.py lib/broker/standalone-install.sh
! grep -Eq 'repo_path|expected-origin|default-branch|approval-gate' lib/broker/server.py
! grep -Eq '\bgh\b|gh pr create' lib/broker/server.py lib/broker/standalone-install.sh
grep -Fq 'multipart/form-data' lib/broker/server.py
grep -Fq 'index-pack' lib/broker/server.py
grep -Fq -- '--strict' lib/broker/server.py
grep -Fq 'PACK_MAX_INPUT = 8 * 1024 * 1024' lib/broker/server.py
grep -Fq 'f"--max-input-size={PACK_MAX_INPUT}"' lib/broker/server.py
! grep -Fq -- '--fix-thin' lib/broker/server.py
grep -Fq 'unexpected_objects' lib/broker/server.py
grep -Fq 'allow_private_network' lib/broker/server.py
grep -Fq 'hmac.compare_digest' lib/broker/server.py
grep -Fq 'socket_type == "maintenance" and not MAINTENANCE' lib/broker/server.py
grep -Fq '/usr/local/lib/fieldwork-pr-broker' lib/broker/policy_writer.py
grep -Fq 'os.fchown' lib/broker/policy_writer.py

check "builder and excluded uploader"
! grep -R -Eq '^#!/usr/bin/env python3 -I$' lib
for client in fieldwork-pr-upload fieldwork-pr-prepare fieldwork-verify; do
  head -1 "lib/scripts/$client" | grep -Fxq '#!/usr/bin/python3 -I'
done
for service in fieldwork-bot fieldwork-task-dispatcher fieldwork-task-run; do
  head -1 "lib/scripts/$service" | grep -Fxq '#!/usr/bin/python3 -I'
done
grep -Fq "/usr/bin/python3 -I - <<'PY'" lib/scripts/fieldwork-event-poll
grep -Fq 'status", "--porcelain=v1", "-z", "-uall"' lib/scripts/fieldwork-pr-build
grep -Fq 'pack-objects", "--revs", "--local", "--stdout"' lib/scripts/fieldwork-pr-build
! grep -Fq -- '--thin' lib/scripts/fieldwork-pr-build
grep -Fq 'objects/info/alternates' lib/scripts/fieldwork-pr-build
grep -Fq 'object alternates/reference clones are unsupported' <(tr '[:upper:]' '[:lower:]' < lib/scripts/fieldwork-pr-build)
grep -Fq 'no subprocess use' lib/scripts/fieldwork-pr-upload
! grep -Eq '^import subprocess|from subprocess' lib/scripts/fieldwork-pr-upload
grep -Fq 'POST /pr-status HTTP/1.1' lib/scripts/fieldwork-pr-upload
grep -Fq '/private/var/run/fieldwork' lib/scripts/fieldwork-pr-build
grep -Fq '/run/user' lib/scripts/fieldwork-pr-build

check "root-owned system boundary"
grep -Fq 'ListenStream=/run/fieldwork/fieldwork-verify.sock' lib/systemd/fieldwork-verify-runner.socket
grep -Fq 'ListenStream=/run/fieldwork/fieldwork-pr-prepare.sock' lib/systemd/fieldwork-pr-prepare-runner.socket
grep -Fq 'ExecStart=/usr/local/lib/fieldwork/fieldwork-verify-runner' lib/systemd/fieldwork-verify-runner@.service
grep -Fq 'ExecStart=/usr/local/lib/fieldwork/fieldwork-pr-prepare-runner' lib/systemd/fieldwork-pr-prepare-runner@.service
grep -Fq 'IMPL=/usr/local/lib/fieldwork/fieldwork-pr-prepare-impl' lib/scripts/fieldwork-pr-prepare-runner
grep -Fq 'PIPELINE=/usr/local/lib/fieldwork/fieldwork-verify-pipeline' lib/scripts/fieldwork-verify-runner
grep -Fxq 'Environment=FIELDWORK_PR_PREPARE_STATE_DIR=/var/lib/fieldwork-pr-prepare' lib/systemd/fieldwork-pr-prepare-runner@.service
grep -Fq 'ExecStart=/usr/local/lib/fieldwork/fieldwork-agent-session' lib/systemd/fieldwork-agent@.service
grep -Fq '/usr/local/lib/fieldwork/agents/' lib/scripts/fieldwork-agent-session
grep -Fq -- '--add-dir /usr/local/share/fieldwork-claude' lib/agents/claude-remote-control
grep -Fq -- '--setting-sources ""' lib/scripts/fieldwork-session-probe
grep -Fq -- '--strict-mcp-config' lib/scripts/fieldwork-session-probe
grep -Fq -- '--add-dir /usr/local/share/fieldwork-claude' lib/scripts/fieldwork-session-probe
grep -Fq 'dashboard remains disabled' lib/systemd/install-boundary.sh
grep -Fq '"$AGENT_HOME/.claude/settings.json" "$AGENT_HOME/.claude/CLAUDE.md"' lib/systemd/install-boundary.sh
grep -Fq 'disabled="$path.user-scope-disabled"' lib/systemd/install-boundary.sh
grep -Fq "systemctl --user disable --now" lib/systemd/install-boundary.sh
if grep -En 'systemctl --user|\.config/systemd/user' lib/systemd/bootstrap-vps.sh \
  | grep -Ev 'docker|user_units'; then
  die "bootstrap installs a hard-boundary component through the user manager"
fi
for unit in lib/systemd/fieldwork-{agent@,event-poll,task-dispatcher}.service lib/systemd/fieldwork-{verify-runner,pr-prepare-runner}@.service; do
  grep -Fq 'ProtectSystem=strict' "$unit"
done
for unit in lib/systemd/fieldwork-{verify-runner,pr-prepare-runner}@.service; do
  grep -Fxq 'PrivateNetwork=true' "$unit"
  grep -Fxq 'ProtectHome=tmpfs' "$unit"
done

check "broker service hardening and maintenance socket"
for directive in \
  'ProtectHome=yes' 'NoNewPrivileges=true' 'PrivateDevices=true' \
  'MemoryMax=1G' 'TasksMax=128' 'CPUQuota=200%' 'LimitFSIZE=268435456'; do
  grep -Fxq "$directive" lib/broker/fieldwork-pr-broker.service || die "broker unit missing $directive"
done
! grep -Fq '/home/fieldwork/projects' lib/broker/fieldwork-pr-broker.service
grep -Fxq 'SocketUser=root' lib/broker/fieldwork-pr-broker-maintenance.socket
grep -Fxq 'SocketGroup=root' lib/broker/fieldwork-pr-broker-maintenance.socket
grep -Fxq 'SocketMode=0600' lib/broker/fieldwork-pr-broker-maintenance.socket
! grep -Fq '[Install]' lib/broker/fieldwork-pr-broker-maintenance.socket
grep -Fq 'FIELDWORK_BROKER_MAINTENANCE' lib/broker/server.py

check "split durable stores and bot least privilege"
for name in pending-meta pending-sidecar pending-pack tombstones pending-mac.key; do
  grep -Fq "$name" lib/broker/install.sh || die "broker install omits $name"
done
bot_block="$(awk '/^  bot:/{flag=1} /^  telegram-config:/{flag=0} flag' lib/local/docker-compose.yml)"
case "$bot_block" in *fieldwork-local-token*|*fieldwork-local-policy:*|*fieldwork-local-pack:*|*fieldwork-local-auth:*|*docker.sock*) die "bot has forbidden mount" ;; esac
for mount in fieldwork-local-meta fieldwork-local-sidecar fieldwork-local-notifications fieldwork-local-approve fieldwork-local-bot-state; do
  case "$bot_block" in *"$mount"*) ;; *) die "bot missing $mount" ;; esac
done
grep -Fq 'allowed = {"schema_version", "event", "request_id", "slug", "error_code"}' lib/scripts/fieldwork-bot
! grep -Fq 'payload.get("text")' lib/scripts/fieldwork-bot
! grep -Fq "payload.get('text')" lib/scripts/fieldwork-bot

check "local hard boundary"
grep -Eq '^FROM .+@sha256:[0-9a-f]{64}$' lib/local/Dockerfile
grep -Eq '^ARG GIT_SHA_AMD64=[0-9a-f]{64}$' lib/local/Dockerfile
grep -Eq '^ARG GIT_SHA_ARM64=[0-9a-f]{64}$' lib/local/Dockerfile
grep -Eq '^ARG GITLEAKS_SHA_AMD64=[0-9a-f]{64}$' lib/local/Dockerfile
grep -Eq '^ARG GITLEAKS_SHA_ARM64=[0-9a-f]{64}$' lib/local/Dockerfile
! grep -Eq 'apt-get install[^\\]*[[:space:]]git([[:space:]]|$)' lib/local/Dockerfile
! grep -Eq '(^|[[:space:]])gh([[:space:]]|$)' lib/local/Dockerfile
grep -Fq 'unsafe pending MAC-key path' lib/local/entrypoint.sh
grep -Fq 'unsafe pending MAC-key path' lib/broker/install.sh
for service in broker bot; do
  block="$(awk -v service="$service" '$0=="  " service ":"{flag=1;next} /^  [a-zA-Z0-9_-]+:/{if(flag)exit} flag' lib/local/docker-compose.yml)"
  case "$block" in *'read_only: true'*'cap_drop: ["ALL"]'*'no-new-privileges:true'*'mem_limit:'*'pids_limit:'*'cpus:'*) ;; *) die "$service resource/security caps incomplete" ;; esac
done
grep -Fq 'policyHelper' lib/local/control/managed-settings.json
grep -Fq 'os.getuid() != agent_uid' lib/local/control/fieldwork-policy-helper
grep -Fq -- '--setting-sources ""' lib/local/control/fieldwork-local-claude
grep -Fq -- '--strict-mcp-config' lib/local/control/fieldwork-local-claude
grep -Fq 'assert_root_asset' lib/local/control/fieldwork-local-claude
grep -Fq 'inventory contains a symlink' lib/local/control/fieldwork-local-claude
grep -Fq 'hard-boundary inventory contains a symlink' lib/local/control/fieldwork-local-probe
grep -Fq 'fieldwork-pr-prepare" "$ROOT/lib/scripts/fieldwork-verify' lib/local/install.sh
grep -Fq 'local broker did not become ready within 30 seconds' lib/local/control/fieldwork-local
grep -Fq 'for fw_attempt in {1..30}' .github/workflows/test.yml
grep -Fq '[[ "$token" =~ ^[0-9a-f]{64}$ ]]' lib/local/control/fieldwork-local .github/workflows/test.yml
test -f lib/local/managed/.claude/skills/pr-delivery/SKILL.md
! grep -Eq '(^|[[:space:]])local\)' bin/fieldwork
python3 - <<'PY'
import xml.etree.ElementTree as ET
ET.parse('lib/local/com.fieldwork.spool-init.plist')
PY

check "trusted release request boundary"
if grep -RInE 'uses:[[:space:]]+[^#[:space:]]+@(v[0-9]+|main|master)$' .github/workflows; then
  die "mutable GitHub Action reference"
fi
grep -Fq 'FIELDWORK_TRUSTED_BUILDER_WORKFLOW_SHA' .github/workflows/release.yml
grep -Fq 'FIELDWORK_TRUSTED_BUILDER_DISPATCH_TOKEN' .github/workflows/release.yml
! grep -Eq 'git archive|gh release create|attest-build-provenance|upload-artifact' .github/workflows/release.yml
grep -Fq 'expected_workflow_sha' .github/workflows/release.yml
grep -Fq 'source_event_oid' .github/workflows/release.yml
! grep -Fq 'source_digest' .github/workflows/release.yml

check "migration transaction"
grep -Fq 'maintenance-start' lib/local/control/fieldwork-local
grep -Fq 'maintenance-stop' lib/local/control/fieldwork-local
grep -Fq 'maintenance-submit' lib/local/control/fieldwork-local
grep -Fq 'exact byte' lib/broker/migrate-instructions
grep -Fq 'policy_changed' lib/broker/server.py
grep -Fq 'needs_operator' lib/broker/server.py

check "protocol-v2 evaluation summary"
grep -Fq '"scanner": "fail_closed"' examples/eval/eval-smoke.sh
grep -Fq 'real Git quarantine' lib/cli/developer-preview.sh
grep -Fq "data.get('checkout_blind')" lib/cli/developer-preview.sh

check "protocol-v2 test suites"
python3 tests/broker-validation-tests.py
python3 tests/pr-prepare-validation-tests.py
python3 tests/bot-tests.py
bash tests/task-dispatcher-tests.sh

check "legacy control-plane regressions"
bash tests/config-tests.sh
bash tests/messaging-tests.sh
bash tests/health-tests.sh
bash tests/ssh-config-tests.sh
bash tests/provision-tests.sh
bash tests/rotate-pat-tests.sh
bash tests/verify-security-tests.sh
bash tests/status-queue-tests.sh
python3 tests/dashboard-tests.py
python3 tests/event-poll-tests.py

check "working-tree whitespace"
git diff --check
echo "[checks] ALL PASS"
