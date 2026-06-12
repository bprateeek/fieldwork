# Project guidance: <!-- fieldwork-init: repo name -->

<!-- fieldwork-init populates the marker fields below; `fieldwork-init --verify` checks they're filled. -->

## Stack

<!-- fieldwork-init: stack -->

## Architecture

<!-- TODO: one-paragraph description of what this project is and how the pieces fit. -->

## Commands

<!-- fieldwork-init: commands -->
- Lint: <!-- e.g. npm run lint -->
- Typecheck: <!-- e.g. npx tsc --noEmit -->
- Test: <!-- e.g. npm test -->
- Build: <!-- e.g. npm run build -->
- Dev server: <!-- e.g. npm run dev -->

## Conventions

- Default to no comments; only add when the why is non-obvious.
- No backwards-compat shims unless explicitly requested.
- Validate inputs at trust boundaries.
- Never log secrets.

## Security

- Cloud, app, and GitHub Action runs use test credentials only.
- All MCP credentials go through environment variables. No inline secrets in `.mcp.json`.
- Never push directly to GitHub from this checkout. Use the Fieldwork broker flow below.

## Fieldwork Delivery Workflow

Codex must use the broker path for every PR. The branch must be `fieldwork/<short-feature-name>`, never the default branch.

Invoke the three fieldwork commands below verbatim: absolute path, single argument, no `cd`/`env`/`&&` prefix. Their sandbox exclusion is a literal prefix match on the command string, and any prefix re-enables the per-command sandbox, which fails inside remote sessions.

1. Run verification:

```bash
/home/fieldwork/.local/bin/fieldwork-verify "$PWD"
```

If it fails, stop and report the failure. Do not retry with direct lint/test commands, auto-fix, stage, commit, push, or open a PR.

2. Write `.fieldwork/local/pr-prepare-request.json`:

```json
{
  "request_id": "<fresh uuid v4>",
  "created_at": "<UTC timestamp>",
  "repo_path": "/home/fieldwork/projects/<slug>",
  "branch": "fieldwork/<short-feature-name>",
  "paths": ["<repo-relative dirty path>"],
  "message": "<commit message body>"
}
```

`paths` must list every modified or untracked file and only those files. No absolute paths or `..` segments.

3. Run the prepare client:

```bash
/home/fieldwork/.local/bin/fieldwork-pr-prepare .fieldwork/local/pr-prepare-request.json
```

The prepare runner creates the branch, stages exactly `paths`, commits outside the agent sandbox, and leaves the worktree clean.

4. Write `.fieldwork/local/pr-request.json`:

```json
{
  "request_id": "<fresh uuid v4 distinct from prepare>",
  "created_at": "<UTC timestamp>",
  "repo_path": "/home/fieldwork/projects/<slug>",
  "branch": "fieldwork/<same branch>",
  "title": "<PR title>",
  "body": "<PR body>"
}
```

5. Submit through the broker:

```bash
/home/fieldwork/.local/bin/fieldwork-pr-submit .fieldwork/local/pr-request.json
```

The broker validates `.fieldwork/expected-origin`, enforces `fieldwork/...` branches, scans the PR body for secrets, and opens the PR. If `.fieldwork/approval-gate` exists, the broker queues the push until the Telegram approval bot receives an approval.

If the broker or runners reject the request, do not bypass them with `git push`. Report the rejection and wait for operator guidance.

## Files The Agent Should Know About

<!-- fieldwork-init: files -->
- <!-- e.g. lib/auth.ts: central auth flow, never bypass -->
- <!-- e.g. db/migrations/: reversibility checklist in REVIEW.md -->
