#!/usr/bin/env bash
# Sourced by bin/fieldwork. Developer preview helper commands.

fieldwork_eval() {
  local sub="${1:-}"
  [ -n "$sub" ] && shift || true
  local compose_file="$FIELDWORK_ROOT/examples/eval/docker-compose.yml"
  local project_name="${FIELDWORK_EVAL_PROJECT:-fieldwork-eval}"
  local compose=(docker compose -p "$project_name" -f "$compose_file")

  eval_row() {
    local status="$1"
    local label="$2"
    local detail="${3:-}"
    local mark
    case "$status" in
      ok) mark="✓" ;;
      needs) mark="!" ;;
      skipped) mark="–" ;;
      info) mark="·" ;;
      *) mark="$status" ;;
    esac
    if [ -n "$detail" ]; then
      printf '  %s  %-22s %s\n' "$mark" "$label" "$detail"
    else
      printf '  %s  %s\n' "$mark" "$label"
    fi
  }

  eval_intro() {
    cat <<'EOF'
Fieldwork eval

Evaluation-only Docker harness for trying the broker flow locally.
Uses fake GitHub behavior and no real PAT.
EOF
  }

  eval_docker_ready() {
    command -v docker >/dev/null 2>&1 || return 1
    docker compose version >/dev/null 2>&1 || return 2
    docker info >/dev/null 2>&1 || return 3
    return 0
  }

  eval_docker_preflight() {
    local docker_status="$1"
    echo "Preflight"
    case "$docker_status" in
      0)
        eval_row ok "Docker CLI"
        eval_row ok "Docker Compose"
        eval_row ok "Docker daemon"
        ;;
      1)
        eval_row needs "Docker CLI" "docker command not found"
        ;;
      2)
        eval_row ok "Docker CLI"
        eval_row needs "Docker Compose" "docker compose unavailable"
        ;;
      *)
        eval_row ok "Docker CLI"
        eval_row ok "Docker Compose"
        eval_row needs "Docker daemon" "not reachable"
        ;;
    esac
  }

  eval_docker_next() {
    local docker_status="$1"
    case "$docker_status" in
      1) echo "  install Docker or start Colima/Docker Desktop, then rerun fieldwork eval up" ;;
      2) echo "  install Docker Compose support, then rerun fieldwork eval up" ;;
      *) echo "  start Colima or Docker Desktop, then rerun fieldwork eval up" ;;
    esac
  }

  case "$sub" in
    up)
      if [ $# -gt 0 ]; then
        case "$1" in
          --help|-h)
            cat <<'EOF'
usage: fieldwork eval up

Starts the Docker evaluation harness.
EOF
            return 0
            ;;
          --*) echo "unknown eval up argument: $1" >&2; return 2 ;;
          *) echo "fieldwork eval up accepts no positional arguments" >&2; return 2 ;;
        esac
      fi
      eval_intro
      echo
      local docker_status=0
      eval_docker_ready || docker_status=$?
      eval_docker_preflight "$docker_status"
      case "$docker_status" in
        0)
          ;;
        *)
          echo
          echo "Summary"
          eval_row needs "Eval environment not started."
          echo
          echo "Next"
          eval_docker_next "$docker_status"
          return 1
          ;;
      esac
      echo
      echo "Starting"
      eval_row info "Docker Compose" "building and starting eval container"
      local eval_log="${TMPDIR:-/tmp}/fieldwork-eval-up.$$.log"
      if "${compose[@]}" up -d --build >"$eval_log" 2>&1; then
        echo
        echo "Summary"
        eval_row ok "Eval environment is running."
        echo
        echo "Next"
        echo "  fieldwork eval smoke"
      else
        echo
        echo "Summary"
        eval_row needs "Eval environment did not start."
        if [ -s "$eval_log" ]; then
          echo
          echo "Details"
          tail -8 "$eval_log" | sed 's/^/  /'
          echo
          echo "Log"
          echo "  $eval_log"
        fi
        echo
        echo "Next"
        echo "  inspect the log above, then rerun fieldwork eval up"
        return 1
      fi
      ;;
    smoke)
      local verbose=0
      local json=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --verbose) verbose=1; shift ;;
          --json) json=1; shift ;;
          --help|-h)
            cat <<'EOF'
usage: fieldwork eval smoke [--verbose] [--json]

