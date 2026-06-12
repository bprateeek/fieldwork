# Review checklist

Used by `/security-review` and surfaced in the PR template body so reviewers (human + Claude) anchor on the same risk model.

## Auth model + critical paths

- Where do authenticated requests enter the system? List file paths.
- Where is the session/token validated? Is it validated *exactly once*, or are there multiple bypass paths?
- Which endpoints are intentionally unauthenticated? Why?
- Any new auth path in this PR : has it been reviewed against the existing model?

## Secrets handling

- Where do secrets enter? (env, vault, MCP, CI secret).
- What rotates them? On what cadence?
- Are any secrets committed in this PR? (gitleaks should catch, but humans look too.)
- Does this PR introduce a new credential type? Document the rotation policy.

## Multi-tenant scoping

- Every query that returns user data : does it scope to the requesting tenant?
- New tables or migrations : do they respect tenant scoping (column, RLS policy, FK)?
- Any cross-tenant write paths? If yes, audit-logged?

## Migration discipline

- Reversible? If irreversibly destructive, has the rollback been agreed upon?
- Backfill plan if adding NOT NULL columns to existing tables?
- RLS / policy impact reviewed?
- Locking behaviour under concurrent writes : measured or estimated?
- Order: this PR adds columns *before* code uses them (and code drops references *before* the migration removes them).

## Performance hotspots

- Query plan checked for new queries on tables >100k rows?
- Any new N+1 patterns introduced?
- Cache invalidation : what changed and what's invalidated?

## Cloud / production-cred policy

Cloud / claude.ai/code / GitHub Action runs use **test credentials only**. Never paste production-like creds into cloud env. Production-shape work happens on the VPS.

## Deployment / rollback

- Feature flag wrapping the change? Default off → ramp.
- Schema changes flagged in deploy notes.
- Rollback procedure documented in PR description (revert commit + drop column / clear cache / etc.).

## Tests

- Happy path covered.
- One adversarial input case (malformed input, oversized payload, concurrent write).
- Migration: forward + backward tested locally.
