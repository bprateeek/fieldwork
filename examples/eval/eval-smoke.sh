#!/usr/bin/env bash
set -euo pipefail

ROOT="/workspace"
export PATH="$ROOT/examples/eval:$PATH"
export FIELDWORK_BROKER_COMMAND_PATH="$ROOT/examples/eval:/usr/bin:/bin"
export FIELDWORK_BROKER_PROJECTS_ROOT="${FIELDWORK_BROKER_PROJECTS_ROOT:-$ROOT/.eval/projects}"
export FIELDWORK_BROKER_LEDGER_DIR="${FIELDWORK_BROKER_LEDGER_DIR:-$ROOT/.eval/state/requests}"
export FIELDWORK_BROKER_PENDING_DIR="${FIELDWORK_BROKER_PENDING_DIR:-$ROOT/.eval/state/pending}"
export FIELDWORK_BROKER_AUDIT_LOG_PATH="${FIELDWORK_BROKER_AUDIT_LOG_PATH:-$ROOT/.eval/state/audit.jsonl}"
export FIELDWORK_BROKER_TOKEN_PATH="${FIELDWORK_BROKER_TOKEN_PATH:-$ROOT/.eval/state/fake-token}"
export FIELDWORK_BROKER_ASKPASS_PATH="${FIELDWORK_BROKER_ASKPASS_PATH:-$ROOT/lib/broker/git-askpass}"
export FIELDWORK_BROKER_SCHEMA_PATH="$ROOT/schema/pr-request.schema.json"
# Exercise the M1 daily-driver loop on PAT mode: lifecycle envelope drop +
# worktree-aware poller + dashboard snapshot. Set before server.py import; the
# broker reads these env vars at module load.
export FIELDWORK_BROKER_NOTIFICATIONS_DIR="${FIELDWORK_BROKER_NOTIFICATIONS_DIR:-$ROOT/.eval/state/notifications}"
export FIELDWORK_BROKER_NOTIFY_LIFECYCLE="${FIELDWORK_BROKER_NOTIFY_LIFECYCLE:-minimal}"

mkdir -p "$FIELDWORK_BROKER_PROJECTS_ROOT" "$FIELDWORK_BROKER_LEDGER_DIR" "$FIELDWORK_BROKER_PENDING_DIR" "$FIELDWORK_BROKER_NOTIFICATIONS_DIR" "$(dirname "$FIELDWORK_BROKER_AUDIT_LOG_PATH")"
printf 'github_pat_eval\n' > "$FIELDWORK_BROKER_TOKEN_PATH"
rm -f "$FIELDWORK_BROKER_AUDIT_LOG_PATH"
find "$FIELDWORK_BROKER_LEDGER_DIR" "$FIELDWORK_BROKER_PENDING_DIR" "$FIELDWORK_BROKER_NOTIFICATIONS_DIR" -type f -delete 2>/dev/null || true
rm -rf "$ROOT/.eval/state/poller-home"

repo="$FIELDWORK_BROKER_PROJECTS_ROOT/throwaway"
rm -rf "$repo"
mkdir -p "$repo/.fieldwork"
git -C "$repo" init -q
git -C "$repo" config user.email eval@example.com
git -C "$repo" config user.name "Fieldwork Eval"
printf 'hello eval\n' > "$repo/README.md"
printf 'https://github.com/eval/throwaway.git\n' > "$repo/.fieldwork/expected-origin"
printf 'main\n' > "$repo/.fieldwork/default-branch"
: > "$repo/.fieldwork/approval-gate"
git -C "$repo" remote add origin git@github-eval:eval/throwaway.git
git -C "$repo" add .
git -C "$repo" commit -m init >/dev/null
git -C "$repo" checkout -b fieldwork/eval-smoke >/dev/null 2>&1
printf 'broker eval\n' > "$repo/eval.md"
git -C "$repo" add eval.md
git -C "$repo" commit -m "chore: eval smoke" >/dev/null

python3 - <<'PY'
import importlib.util
import json
import os
import sys
import uuid
from pathlib import Path
from unittest.mock import patch

root = Path("/workspace")
spec = importlib.util.spec_from_file_location("fieldwork_broker_server", root / "lib/broker/server.py")
server = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = server
spec.loader.exec_module(server)