Runs the Docker evaluation smoke flow against fake GitHub behavior. Default
output is human-readable; --verbose shows the event timeline; --json prints
the structured smoke result.
EOF
            return 0
            ;;
          --*) echo "unknown eval smoke argument: $1" >&2; return 2 ;;
          *) echo "fieldwork eval smoke accepts no positional arguments" >&2; return 2 ;;
        esac
      done
      local docker_status=0
      eval_docker_ready || docker_status=$?
      if [ "$docker_status" != "0" ]; then
        echo "Fieldwork eval smoke"
        echo
        eval_docker_preflight "$docker_status"
        echo
        echo "Summary"
        eval_row needs "Smoke request not run."
        echo
        echo "Next"
        eval_docker_next "$docker_status"
        return 1
      fi
      if ! "${compose[@]}" ps >/dev/null 2>&1; then
        echo "Fieldwork eval smoke"
        echo
        echo "Summary"
        eval_row needs "Eval environment is not running."
        echo
        echo "Next"
        echo "  fieldwork eval up"
        return 1
      fi
      local smoke_output smoke_status=0
      smoke_output="$("${compose[@]}" exec -T fieldwork-eval /workspace/examples/eval/eval-smoke.sh 2>&1)" || smoke_status=$?
      if [ "$smoke_status" != "0" ]; then
        echo "Fieldwork eval smoke"
        echo
        echo "Evaluation mode only."
        echo "No real GitHub PAT is used. No real PR is created."
        echo
        echo "Result"
        eval_row needs "smoke test failed"
        if [ -n "$smoke_output" ]; then
          echo
          echo "Details"
          printf '%s\n' "$smoke_output" | tail -8 | sed 's/^/  /'
        fi
        echo
        echo "Fix"
        echo "  Run:"
        echo "    fieldwork eval logs"
        echo
        echo "  Then retry:"
        echo "    fieldwork eval smoke"
        return "$smoke_status"
      fi
      if [ "$json" = "1" ]; then
        printf '%s\n' "$smoke_output" | python3 -m json.tool
        return 0
      fi
      SMOKE_VERBOSE="$verbose" python3 - "$smoke_output" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

data = json.loads(sys.argv[1])
verbose = os.environ.get("SMOKE_VERBOSE") == "1"
events = data.get("events", [])
by_event = {event.get("event"): event for event in events}

def row(mark, label, detail=""):
    if detail:
        print(f"  {mark}  {label:<22} {detail}")
    else:
        print(f"  {mark}  {label}")

def short_request(value):
    return (value or "")[:8]

def event_time(event):
    value = event.get("ts", "")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").strftime("%H:%M:%S")
    except Exception:
        return "--:--:--"

def expires_detail(event):
    value = event.get("expires_at", "")
    try:
        dt = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        return "expires " + dt.strftime("%Y-%m-%d %H:%M UTC")
    except Exception:
        return ""

print("Fieldwork eval smoke")
print()
print("Evaluation mode only.")
print("No real GitHub PAT is used. No real PR is created.")
print()
print("Preparing")
row("✓", "throwaway repo ready")
row("✓", "switched branch", data.get("branch", ""))

if verbose:
    print()
    print("Timeline")
    timeline = [
        ("request_received", "request received", lambda e: e.get("transport", "")),
        ("request_queued", "request queued", expires_detail),
        ("request_approved", "request approved", lambda e: e.get("transport", "")),
        ("push_attempted", "push attempted", lambda e: e.get("transport", "")),
        ("pr_opened", "PR opened", lambda e: e.get("pr_url", "")),
    ]
    for key, label, detail_fn in timeline:
        event = by_event.get(key, {})
        detail = detail_fn(event)
        timestamp = event_time(event)
        print(f"  ✓  {timestamp}  {label:<18} {detail}".rstrip())
else:
    print()
    print("Broker flow")
    row("✓", "request received")
    row("✓", "request queued")
    row("✓", "approval accepted", data.get("decision", ""))
    row("✓", "push attempted", by_event.get("push_attempted", {}).get("transport", ""))
    row("✓", "PR opened")

print()
print("Result")
if data.get("ok"):
    row("✓", "smoke test passed")
else:
    row("!", "smoke test failed")
print()
print(f"  {'repo':<10} {data.get('repo', '')}")
print(f"  {'branch':<10} {data.get('branch', '')}")
request = data.get("request_id", "")
print(f"  {'request':<10} {request if verbose else short_request(request)}")
if verbose:
    print(f"  {'transport':<10} {by_event.get('push_attempted', {}).get('transport', '')}")
else:
    print(f"  {'PR':<10} {data.get('pr_url', '')}")
if verbose and data.get("pr_url"):
    print(f"  {'PR':<10} {data.get('pr_url', '')}")

if not verbose:
    print()
    print("For details:")
    print("  fieldwork eval smoke --verbose")
    print()
    print("For raw JSON:")
    print("  fieldwork eval smoke --json")
PY
      ;;
    logs)
      if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        cat <<'EOF'
usage: fieldwork eval logs [docker-compose-logs-options]

