#!/usr/bin/env bash
# Stop hook: appends a one-line journal entry to ~/.fieldwork/project-journals/<slug>.md.
# Skips in cloud / CI / GitHub Action runs (journal is local-only).

set -euo pipefail

# Local-only: skip in cloud / Action / CI. FIELDWORK_SKIP_LOCAL_HOOKS is the
# agent-neutral signal an agent adapter can set; CLAUDE_CODE_REMOTE is the
# Claude Code adapter's own equivalent and is kept as a fallback.
[ -n "${CI:-}${GITHUB_ACTIONS:-}${FIELDWORK_SKIP_LOCAL_HOOKS:-}${CLAUDE_CODE_REMOTE:-}" ] && exit 0

mkdir -p "$HOME/.fieldwork/project-journals"
JOURNAL="$HOME/.fieldwork/project-journals/$(basename "${CLAUDE_PROJECT_DIR:-$PWD}").md"
payload="$(cat)"

# 1) Direct field if Stop input carries it (current docs).
last="$(jq -r '.last_assistant_message // empty' <<<"$payload" \
        | head -c 200 | tr '\n' ' ' || true)"

# 2) Fallback: tail the transcript JSONL (older shape, more robust).
if [ -z "$last" ]; then
  transcript="$(jq -r '.transcript_path // empty' <<<"$payload")"
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    last="$(grep -F '"role":"assistant"' "$transcript" | tail -1 \
            | jq -r '..|.text? // empty' 2>/dev/null \
            | head -c 200 | tr '\n' ' ' || true)"
  fi
fi

branch="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
echo "- $(date -Iseconds) | $branch | $last" >> "$JOURNAL"
