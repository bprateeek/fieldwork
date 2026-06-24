#!/usr/bin/env bash
# Tests for the one_shot_job task pipeline: fieldwork-task-run (the runner) and
# fieldwork-task-dispatcher (the scheduler). No real bwrap/aider/broker: a fake
# bwrap honours --setenv/--chdir and the adapter bind then execs the inner
# command; a fake aider edits the worktree; fake prepare/verify/submit clients
# stand in for the broker path.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

make_env() {
  # $1 = scenario tag. Echoes the temp HOME.
  local home; home="$(mktemp -d "${TMPDIR:-/tmp}/fwtask.XXXXXX")"
  local slug="web"
  mkdir -p "$home/.local/bin" "$home/.fieldwork/infra/agents" "$home/.fieldwork/agents" \
           "$home/projects/$slug" "$home/spool/queue" "$home/spool/processing" \
           "$home/spool/done" "$home/spool/failed" "$home/spool/locks" "$home/notifications"

  # Repo on main with an initial commit + the .fieldwork plumbing.
  git -C "$home/projects/$slug" init -q -b main
  git -C "$home/projects/$slug" config user.email t@e.st
  git -C "$home/projects/$slug" config user.name tester
  git -C "$home/projects/$slug" config core.hooksPath /dev/null  # silence host pre-commit hooks in tests
  mkdir -p "$home/projects/$slug/.fieldwork/local"
  printf 'main\n' > "$home/projects/$slug/.fieldwork/default-branch"
  printf 'https://github.com/o/web.git\n' > "$home/projects/$slug/.fieldwork/expected-origin"
  printf '.fieldwork/local/\nnode_modules/\n' > "$home/projects/$slug/.gitignore"
  printf 'hello\n' > "$home/projects/$slug/README.md"
  git -C "$home/projects/$slug" add -A >/dev/null
  git -C "$home/projects/$slug" commit -qm init

  # aider.conf with a secret to assert redaction.
  cat > "$home/.fieldwork/aider.conf" <<EOF
model = gpt-test
base_url = https://model.example/v1
api_key = sk-SUPERSECRET123
EOF

  # Real adapter, declared one_shot_job.
  ln -sf "$ROOT/lib/agents/aider" "$home/.fieldwork/infra/agents/aider"

  # Fake bwrap: apply --setenv, --chdir, map the adapter bind, exec after `--`.
  cat > "$home/.local/bin/bwrap" <<'BWRAP'
#!/usr/bin/env bash
env_args=(); chdir=""; adapter_src=""
while [ $# -gt 0 ]; do
  case "$1" in
    --setenv) env_args+=("$2=$3"); shift 3 ;;
    --chdir) chdir="$2"; shift 2 ;;
    --ro-bind) [ "$3" = "/tmp/fieldwork-adapter" ] && adapter_src="$2"; shift 3 ;;
    --bind|--symlink) shift 3 ;;
    --tmpfs|--dir|--proc|--dev) shift 2 ;;
    --clearenv|--unshare-pid|--unshare-ipc|--unshare-uts|--unshare-user|--new-session|--die-with-parent) shift ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
cmd=("$@")
for i in "${!cmd[@]}"; do [ "${cmd[$i]}" = "/tmp/fieldwork-adapter" ] && cmd[$i]="$adapter_src"; done
[ -n "$chdir" ] && cd "$chdir"
# Simulate --clearenv but keep FAKE_AIDER_MODE so the fake aider can branch.
exec env -i HOME="${HOME}" FAKE_AIDER_MODE="${FAKE_AIDER_MODE:-}" "${env_args[@]}" "${cmd[@]}"
BWRAP
  chmod +x "$home/.local/bin/bwrap"

  # Fake aider: behaviour from FAKE_AIDER_MODE.
  cat > "$home/.local/bin/fake-aider" <<'AIDER'
#!/usr/bin/env bash
# Receives aider flags; FIELDWORK_TASK_PROMPT_FILE + model env are set.
case "${FAKE_AIDER_MODE:-edit}" in
  edit)       printf 'patched by aider\n' >> README.md ;;
  noop)       : ;;
  control)    mkdir -p .claude; printf 'x\n' > .claude/evil.md ;;
  gittamper)  printf '[core]\n\tpager = evil\n' >> .git/config ;;
  ignored)    mkdir -p node_modules; printf 'k\n' > node_modules/.cache ;;
  secretfile) printf 'AWS=1\n' > .env.leak ;;  # ignored? no - .env.leak not in .gitignore
esac
# Echo the secret to stdout to test log redaction.
echo "model key seen: ${OPENAI_API_KEY:-none}"
exit 0
AIDER
  chmod +x "$home/.local/bin/fake-aider"

  # Fake broker clients.
  cat > "$home/.local/bin/fieldwork-pr-prepare" <<'PREP'
