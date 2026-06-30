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

The smoke command creates a throwaway repo inside the container, queues a
broker request behind the approval gate, approves it through broker code, uses
fake GitHub behavior, and prints a human-readable broker-flow summary. Use
`fieldwork eval smoke --json` for the structured smoke result or
`fieldwork eval smoke --verbose` for the event timeline.

The Docker evaluation path remains GitHub-shaped. It does not exercise GitLab
host pinning, GitLab token liveness, or GitLab MR creation.

For production use, follow the VPS setup path. Production Fieldwork relies on
separate Unix users, systemd sockets, the broker-owned forge token, and real
repository checkouts.
