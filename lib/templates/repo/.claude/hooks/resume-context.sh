#!/usr/bin/env bash
# SessionStart hook: prints a briefing for the resumed repo.
# Output is captured and injected as additionalContext.

set -euo pipefail
REPO_SLUG="$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")"
JOURNAL="$HOME/.fieldwork/project-journals/${REPO_SLUG}.md"
ARTIFACT="$HOME/.fieldwork/state/resume-context/${REPO_SLUG}.md"

if [ -f "$ARTIFACT" ]; then
  cat "$ARTIFACT"
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || true

echo "## Resume context for $REPO_SLUG"
echo

echo "### Repo guidance"
[ -f CLAUDE.md ] && head -80 CLAUDE.md
echo

echo "### Review checklist"
[ -f REVIEW.md ] && head -40 REVIEW.md
echo

echo "### Last 5 commits"
git log -5 --oneline 2>/dev/null || echo "(no git history)"
echo

echo "### Open PRs"
if command -v gh >/dev/null 2>&1; then
  gh pr list --limit 5 --json number,title,headRefName,statusCheckRollup 2>/dev/null \
    | jq -r '.[] | "#\(.number) \(.title) [\(.headRefName)]"' 2>/dev/null \
    || echo "(gh not authenticated or repo lookup failed)"
else
  echo "(gh not installed)"
fi
echo

echo "### Last 10 journal entries"
if [ -f "$JOURNAL" ]; then
  tail -10 "$JOURNAL"
else
  echo "(no journal yet at $JOURNAL)"
fi