Streams raw Docker Compose logs for the evaluation harness. Use this after
fieldwork eval up or when fieldwork eval smoke asks for details.
EOF
        return 0
      fi
      local docker_status=0
      eval_docker_ready || docker_status=$?
      if [ "$docker_status" != "0" ]; then
        echo "Fieldwork eval logs"
        echo
        eval_docker_preflight "$docker_status"
        echo
        echo "Summary"
        eval_row needs "Logs not available."
        echo
        echo "Next"
        eval_docker_next "$docker_status"
        return 1
      fi
      "${compose[@]}" logs "$@"
      ;;
    down)
      if [ $# -gt 0 ]; then
        case "$1" in
          --help|-h)
            cat <<'EOF'
usage: fieldwork eval down

Stops the Docker evaluation containers without removing their volumes.
EOF
            return 0
            ;;
          --*) echo "unknown eval down argument: $1" >&2; return 2 ;;
          *) echo "fieldwork eval down accepts no positional arguments" >&2; return 2 ;;
        esac
      fi
      local docker_status=0
      eval_docker_ready || docker_status=$?
      if [ "$docker_status" != "0" ]; then
        echo "Fieldwork eval"
        echo
        eval_docker_preflight "$docker_status"
        echo
        echo "Summary"
        eval_row needs "Eval environment not stopped."
        echo
        echo "Next"
        eval_docker_next "$docker_status"
        return 1
      fi
      echo "Fieldwork eval"
      echo
      echo "Stopping"
      eval_row info "Docker Compose" "stopping eval environment"
      local eval_log="${TMPDIR:-/tmp}/fieldwork-eval-down.$$.log"
      if "${compose[@]}" down >"$eval_log" 2>&1; then
        echo
        echo "Summary"
        eval_row ok "Eval environment stopped."
      else
        echo
        echo "Summary"
        eval_row needs "Eval environment did not stop cleanly."
        if [ -s "$eval_log" ]; then
          echo
          echo "Details"
          tail -8 "$eval_log" | sed 's/^/  /'
          echo
          echo "Log"
          echo "  $eval_log"
        fi
        return 1
      fi
      ;;
    clean)
      if [ $# -gt 0 ]; then
        case "$1" in
          --help|-h)
            cat <<'EOF'
usage: fieldwork eval clean

Removes the Docker evaluation containers and volumes.
EOF
            return 0
            ;;
          --*) echo "unknown eval clean argument: $1" >&2; return 2 ;;
          *) echo "fieldwork eval clean accepts no positional arguments" >&2; return 2 ;;
        esac
      fi
      local docker_status=0
      eval_docker_ready || docker_status=$?
      if [ "$docker_status" != "0" ]; then
        echo "Fieldwork eval"
        echo
        eval_docker_preflight "$docker_status"
        echo
        echo "Summary"
        eval_row needs "Eval environment not cleaned."
        echo
        echo "Next"
        eval_docker_next "$docker_status"
        return 1
      fi
      echo "Fieldwork eval"
      echo
      echo "Cleaning"
      eval_row info "Docker Compose" "removing eval containers and volumes"
      local eval_log="${TMPDIR:-/tmp}/fieldwork-eval-clean.$$.log"
      if "${compose[@]}" down -v --remove-orphans >"$eval_log" 2>&1; then
        echo
        echo "Summary"
        eval_row ok "Eval environment cleaned."
      else
        echo
        echo "Summary"
        eval_row needs "Eval environment did not cleanly remove."
        if [ -s "$eval_log" ]; then
          echo
          echo "Details"
          tail -8 "$eval_log" | sed 's/^/  /'
          echo
          echo "Log"
          echo "  $eval_log"
        fi
        return 1
      fi
      ;;
    --help|-h|"")
      cat <<'EOF'
Fieldwork eval

Usage
  fieldwork eval <command> [options]

Docker-backed, no-VPS evaluation harness. It uses fake GitHub behavior and is
explicitly not a supported deployment topology.

Commands
  up                 start the Docker evaluation harness
  smoke              run the fake PR broker flow
  logs               stream raw evaluation logs
  down               stop evaluation containers
  clean              remove evaluation containers and volumes
