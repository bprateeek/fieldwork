#!/usr/bin/env bash
# Stop hook compatibility shim.
#
# Durable journaling is now owned by the agent-agnostic fieldwork-event-poll
# timer, which records git-derived branch + latest commit subject for Claude,
# Codex, and future agents. The immediate Claude Stop notification remains
# wired through notify-wrapper.sh in .claude/settings.json.

set -euo pipefail

cat >/dev/null 2>&1 || true
