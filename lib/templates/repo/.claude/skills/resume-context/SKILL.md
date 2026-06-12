---
name: resume-context
description: Manually print the SessionStart resume-context briefing for this repo. Wraps .claude/hooks/resume-context.sh so it can be invoked mid-session without spawning a new SessionStart event.
---

# /resume-context

The `SessionStart` hook auto-prints this same briefing at session start. Use this skill when you want to re-print it later, e.g. after `/clear`, after a long detour, or when you want a fresh look at journal + open PRs without restarting.

## What it prints

- First 80 lines of `CLAUDE.md` (repo guidance).
- First 40 lines of `REVIEW.md` (review checklist).
- Last 5 commits.
- Last 5 open PRs (number, title, branch, status).
- Last 10 journal entries from `~/.fieldwork/project-journals/<repo-slug>.md`.

## How

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/resume-context.sh"
```

Output is plain text. If something looks wrong, check that the hook script exists and that `gh` is authenticated for the open-PRs query.

## Note

Journal lives **outside** the repo (`~/.fieldwork/project-journals/`) so it doesn't dirty cloud worktrees. Cloud sessions skip the journal portion (they set `CLAUDE_CODE_REMOTE`).
