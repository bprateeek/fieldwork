# No-VPS Evaluation

The Docker evaluation path is for a quick local look at Fieldwork's broker
shape. It is **evaluation only**, not a supported deployment topology.

It does not require:

- VPS provisioning
- a real GitHub PAT
- Claude login
- Telegram bot setup
- an onboarded repository

Run:

```sh
fieldwork eval up
fieldwork eval smoke
fieldwork eval logs
fieldwork eval down
fieldwork eval clean
```

The smoke command runs a hermetic subset of the real protocol-v2 broker tests.
It creates real Git repositories and packfiles, exercises quarantine and the
durable approval lifecycle, and performs no forge or network operation. Use
`fieldwork eval smoke --json` for the structured result.

Because the evaluation is forge-free, it does not exercise GitHub or GitLab
token liveness, host pinning, or PR/MR creation.

For production use, follow the VPS setup path. Production Fieldwork relies on
separate Unix users, systemd sockets, the broker-owned forge token, and real
repository checkouts. The gated local-mode implementation instead uses the
hardened broker container plus a dedicated host account; it is not supported
until the documented release acceptance gate passes. See [Local Mode](local-mode.md).
