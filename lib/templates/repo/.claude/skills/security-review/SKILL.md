---
name: security-review
description: Repo-aware security review of the pending changes. Consults REVIEW.md to anchor the review on this project's specific risk model (auth, secrets, multi-tenant, migrations, performance). Used by claude-review.yml at PR time.
---

# /security-review (repo override)

This is the repo-level override of the built-in `/security-review`. Built-in does generic OWASP-style scanning. This version layers in **REVIEW.md**, the per-repo risk model.

## Inputs

- `git diff main...HEAD` — the PR's changeset.
- `REVIEW.md`: repo-specific review checklist (auth model, secrets handling, tenancy, migration discipline, performance hotspots).
- `CLAUDE.md`: repo conventions.

## Sequence

### 1. Read REVIEW.md fully

Identify which sections apply to the diff. Skip sections the diff doesn't touch.

### 2. Walk the diff

For each changed file:
- Does any line cross a trust boundary (user input → query, render, file path, network call)?
- Does any line touch auth, session, token, password, secret, env?
- Does any migration add/drop/alter columns affecting RLS or tenant scoping?
- Does any new dependency introduce known-vuln transitive packages? (Cross-check `audit.yml` output if available.)

### 3. Apply REVIEW.md sections

Score each applicable section: pass / risk / blocker. Cite line numbers. Be specific.

### 4. Generic OWASP pass

Only after the repo-specific pass. Catch things REVIEW.md doesn't enumerate but that any production code should worry about: XSS sinks, SSRF, prototype pollution, IDOR, weak crypto.

### 5. Output

Format as PR review comments. Each finding:
- **Severity**: blocker / risk / nit.
- **Location**: `path:line`.
- **Why it matters**: one sentence.
- **Suggested fix**: one sentence; or a code suggestion if obvious.

End with a one-line summary: `<N> blockers, <M> risks, <K> nits`. No blockers + clean OWASP pass = recommend approval (but never auto-approve. That's GitHub mobile native UI's job).

## Limits

- Hint, not gate. Branch protection requires deterministic checks (semgrep, codeql, audit).
- Budget capped at `--max-budget-usd 2` per CI invocation (set in `claude-review.yml`).
- Cloud / Action runs have **no production credentials**. Don't recommend manual reproduction steps that require prod-only secrets.