#!/usr/bin/env bash
req="$1"; repo="$(git rev-parse --show-toplevel)"
branch="$(jq -r .branch "$req")"; msg="$(jq -r .message "$req")"
paths=(); while IFS= read -r p; do paths+=("$p"); done < <(jq -r '.paths[]' "$req")
G=(git -c core.hooksPath=/dev/null)
"${G[@]}" checkout -q -b "$branch" || exit 12
"${G[@]}" add -- "${paths[@]}" || exit 12
"${G[@]}" -c user.email=b@r.k -c user.name=broker commit -q -F - <<EOF || exit 12
$msg
EOF
echo '{"head":"abc","branch":"'"$branch"'"}'
PREP
  chmod +x "$home/.local/bin/fieldwork-pr-prepare"

  cat > "$home/.local/bin/fieldwork-verify" <<'VER'
#!/usr/bin/env bash
exit "${FAKE_VERIFY_RC:-0}"
VER
  chmod +x "$home/.local/bin/fieldwork-verify"

  cat > "$home/.local/bin/fieldwork-pr-submit" <<'SUB'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_SUBMIT_JSON:-{\"ok\":true,\"request_id\":\"r1\",\"url\":\"http://pr/1\"}}"
exit 0
SUB
  chmod +x "$home/.local/bin/fieldwork-pr-submit"

  printf '%s\n' "$home"
}

# Build a claimed (processing) task dir and run the runner. Echoes runner rc.
run_one() {
  local home="$1" prompt="${2:-do the thing}"
  local id; id="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '-' || echo deadbeefdeadbeefdeadbeefdeadbeef)"
  local td="$home/spool/processing/web-${id:0:12}"
  mkdir -p "$td"
  printf '{"id":"%s","slug":"web","profile":null,"actor":"cli","source":"cli","schema_version":1}\n' "$id" > "$td/task.json"
  printf '%s' "$prompt" > "$td/prompt.txt"
  HOME="$home" PATH="$home/.local/bin:$PATH" \
    FIELDWORK_PROJECTS_ROOT="$home/projects" \
    FIELDWORK_TASKS_DIR="$home/spool" \
    FIELDWORK_NOTIFICATIONS_DIR="$home/notifications" \
    FIELDWORK_BROKER_AUDIT_LOG="$home/audit.jsonl" \
    FIELDWORK_AIDER_BIN="$home/.local/bin/fake-aider" \
    "$ROOT/lib/scripts/fieldwork-task-run" "$td"
  echo "rc=$?"
}

echo "[task] scenario: happy path (non-gated)"
H="$(make_env happy)"
out="$(FAKE_AIDER_MODE=edit run_one "$H" "fix the login bug")"
rc="${out##*rc=}"
[ "$rc" = 0 ] && pass "runner exits 0" || fail "runner rc=$rc"
ls "$H/spool/done/"* >/dev/null 2>&1 && pass "task moved to done/" || fail "task not in done/"
[ -z "$(git -C "$H/projects/web" status --porcelain)" ] && pass "checkout clean after run" || fail "checkout dirty"
[ "$(git -C "$H/projects/web" rev-parse --abbrev-ref HEAD)" = main ] && pass "checkout restored to main" || fail "not on main"
runlog="$(cat "$H/spool/done/"*/run.log 2>/dev/null)"
case "$runlog" in *sk-SUPERSECRET123*) fail "api_key leaked in run.log" ;; *"[redacted]"*) pass "api_key redacted in run.log" ;; *) fail "redaction marker missing" ;; esac
# prompt text must not appear in the commit message of the pushed branch
msgs="$(git -C "$H/projects/web" log --all --format=%B 2>/dev/null)"
case "$msgs" in *"fix the login bug"*) fail "raw prompt leaked into commit" ;; *) pass "prompt absent from commit message" ;; esac
rm -rf "$H"

echo "[task] scenario: no changes"
H="$(make_env noop)"
out="$(FAKE_AIDER_MODE=noop run_one "$H")"; rc="${out##*rc=}"
[ "$rc" = 0 ] && pass "no-diff exits 0" || fail "rc=$rc"
ls "$H/spool/done/"*/state.json >/dev/null 2>&1 && grep -q no_changes "$H/spool/done/"*/state.json && pass "outcome no_changes" || fail "not no_changes"
rm -rf "$H"

