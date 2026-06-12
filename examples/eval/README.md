# Fieldwork Docker Evaluation

This directory is a **no-VPS evaluation harness**. It is evaluation only and
intentionally not a production deployment topology.

It demonstrates the broker request contract, approval queue, fake GitHub PR
creation, and broker audit log without a VPS, real GitHub PAT, Claude account,
Telegram bot, or onboarded repository.

Run:

```sh
fieldwork eval up
fieldwork eval smoke
fieldwork eval logs
fieldwork eval down
```

The harness uses fake `gh` and `gitleaks` commands inside the container.
Production Fieldwork still runs on a VPS with separate Unix identities and a
real broker-owned GitHub token.