EOF
      ;;
    *)
      echo "unknown eval command: $sub" >&2
      echo "usage: fieldwork eval up|smoke|logs|down|clean" >&2
      return 2
      ;;
  esac
}
fieldwork_adapter() {
  local sub="${1:-}"
  [ -n "$sub" ] && shift || true
  local agents_dir="$FIELDWORK_ROOT/lib/agents"
  case "$sub" in
    list)
      if [ $# -gt 0 ]; then
        case "$1" in
          --help|-h)
            echo "usage: fieldwork adapter list"
            return 0
            ;;
          --*) echo "unknown adapter list argument: $1" >&2; return 2 ;;
          *) echo "fieldwork adapter list accepts no positional arguments" >&2; return 2 ;;
        esac
      fi
      echo "Available Fieldwork agent adapters:"
      find "$agents_dir" -maxdepth 1 -type f -perm -111 -print | sort | while IFS= read -r adapter; do
        printf '  - %s\n' "$(basename "$adapter")"
      done
      ;;
    doctor)
      case "${1:-}" in
        --help|-h)
          echo "usage: fieldwork adapter doctor [adapter-name]"
          return 0
          ;;
        --*) echo "unknown adapter doctor argument: $1" >&2; return 2 ;;
      esac
      [ $# -le 1 ] || { echo "fieldwork adapter doctor accepts at most one adapter-name" >&2; return 2; }
      local adapter="${1:-${FIELDWORK_AGENT_ADAPTER:-claude-remote-control}}"
      local path="$agents_dir/$adapter"
      echo "Fieldwork adapter doctor"
      info_row "adapter" "$adapter"
      if [ -x "$path" ]; then
        status_ok_line "adapter executable exists"
      else
        setup_status_line needs "adapter executable missing: $path"
        return 1
      fi
      case "$adapter" in
        claude-remote-control)
          if command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]; then
            status_ok_line "Claude Code CLI found"
          else
            setup_status_line manual "Claude Code CLI not found on this host"
          fi
          info_row "launch" "$path <repo-slug> <repo-dir>"
          info_row "remote command" "claude remote-control --name vps-<slug> --remote-control-session-name-prefix vps-<slug> --sandbox --spawn=worktree --capacity=\$FIELDWORK_AGENT_CAPACITY"
          ;;
        *)
          info_row "launch" "$path <repo-slug> <repo-dir>"
          info_row "note" "custom adapters must exec one long-running foreground agent process"
          ;;
      esac
      ;;
    --help|-h|"")
      cat <<'EOF'
usage: fieldwork adapter list
       fieldwork adapter doctor [adapter-name]

Claude remote-control is the supported developer preview adapter. The adapter
contract is documented in docs/agent-adapters.md.
EOF
      ;;
    *)
      echo "unknown adapter command: $sub" >&2
      echo "usage: fieldwork adapter list|doctor" >&2
      return 2
      ;;
  esac
}
fieldwork_log() {
  local slug=""
  local json=0
  local since=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --since) since="${2:?--since requires a duration or UTC timestamp}"; shift 2 ;;
      --help|-h)
        cat <<'EOF'
usage: fieldwork log [repo-slug] [--json] [--since <duration-or-utc>]

Reads the broker audit log. By default this queries the configured VPS through
sudo because the audit log belongs to the token-owning broker user.
EOF
        return 0
        ;;
      --*) echo "unknown log argument: $1" >&2; return 2 ;;
      *) [ -z "$slug" ] || { echo "fieldwork log accepts at most one repo-slug" >&2; return 2; }; slug="$1"; shift ;;
    esac
  done
  [ -z "$slug" ] || valid_slug "$slug" || { echo "invalid repo slug: $slug" >&2; return 2; }

  local filter_py path audit_tmp
  path="${FIELDWORK_BROKER_AUDIT_LOG_PATH:-/var/lib/fieldwork-pr-broker/audit.jsonl}"
  IFS= read -r -d '' filter_py <<'PY' || true
import json, os, sys
from datetime import datetime, timezone, timedelta

path, slug, since, as_json = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"

def cutoff(value):
    if not value:
        return None
    units = {"m": 60, "h": 3600, "d": 86400}
    if value[-1:] in units and value[:-1].isdigit():
        return datetime.now(timezone.utc) - timedelta(seconds=int(value[:-1]) * units[value[-1]])
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        raise SystemExit(f"invalid --since value: {value}")

def parse_ts(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        return None

cut = cutoff(since)
lines = open(path).read().splitlines()
events = []
for line in lines:
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if slug and event.get("repo_path_slug") != slug:
        continue
    ts = parse_ts(event.get("ts"))
    if cut is not None and ts is not None and ts < cut:
        continue
    events.append(event)

if as_json:
    for event in events:
        print(json.dumps(event, sort_keys=True))
else:
    for event in events:
        bits = [event.get("ts", "?"), event.get("event", "?")]
        for key in ("repo", "branch", "base_branch", "decision", "pr_url", "error_category"):
            if event.get(key):
                bits.append(f"{key}={event[key]}")
        print("  ".join(bits))
PY

  audit_tmp="$(mktemp "${TMPDIR:-/tmp}/fieldwork-audit.XXXXXX")"
  if ! ssh -t "$FIELDWORK_SSH_HOST" "$(remote_sudo_command "cat $(shell_quote "$path")")" >"$audit_tmp" 2>/dev/null; then
    : >"$audit_tmp"
  fi
  python3 -c "$filter_py" "$audit_tmp" "$slug" "$since" "$json"
  rm -f "$audit_tmp"
}
