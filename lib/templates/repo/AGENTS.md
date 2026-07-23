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

The escape-side clients below are root-owned. Invoke each excluded command as a
separate top-level tool call with its absolute path and one argument; shell
composition is denied by the root-owned managed Bash policy before sandbox
exclusions are evaluated.

1. Run verification:

```bash
/usr/local/bin/fieldwork-verify "$PWD"
```

If it fails, stop and report the failure. Do not retry with direct lint/test commands, auto-fix, stage, commit, push, or open a PR.

2. If the sandbox cannot commit, create a fresh per-UID spool directory and
write its only file, `request.json`, with this prepare request:

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

3. Run the prepare client with that request UUID:

```bash
/usr/local/bin/fieldwork-pr-prepare <prepare-request-id>
```

The prepare runner creates the branch, stages exactly `paths`, commits outside the agent sandbox, and leaves the worktree clean.

4. Write `.fieldwork/local/pr-build-request.json` (this file is not uploaded):

```json
{
  "schema_version": 2,
  "slug": "<slug>",
  "branch": "fieldwork/<same branch>",
  "title": "<PR title>",
  "body": "<PR body>"
}
```

5. Perform the upload phase as exactly two separate top-level calls. First build:

```bash
fieldwork-pr-build .fieldwork/local/pr-build-request.json
```

Then pass the printed UUID to the excluded uploader in a new tool call:

```bash
/usr/local/bin/fieldwork-pr-upload <request-id>
```

The broker never reads this checkout. It fetches the operator-wired base,
reconstructs the uploaded pack in quarantine, enforces object and scan caps,
scans title/body and the policy delta, and either opens the PR or durably queues
it for human approval.

If the broker or runners reject the request, do not bypass them with `git push`. Report the rejection and wait for operator guidance.

## Files The Agent Should Know About

<!-- fieldwork-init: files -->
- <!-- e.g. lib/auth.ts: central auth flow, never bypass -->
- <!-- e.g. db/migrations/: reversibility checklist in REVIEW.md -->
