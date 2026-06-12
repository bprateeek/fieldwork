# Global guidance for Claude Code (LOCAL sessions)

Local sessions only. Cloud, claude.ai/code, and GitHub Action runs do **not** see this file; the repo-level `CLAUDE.md` covers those.

## Output style
No em-dashes or en-dashes in anything you produce (comments, commits, PR bodies, docs, chat). Use a comma, colon, or full stop. Hyphens in compound words (read-only, fine-grained) stay.

## Planning (plan mode)
Non-trivial work (auth, payments, migrations, infra, or >3 files): ask **2+ rounds** via AskUserQuestion before the plan. Round 1: scope, constraints, success criteria, non-goals. Round 2: edge cases, failure modes, security/auth, rollback. Third round only for genuine ambiguity. Trivial work (typos, one-line fixes, renames): skip rounds, short plan. Design tradeoffs: delegate a pass to the `planner` subagent first.

## Security
- Never trade security for convenience.
- Treat all network/file/argv input as hostile; validate it.
- Never log secrets or paste them into responses.
- Least-privilege by default: read-only tokens, write access opt-in per call.
- Unsure if a control is needed: add it, flag for review.
- Credentials via env vars only, never inline. Document var names in `.mcp.local.example.json`.
- Cloud/Action runs: **test credentials only**. Production-shape work is on the VPS.

## Code
- No comments by default. Add one only when the *why* is non-obvious: hidden constraint, subtle invariant, bug workaround.
- Identifiers carry meaning; don't narrate what code does.
- No backwards-compat shims unless asked. Delete dead code, no `_unused` aliases.
- No half-finished scaffolds. Ship it or leave it out.

## MCP servers
- Read-only DB creds by default. Write-capable creds live in `.mcp.local.json` (gitignored), local use only.
- No prod write tokens via MCP; prod writes go through a manual flow.
- Allowlist server commands in `permissions`; fail closed even for read-only servers.

## Broker PAT
Fine-grained PAT scopes for `/etc/fieldwork-pr-broker/gh-token`: see `docs/broker-pat.md`.