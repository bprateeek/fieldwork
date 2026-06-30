# shellcheck shell=bash
# fieldwork task - submit and inspect one_shot_job tasks (e.g. aider).
#
# Tasks run on the VPS via fieldwork-task-dispatcher. This client only enqueues
# and inspects; it never runs an agent locally. `add` streams the prompt over
# SSH to fieldwork-task-enqueue on stdin (framed header + raw prompt bytes) so
# the prompt never lands on the local disk and never appears in an SSH argv.

_task_slug_ok() {
  case "$1" in
    [a-z0-9]) return 0 ;;
    [a-z0-9]*[!a-z0-9-]*) return 1 ;;
    [a-z0-9]*) [ "${#1}" -le 31 ] ;;
    *) return 1 ;;
  esac
}

_task_profile_ok() {
  # Empty is allowed (no profile). Otherwise [a-z0-9][a-z0-9_-]{0,40}.
  [ -z "$1" ] && return 0
  case "$1" in
    [a-z0-9]) return 0 ;;
    [a-z0-9]*[!a-z0-9_-]*) return 1 ;;
    [a-z0-9]*) [ "${#1}" -le 41 ] ;;
    *) return 1 ;;
  esac
}

task_usage() {
  cat <<'EOF'
usage:
  fieldwork task add <slug> [<prompt>] [--profile <name>]
                              (prompt from arg, or piped on stdin)
  fieldwork task list
  fieldwork task discard <task-id>

Submit a one_shot_job task (e.g. aider) to run on the VPS. The dispatcher edits
the repo, runs verify, and opens a PR through the broker. Inspect with `list`;
`discard` removes a queued or terminal (done/failed) task. A task that is
running or awaiting approval cannot be discarded; deny it via Telegram first.
EOF
}

task_add() {
  local slug="" profile="" prompt="" have_prompt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) [ -n "${2:-}" ] || { echo "--profile requires a name" >&2; return 2; }; profile="$2"; shift 2 ;;
      --profile=*) profile="${1#--profile=}"; shift ;;
      --help|-h) task_usage; return 0 ;;
      --*) echo "unknown task add argument: $1" >&2; return 2 ;;
      *)
        if [ -z "$slug" ]; then slug="$1"
        elif [ "$have_prompt" -eq 0 ]; then prompt="$1"; have_prompt=1
        else echo "task add takes at most one prompt argument" >&2; return 2
        fi
        shift ;;
    esac
  done

  [ -n "$slug" ] || { echo "task add requires a <slug>" >&2; task_usage >&2; return 2; }
  _task_slug_ok "$slug" || { echo "invalid slug '$slug' (^[a-z0-9][a-z0-9-]{0,30}\$)" >&2; return 2; }
  _task_profile_ok "$profile" || { echo "invalid profile '$profile'" >&2; return 2; }

  if [ "$have_prompt" -eq 0 ]; then
    if [ -t 0 ]; then
      echo "no prompt given; pass it as an argument or pipe it on stdin" >&2
      return 2
    fi
    prompt="$(cat)"
  fi
  [ -n "$prompt" ] || { echo "prompt is empty" >&2; return 2; }

  local nbytes
  nbytes="$(printf '%s' "$prompt" | LC_ALL=C wc -c | tr -d ' ')"

  local actor header
  actor="$(id -un 2>/dev/null || whoami 2>/dev/null || printf 'unknown')"
  header="$(FIELDWORK_TASK_SLUG="$slug" FIELDWORK_TASK_PROFILE="$profile" FIELDWORK_TASK_BYTES="$nbytes" FIELDWORK_TASK_ACTOR="$actor" python3 - <<'PY'
import json
import os

print(json.dumps({
    "slug": os.environ["FIELDWORK_TASK_SLUG"],
    "profile": os.environ.get("FIELDWORK_TASK_PROFILE", ""),
    "prompt_bytes": int(os.environ["FIELDWORK_TASK_BYTES"]),
    "source": "cli",
    "actor": os.environ.get("FIELDWORK_TASK_ACTOR") or "unknown",
}, separators=(",", ":")))
PY
)"

  local task_id
  if ! task_id="$( { printf '%s\n' "$header"; printf '%s' "$prompt"; } \
      | ssh "$FIELDWORK_SSH_HOST" '"$HOME"/.local/bin/fieldwork-task-enqueue' )"; then
    echo "failed to enqueue task on $FIELDWORK_SSH_HOST" >&2
    return 1
  fi
  echo "queued task: $task_id"
  echo "  fieldwork task list      # watch progress"
}

task_list() {
  [ $# -eq 0 ] || { echo "fieldwork task list takes no arguments" >&2; return 2; }
  ssh "$FIELDWORK_SSH_HOST" 'bash -s' <<'REMOTE'
set -eu
spool="${FIELDWORK_TASKS_DIR:-/var/lib/fieldwork-tasks}"
for state in queue processing done failed; do
  dir="$spool/$state"
  [ -d "$dir" ] || continue
  for task in "$dir"/*/; do
    [ -d "$task" ] || continue
    name="$(basename "$task")"
    case "$name" in .tmp.*) continue ;; esac
    phase=""
    [ -f "$task/state.json" ] && phase="$(sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$task/state.json" | head -1)"
    printf '%-10s %-34s %s\n' "$state" "$name" "$phase"
  done
done
REMOTE
}

task_discard() {
  local id="${1:-}"
  [ -n "$id" ] || { echo "fieldwork task discard requires a <task-id>" >&2; return 2; }
  case "$id" in *[!a-z0-9-]*) echo "invalid task id" >&2; return 2 ;; esac
  local id_q
  id_q="$(shell_quote "$id")"
  ssh "$FIELDWORK_SSH_HOST" "id=$id_q bash -s" <<'REMOTE'
set -eu
spool="${FIELDWORK_TASKS_DIR:-/var/lib/fieldwork-tasks}"
# Queued (not yet claimed) and terminal (done/failed) tasks are safe to discard.
# A task in processing/ is running or awaiting approval; refuse it so a pending
# broker request cannot later approve and push. Deny it via Telegram first.
if [ -d "$spool/processing/$id" ]; then
  echo "task $id is running or awaiting approval; cannot discard" >&2
  echo "  if it is awaiting approval, deny it via Telegram first" >&2
  exit 1
fi
for state in queue done failed; do
  if [ -d "$spool/$state/$id" ]; then
    rm -rf -- "$spool/$state/$id"
    echo "discarded $id (was $state)"
    exit 0
  fi
done
echo "no such task: $id" >&2
exit 1
REMOTE
}

task_fieldwork() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift || true
  case "$sub" in
    add) task_add "$@" ;;
    list) task_list "$@" ;;
    discard) task_discard "$@" ;;
    ""|--help|-h) task_usage ;;
    *) echo "unknown subcommand: fieldwork task $sub" >&2; task_usage >&2; return 2 ;;
  esac
}