echo "[task] scenario: verify fails -> no submit"
H="$(make_env verify)"
out="$(FAKE_AIDER_MODE=edit FAKE_VERIFY_RC=1 run_one "$H")"; rc="${out##*rc=}"
[ "$rc" = 1 ] && pass "verify-fail exits 1" || fail "rc=$rc"
ls "$H/spool/failed/"*/diff.patch >/dev/null 2>&1 && pass "diff.patch captured on failure" || fail "no diff.patch"
[ "$(git -C "$H/projects/web" rev-parse --abbrev-ref HEAD)" = main ] && pass "restored to main after verify-fail" || fail "not restored"
rm -rf "$H"

echo "[task] scenario: control-path edit refused"
H="$(make_env control)"
out="$(FAKE_AIDER_MODE=control run_one "$H")"; rc="${out##*rc=}"
[ "$rc" = 1 ] && pass "control-path exits 1" || fail "rc=$rc"
grep -q "control-path" "$H/spool/failed/"*/state.json 2>/dev/null && pass "refused control-path edit" || fail "control-path not refused"
# The refused (untracked) .claude/evil.md must be cleaned so the checkout is not
# left dirty (which would defer all future tasks for the slug).
[ -z "$(git -C "$H/projects/web" status --porcelain)" ] && pass "checkout clean after control-path failure" || fail "checkout left dirty after control-path failure"
rm -rf "$H"

echo "[task] scenario: .git tamper caught by snapshot backstop"
H="$(make_env gittamper)"
out="$(FAKE_AIDER_MODE=gittamper run_one "$H")"; rc="${out##*rc=}"
[ "$rc" = 1 ] && pass ".git tamper exits 1" || fail "rc=$rc"
grep -q "\.git config/hooks/info changed" "$H/spool/failed/"*/state.json 2>/dev/null && pass ".git tamper caught" || fail ".git tamper not caught"
rm -rf "$H"

echo "[task] scenario: gated -> approval pushes, checkout held then restored"
H="$(make_env gated)"
# The approval-gate marker is committed (pre-existing), not a task change.
touch "$H/projects/web/.fieldwork/approval-gate"
git -C "$H/projects/web" add .fieldwork/approval-gate
git -C "$H/projects/web" commit -qm "enable approval gate"
# submit returns queued; pre-seed the audit log with pr_opened so the wait ends fast
printf '{"event":"pr_opened","request_id":"r1"}\n' > "$H/audit.jsonl"
out="$(FAKE_AIDER_MODE=edit FAKE_SUBMIT_JSON='{"ok":true,"queued":true,"request_id":"r1","expires_at":"2099-01-01T00:00:00Z"}' \
  FIELDWORK_TASK_APPROVAL_GRACE=1 run_one "$H")"; rc="${out##*rc=}"
[ "$rc" = 0 ] && pass "gated approval exits 0" || fail "rc=$rc"
grep -q '"outcome": "success"' "$H/spool/done/"*/state.json 2>/dev/null && pass "gated success after pr_opened" || fail "gated outcome wrong"
[ "$(git -C "$H/projects/web" rev-parse --abbrev-ref HEAD)" = main ] && pass "checkout restored after approval" || fail "not restored"
rm -rf "$H"

echo "[dispatch] scenario: per-slug serial + capacity + claim + recovery"
H="$(make_env disp)"
# Fake runner: records invocation, sleeps briefly, moves dir to done.
cat > "$H/.local/bin/fake-run" <<'FR'
#!/usr/bin/env bash
td="$1"; echo "$(basename "$td")" >> "$FRLOG"
sleep 0.5
mkdir -p "$(dirname "$td")/../done"
mv "$td" "$(dirname "$td")/../done/"
FR
chmod +x "$H/.local/bin/fake-run"
# Two queued tasks for the SAME slug; capacity 4. Per-slug serial => only 1 runs this pass.
for n in 1 2; do
  d="$H/spool/queue/web-aaaaaaaaaaa$n"; mkdir -p "$d"
  printf '{"id":"aaaaaaaaaaaa000%s","slug":"web"}\n' "$n" > "$d/task.json"
  printf 'p\n' > "$d/prompt.txt"
done
# A leftover processing dir simulates a crash, for recovery.
mkdir -p "$H/spool/processing/web-crashed01"; printf '{"id":"crashed","slug":"web"}\n' > "$H/spool/processing/web-crashed01/task.json"
dispatch_once() {
  FRLOG="$H/fr.log" HOME="$H" PATH="$H/.local/bin:$PATH" \
    FIELDWORK_PROJECTS_ROOT="$H/projects" FIELDWORK_TASKS_DIR="$H/spool" \
    FIELDWORK_AGENT_CAPACITY=4 FIELDWORK_TASK_RUN_BIN="$H/.local/bin/fake-run" \
    FIELDWORK_TASK_DISPATCH_ONCE=1 \
    "$ROOT/lib/scripts/fieldwork-task-dispatcher" 2>/dev/null
}
dispatch_once
sleep 1
ls "$H/spool/failed/web-crashed01"*/recovery.json >/dev/null 2>&1 && pass "crash recovery moved stale task to failed" || fail "no recovery"
started="$(wc -l < "$H/fr.log" 2>/dev/null | tr -d ' ')"
[ "${started:-0}" = 1 ] && pass "per-slug serial: only 1 of 2 same-slug tasks claimed (clean checkout)" || fail "claimed $started same-slug tasks"

