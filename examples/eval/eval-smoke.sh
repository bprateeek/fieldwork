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

mkdir -p "$FIELDWORK_BROKER_PROJECTS_ROOT" "$FIELDWORK_BROKER_LEDGER_DIR" "$FIELDWORK_BROKER_PENDING_DIR" "$(dirname "$FIELDWORK_BROKER_AUDIT_LOG_PATH")"
printf 'github_pat_eval\n' > "$FIELDWORK_BROKER_TOKEN_PATH"
rm -f "$FIELDWORK_BROKER_AUDIT_LOG_PATH"
find "$FIELDWORK_BROKER_LEDGER_DIR" "$FIELDWORK_BROKER_PENDING_DIR" -type f -delete 2>/dev/null || true

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
    repo=f"{validated.owner}/{validated.repo}",
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
    repo=f"{validated.owner}/{validated.repo}",
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
        repo=f"{req.owner}/{req.repo}",
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
        repo=f"{req.owner}/{req.repo}",
        repo_path_slug=Path(req.repo_path).name,
        branch=req.branch,
        base_branch=req.base_branch,
        actor="broker",
        transport="fake-github",
        pr_url=url,
    )
    return url

with patch.object(server, "push_and_open_pr", fake_push):
    result = server.approve({"request_id": request_id, "decision": "approve", "chat_id": "eval"})

events = []
for line in Path(os.environ["FIELDWORK_BROKER_AUDIT_LOG_PATH"]).read_text().splitlines():
    if line.strip():
        events.append(json.loads(line))

print(json.dumps({
    "ok": bool(result.get("ok")),
    "mode": "eval",
    "decision": result.get("decision"),
    "repo": "eval/throwaway",
    "branch": "fieldwork/eval-smoke",
    "request_id": request_id,
    "pr_url": result.get("url"),
    "events": events,
}, sort_keys=True))
PY
