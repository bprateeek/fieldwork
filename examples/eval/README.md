# Fieldwork Docker Evaluation

This directory is a **no-VPS evaluation harness**. It is evaluation only and
intentionally not a production deployment topology.

It demonstrates the protocol-v2 metadata/pack contract, real Git quarantine,
zero-write approval gate, durable auto mode, tombstones, and idempotent resume
without a VPS, forge credential, Claude account, or Telegram bot.

Run:

```sh
fieldwork eval up
fieldwork eval smoke
fieldwork eval logs
fieldwork eval down
```

The harness uses the fake `gitleaks` scanner inside the container. Production
Fieldwork uses either the local Docker boundary or separate VPS identities and
a broker-owned forge credential.