repo = Path(os.environ["FIELDWORK_BROKER_PROJECTS_ROOT"]) / "throwaway"
request_id = str(uuid.uuid4())
req = {
    "request_id": request_id,
    "created_at": "2026-05-20T00:00:00Z",
    "repo_path": str(repo),
    "branch": "fieldwork/eval-smoke",
    "title": "chore: eval smoke",
    "body": "Summary:\n- Exercise Fieldwork eval broker flow.\n\nTests:\n- fieldwork eval smoke",
}

validated = server.validate(req)
server.audit_event(
    "request_received",
    request_id=validated.request_id,
    repo=validated.project,
    repo_path_slug=Path(validated.repo_path).name,
    branch=validated.branch,
    base_branch=validated.base_branch,
    actor="eval",
    transport="docker",
)
server.reserve_request_id(validated)
expires_at = server.queue_pending(validated)
server.audit_event(
    "request_queued",
    request_id=validated.request_id,
    repo=validated.project,
    repo_path_slug=Path(validated.repo_path).name,
    branch=validated.branch,
    base_branch=validated.base_branch,
    actor="eval",
    transport="docker",
    status="queued",
    expires_at=expires_at,
)

def fake_push(req):
    server.audit_event(
        "push_attempted",
        request_id=req.request_id,
        repo=req.project,
        repo_path_slug=Path(req.repo_path).name,
        branch=req.branch,
        base_branch=req.base_branch,
        actor="broker",
        transport="fake-github",
    )
    url = "https://github.local/eval/throwaway/pull/1"
    server.audit_event(
        "pr_opened",
        request_id=req.request_id,
        repo=req.project,
        repo_path_slug=Path(req.repo_path).name,
        branch=req.branch,
        base_branch=req.base_branch,
        actor="broker",
        transport="fake-github",
        pr_url=url,
    )
    # The real push path drops a lifecycle notification next to the audit event;
    # reproduce it here since the test patches push_and_open_pr.
    server.notify_lifecycle(
        "pr_opened",
        repo_slug_value=Path(req.repo_path).name,
        request_id=req.request_id,
        branch=req.branch,
        pr_url=url,
    )
    return url

with patch.object(server, "push_and_open_pr", fake_push):
    result = server.approve({"request_id": request_id, "decision": "approve", "chat_id": "eval"})

events = []
for line in Path(os.environ["FIELDWORK_BROKER_AUDIT_LOG_PATH"]).read_text().splitlines():
    if line.strip():
        events.append(json.loads(line))

# --- M1 daily-driver loop integration (PAT mode) --------------------------
# Everything below stays silent on success: eval-smoke stdout must remain a
# single JSON object (developer-preview.sh parses it with json.loads).
import shutil
import subprocess

# 1. The broker dropped a versioned, token-free lifecycle envelope. Select the
#    pr_opened drop explicitly (filenames are random UUIDs, and the lifecycle
#    set may include other events) and assert no drop leaks the token.
notif_dir = Path(os.environ["FIELDWORK_BROKER_NOTIFICATIONS_DIR"])
drops = sorted(notif_dir.glob("*.json"))
assert drops, "no broker lifecycle notification was dropped"
broker_token = Path(os.environ["FIELDWORK_BROKER_TOKEN_PATH"]).read_text().strip()
assert broker_token, "fake broker token is empty"
pr_opened_envelopes = []
for drop in drops:
    raw = drop.read_text()
    assert broker_token not in raw, f"token leaked into notification envelope: {drop.name}"
    parsed = json.loads(raw)
    if parsed.get("event") == "pr_opened":
        pr_opened_envelopes.append(parsed)
assert len(pr_opened_envelopes) == 1, [json.loads(d.read_text()) for d in drops]
envelope = pr_opened_envelopes[0]
assert envelope.get("schema") and envelope.get("dedupe_key"), envelope

