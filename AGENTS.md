# Fieldwork Repo Guidance

Fieldwork is a developer-preview tool for running mobile-driven coding-agent work on a VPS and routing repository writes through a broker-owned PR path.

## Engineering Defaults

- Make surgical changes that map directly to the task.
- Preserve the Claude discovery tree under `.claude/` unless a change explicitly targets Claude behavior.
- Fieldwork-owned repo state lives under `.fieldwork/`.
- Delivery clients stay on `~/.local/bin`: `fieldwork-verify`, `fieldwork-pr-prepare`, and `fieldwork-pr-submit`.
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

When preparing a PR from an onboarded VPS checkout:

1. Run `/home/fieldwork/.local/bin/fieldwork-verify "$PWD"`.
2. Write `.fieldwork/local/pr-prepare-request.json`.
3. Run `/home/fieldwork/.local/bin/fieldwork-pr-prepare .fieldwork/local/pr-prepare-request.json`.
4. Write `.fieldwork/local/pr-request.json`.
5. Run `/home/fieldwork/.local/bin/fieldwork-pr-submit .fieldwork/local/pr-request.json`.

Use `fieldwork/...` branches only. Never push directly to GitHub; the broker and approval gate are part of the security boundary.
