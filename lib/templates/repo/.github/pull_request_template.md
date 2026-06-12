## Summary

<!-- 1–3 bullets: what changes and why. -->

## Linked task

<!-- Closes #N (issue created from .github/ISSUE_TEMPLATE/claude-task.md) -->

## Review checklist

Anchored on REVIEW.md. Tick what applies; skip what doesn't.

### Auth + critical paths
- [ ] No new unauthenticated entry points (or new ones documented and intentional).
- [ ] Auth/session validation happens exactly once per request path.

### Secrets
- [ ] No secrets in diff (gitleaks clean).
- [ ] New credential types have a rotation policy documented.

### Multi-tenant scoping
- [ ] All new data-access paths scope to the requesting tenant.
- [ ] Migrations preserve tenant scoping.

### Migrations
- [ ] Reversible (or rollback plan agreed).
- [ ] Backfill strategy for NOT NULL adds.
- [ ] Forward + backward tested locally.

### Performance
- [ ] No new N+1.
- [ ] Query plan checked for queries hitting >100k-row tables.

### Tests
- [ ] Happy path covered.
- [ ] One adversarial input case.

## Rollback

<!-- Specific revert procedure: revert commit / drop column / clear cache / disable feature flag. -->

## Test plan

- [ ] Local tests pass.
- [ ] CI green when configured (semgrep, codeql, audit, claude-review).
- [ ] Manual smoke (describe what you clicked / curled).

🤖 Opened via `/pr-delivery` through `fieldwork-pr-broker`.