# 2. The worktree-aware poller reads the real broker audit log and writes
#    state + journal + resume-context artifacts.
poller_home = root / ".eval/state/poller-home"
shutil.rmtree(poller_home, ignore_errors=True)
poller_env = dict(os.environ)
poller_env.update({
    "HOME": str(poller_home),
    # The poller and snapshot read FIELDWORK_PROJECTS_ROOT; the broker exports
    # the projects root under its own name.
    "FIELDWORK_PROJECTS_ROOT": os.environ["FIELDWORK_BROKER_PROJECTS_ROOT"],
    "FIELDWORK_EVENT_STATE_DIR": str(poller_home / "state"),
    "FIELDWORK_JOURNAL_DIR": str(poller_home / "journals"),
    "FIELDWORK_NOTIFICATIONS_DIR": str(poller_home / "poller-notifications"),
})
subprocess.run(
    [str(root / "lib/scripts/fieldwork-event-poll")],
    env=poller_env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
poller_state = json.loads((poller_home / "state/events/throwaway.json").read_text())
assert poller_state.get("schema_version") == 1, poller_state
assert poller_state["prs"]["fieldwork/eval-smoke"]["number"] == 1, poller_state
assert (poller_home / "journals/throwaway.md").is_file()
assert (poller_home / "state/resume-context/throwaway.md").is_file()

# 3. The dashboard data source (local-only snapshot) sees the repo + audit log.
snapshot = json.loads(subprocess.run(
    [str(root / "lib/scripts/fieldwork-status-snapshot")],
    env=poller_env, check=True, stdout=subprocess.PIPE,
).stdout)
snapshot_slugs = sorted(repo_item["slug"] for repo_item in snapshot["repos"])
assert "throwaway" in snapshot_slugs, snapshot
assert snapshot["audit_readable"], snapshot

# 4. The dashboard request handler serves the real snapshot on GET /api/status
#    and refuses non-GET. Driven in-process (no socket bind) so it runs the real
#    snapshot_json() path end to end; the live 127.0.0.1 bind and routing are
#    covered deterministically by tests/dashboard-tests.py.
import importlib.machinery
import importlib.util

# snapshot_json() runs the snapshot script with the inherited environment.
os.environ.update({
    "FIELDWORK_PROJECTS_ROOT": poller_env["FIELDWORK_PROJECTS_ROOT"],
    "FIELDWORK_EVENT_STATE_DIR": poller_env["FIELDWORK_EVENT_STATE_DIR"],
    "FIELDWORK_JOURNAL_DIR": poller_env["FIELDWORK_JOURNAL_DIR"],
})
dash_loader = importlib.machinery.SourceFileLoader(
    "fieldwork_dashboard_server", str(root / "lib/scripts/fieldwork-dashboard-server")
)
dash_spec = importlib.util.spec_from_loader(dash_loader.name, dash_loader)
dash = importlib.util.module_from_spec(dash_spec)
dash_loader.exec_module(dash)
dash.SNAPSHOT = str(root / "lib/scripts/fieldwork-status-snapshot")

def dashboard_call(req_path, method):
    handler = dash.DashboardHandler.__new__(dash.DashboardHandler)
    handler.path = req_path
    sent = {}
    handler.send_bytes = lambda status, ctype, body: sent.update(status=status, body=body)
    getattr(handler, "do_" + method)()
    return sent["status"], sent["body"]

api_status, api_body = dashboard_call("/api/status", "GET")
assert api_status == 200, (api_status, api_body)
api_payload = json.loads(api_body)
assert any(r.get("slug") == "throwaway" for r in api_payload.get("repos", [])), api_payload
index_status, _ = dashboard_call("/", "GET")
assert index_status == 200, index_status
dashboard_post_status, _ = dashboard_call("/api/status", "POST")
assert dashboard_post_status == 405, dashboard_post_status

print(json.dumps({
    "ok": bool(result.get("ok")),
    "mode": "eval",
    "decision": result.get("decision"),
    "repo": "eval/throwaway",
    "branch": "fieldwork/eval-smoke",
    "request_id": request_id,
    "pr_url": result.get("url"),
    "events": events,
    "m1": {
        "lifecycle_envelope_event": envelope["event"],
        "poller_pr_number": poller_state["prs"]["fieldwork/eval-smoke"]["number"],
        "snapshot_repos": snapshot_slugs,
        "dashboard_post_status": dashboard_post_status,
    },
}, sort_keys=True))
PY
