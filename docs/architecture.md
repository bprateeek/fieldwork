# Architecture

Fieldwork separates untrusted code production from credential-bearing delivery.
Local and VPS modes use the same checkout-blind broker protocol.

```text
dedicated agent session
  |  commit + exact root-owned fieldwork-pr-build client
  v
untrusted per-UID spool: meta.json + non-thin pack
  |  /usr/local/bin/fieldwork-pr-upload (excluded, no subprocess)
  v
broker ingress
  |-- authenticate transport
  |-- load broker-owned slug policy under lock
  |-- resolve/classify/pin forge endpoints
  |-- quarantine + caps + ancestry + secret scans
  |-- durable record + pack + HMAC
  v
approval state machine
  |-- require: wait, with zero forge writes
  |-- auto: approved is durable before write
  v
host-pinned Git push + GitHub/GitLab REST
```

## Local mode

The broker and optional Telegram bot run as separate non-root Docker services
with read-only roots, dropped capabilities, no-new-privileges, memory/CPU/PID
limits, and narrowly split named volumes. The bot cannot mount the token,
policy, pack, MAC key, local bearer, or Docker socket.

The human control surface is the root-owned
`/usr/local/sbin/fieldwork-local`. It uses fixed Docker and Compose paths and
a scrubbed environment. There is intentionally no user-level `fieldwork local`
wrapper.

Claude runs as the dedicated `fieldwork-agent` account through a root-owned
launcher. A policy helper returns strict managed policy only to that UID, so an
ordinary human Claude session is unaffected. The launcher pins the Claude
executable digest and the complete pre-/out-of-sandbox asset inventory.

## VPS mode

The broker is a separate system user and owns the forge credential. Agent,
event poller, task dispatcher, verify runner, prepare runner, clients, and
adapters are installed as root-owned assets. Boundary services are system
units, not user units:

- `fieldwork-agent@.service`
- `fieldwork-event-poll.service/.timer`
- `fieldwork-task-dispatcher.service`
- `fieldwork-verify-runner.socket/@.service`
- `fieldwork-pr-prepare-runner.socket/@.service`

Sockets are fixed beneath `/run/fieldwork`. The dashboard is disabled in
hard-boundary mode. Rootless Docker may remain a user service; it is not a
Fieldwork execution boundary.

## Storage ownership

Broker state is split by trust:

- policy and CA: broker/root controlled;
- pending metadata: broker writable, bot read-only;
- notification sidecars and typed queue: broker/bot shared where needed;
- pending packs: broker only;
- pending HMAC key: broker only and persistent;
- tombstones and replay ledger: broker only.

The agent spool is intentionally untrusted. Its private ownership and no-follow
walk protect the uploader from path redirection, not the broker from malicious
content; the broker revalidates everything.

## Forge access

The broker scrubs Git environment and configuration, pins the allowed HTTPS
host in askpass, supplies credentials only for the matching prompt host, and
pins DNS answers to the policy port. PR/MR lookup and creation use zero-redirect
REST with the same endpoint constraints.

## Lifecycle recovery

Transitions are fsynced before rename. On startup and status/approval paths,
reconciliation verifies MAC, pack, and policy, inspects remote branch/PR state,
and continues only missing steps. A policy change after push yields
`needs_operator` and reports the possible orphan branch; it is never silently
completed under changed authority.

See [broker protocol](broker-contract.md), [runner architecture](runner-architecture.md),
and [threat model](threat-model.md).