echo "[dispatch] scenario: defer while the checkout is dirty"
H="$(make_env dispdirty)"
cat > "$H/.local/bin/fake-run" <<'FR'
#!/usr/bin/env bash
echo "$(basename "$1")" >> "$FRLOG"; mkdir -p "$(dirname "$1")/../done"; mv "$1" "$(dirname "$1")/../done/"
FR
chmod +x "$H/.local/bin/fake-run"
printf 'uncommitted\n' >> "$H/projects/web/README.md"   # dirty the checkout
d="$H/spool/queue/web-bbbbbbbbbbbb"; mkdir -p "$d"
printf '{"id":"bbbbbbbbbbbb0001","slug":"web"}\n' > "$d/task.json"; printf 'p\n' > "$d/prompt.txt"
FRLOG="$H/fr.log" HOME="$H" PATH="$H/.local/bin:$PATH" \
  FIELDWORK_PROJECTS_ROOT="$H/projects" FIELDWORK_TASKS_DIR="$H/spool" \
  FIELDWORK_AGENT_CAPACITY=4 FIELDWORK_TASK_RUN_BIN="$H/.local/bin/fake-run" \
  FIELDWORK_TASK_DISPATCH_ONCE=1 "$ROOT/lib/scripts/fieldwork-task-dispatcher" 2>/dev/null
sleep 1
[ -d "$H/spool/queue/web-bbbbbbbbbbbb" ] && [ ! -f "$H/fr.log" ] && pass "dirty checkout deferred (task stays queued)" || fail "task claimed despite dirty checkout"
rm -rf "$H"

echo "[enqueue] scenario: framed stdin, validation, atomic write"
SP="$(mktemp -d "${TMPDIR:-/tmp}/fwenq.XXXXXX")"
mkdir -p "$SP/queue"
ENQ="$ROOT/lib/scripts/fieldwork-task-enqueue"
id="$(printf '{"slug":"web","profile":"","prompt_bytes":7,"source":"cli","actor":"cli"}\nfix bug' | FIELDWORK_TASKS_DIR="$SP" python3 "$ENQ" 2>/dev/null)"
[ -f "$SP/queue/$id/task.json" ] && [ -f "$SP/queue/$id/prompt.txt" ] && pass "enqueue writes task.json + prompt.txt" || fail "enqueue did not create task dir"
[ "$(cat "$SP/queue/$id/prompt.txt")" = "fix bug" ] && pass "prompt body intact" || fail "prompt body wrong"
# Group-permissive modes (umask-proof) so a cross-user ACL mask stays open and
# the dispatcher (a different user in prod) can claim bot-created tasks.
md="$(stat -c %a "$SP/queue/$id" 2>/dev/null || stat -f %Lp "$SP/queue/$id")"
[ "$md" = 770 ] && pass "task dir mode 0770 (ACL-mask safe)" || fail "task dir mode=$md (expected 770)"
mf="$(stat -c %a "$SP/queue/$id/task.json" 2>/dev/null || stat -f %Lp "$SP/queue/$id/task.json")"
[ "$mf" = 660 ] && pass "task.json mode 0660 (ACL-mask safe)" || fail "task.json mode=$mf (expected 660)"
printf '{"slug":"Bad","prompt_bytes":3,"source":"cli"}\nabc' | FIELDWORK_TASKS_DIR="$SP" python3 "$ENQ" >/dev/null 2>&1
[ "$?" -ne 0 ] && pass "enqueue rejects bad slug" || fail "bad slug accepted"
printf '{"slug":"web","prompt_bytes":99,"source":"cli"}\nshort' | FIELDWORK_TASK_PROMPT_MAX_BYTES=5 FIELDWORK_TASKS_DIR="$SP" python3 "$ENQ" >/dev/null 2>&1
[ "$?" -ne 0 ] && pass "enqueue rejects oversize before buffering" || fail "oversize accepted"
ls "$SP/queue" | grep -q '^\.tmp' && fail "temp dir leaked" || pass "no temp dir leak"
rm -rf "$SP"

echo
[ "$FAILS" -eq 0 ] && { echo "task-dispatcher-tests: ALL PASS"; exit 0; } || { echo "task-dispatcher-tests: $FAILS FAILED"; exit 1; }
