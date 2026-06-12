# Project guidance: <!-- fieldwork-init: repo name -->

<!-- fieldwork-init populates the marker fields below; `--verify` checks they're filled. -->

## Stack

<!-- fieldwork-init: stack -->

## Architecture (one-paragraph)

<!-- TODO: one-paragraph description of what this project is and how the pieces fit. -->

## Commands

<!-- fieldwork-init: commands -->
- Lint: <!-- e.g. npm run lint -->
- Typecheck: <!-- e.g. npx tsc --noEmit -->
- Test: <!-- e.g. npm test -->
- Build: <!-- e.g. npm run build -->
- Dev server: <!-- e.g. npm run dev -->

## Conventions

- Default to no comments; only add when the *why* is non-obvious.
- No backwards-compat shims unless explicitly requested.
- Validate inputs at trust boundaries (user input, network, file).
- Never log secrets.

## Security

- Cloud / claude.ai/code / GitHub Action runs use **test credentials only**. Never paste production-shape creds into cloud env. Production-shape work happens on the VPS.
- All MCP credentials via env vars. No inline secrets in `.mcp.json`.
- Read-only DB credentials by default.

## Workflow

- Plan mode for non-trivial work (auth, payments, schema, infra, or >3 files).
- `/deepplan` triggers 2 rounds of clarifying questions before plan write.
- Branching: do NOT run `git checkout -b` in Fieldwork remote sessions; the `/pr-delivery` prepare runner creates the `fieldwork/<short-feature>` branch and the commit, then leaves the worktree clean. Editing on the current checkout is fine.
- `/verify-before-pr` then `/pr-delivery` to ship. Both run locally before broker push.
- In Fieldwork remote sessions, plain Bash commands fail with a bwrap sandbox error by design. Explore with Read/Grep/Glob; the only working shell commands are the three `fieldwork-*` clients the skills invoke verbatim. A failing `ls` or `git status` is not a malfunction and not a reason to abandon the PR flow.

## Files Claude should know about

<!-- fieldwork-init: files -->
- <!-- e.g. lib/auth.ts: central auth flow, never bypass -->
- <!-- e.g. db/migrations/: reversibility checklist in REVIEW.md -->
