# Fieldwork Repo Guidance

Fieldwork is a developer-preview tool for running mobile-driven coding-agent work on a VPS and routing repository writes through a broker-owned PR path.

## Engineering Defaults

- Make surgical changes that map directly to the task.
- Preserve the Claude discovery tree under `.claude/` unless a change explicitly targets Claude behavior.
- Fieldwork-owned repo state lives under `.fieldwork/`.
- Escape-side delivery clients are root-owned at `/usr/local/bin`: `fieldwork-verify`, `fieldwork-pr-prepare`, and `fieldwork-pr-upload`. `fieldwork-pr-build` remains sandboxed.
- Never log secrets or put token-shaped values in examples.

## Verification

Run the narrowest useful checks first, then the broader suite when touching shared paths:

```bash
tests/static-checks.sh
python3 tests/broker-validation-tests.py
python3 tests/pr-prepare-validation-tests.py
python3 tests/bot-tests.py
```

## Fieldwork Delivery Workflow

When preparing a PR from an onboarded checkout, verify first and ensure every
intended change is committed (use the root-owned prepare runner when the agent
sandbox cannot commit). Then perform the upload phase as two separate top-level
tool calls:

1. Run `fieldwork-pr-build .fieldwork/local/pr-build-request.json` and record the UUID it prints.
2. Run `/usr/local/bin/fieldwork-pr-upload <request-id>` as a separate call.

The build input contains `slug`, a `fieldwork/...` branch, `title`, and `body`;
the builder resolves `head_oid`, creates a non-thin pack, and refuses a dirty
worktree. Never combine build and upload in one shell command, and never push
directly—the checkout-blind broker reconstructs, scans, and policy-gates the pack.
