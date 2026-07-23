# Operations runbook

## Daily checks

```sh
fieldwork doctor --remote --explain      # VPS
fieldwork verify-security                # VPS
sudo fieldwork-local status              # local
sudo fieldwork-local logs broker         # local
```

Use `/usr/local/bin/fieldwork-pr-upload --status <request-id>` for durable
request state. Do not infer completion from notification delivery.

## Stop intake

Local:

```sh
sudo fieldwork-local down
```

VPS:

```sh
sudo systemctl stop 'fieldwork-agent@*.service'
sudo systemctl stop fieldwork-pr-broker.socket fieldwork-pr-approve.socket
```

Preserve state. If credential exposure is possible, revoke the forge token
before diagnostics.

## Protocol-v2 upgrade transaction

The upgrade is discrete; do not run mixed v1/v2 intake.

1. Stop task intake and all agent sessions.
2. Drain or quarantine every v1 pending request. V1 records have no pack and
   cannot be approved by v2.
3. Verify both release chains and install v2. Confirm the persistent MAC key was
   generated.
4. Re-wire every slug. Re-wire is the default: the migration helper may prefill
   only project and base branch for confirmation. It must not import host, CA,
   private-network opt-in, or automatic approval.
5. Start maintenance.

VPS:

```sh
sudo /usr/local/sbin/fieldwork-pr-maintenance-mode start
```

Local:

```sh
sudo fieldwork-local maintenance-start
```

6. For each repository, run the structural migrator:

```sh
sudo /usr/local/sbin/fieldwork-migrate-instructions /path/to/checkout
```

It replaces only an exact byte match of a known legacy delivery section, creates
`fieldwork/protocol-v2-instructions`, and commits the change. Modified or
ambiguous instructions are reported and left untouched.

7. Build and submit that migration branch through the privileged maintenance
path using the same v2 metadata plus pack. Never push the default branch.
8. Merge migration PRs.
9. Stop maintenance and explicitly restart without the maintenance environment.
   On VPS run `sudo /usr/local/sbin/fieldwork-pr-maintenance-mode stop`; locally
   use `sudo fieldwork-local maintenance-stop`.
10. Re-enable normal broker sockets, dispatcher, timer, and agent sessions.

Normal `/pr` and `/approve` return 503 in maintenance. Status and
reconciliation continue. A repository remains `repo_not_wired` until its
broker-owned policy exists.

## Pending and policy incidents

- `metadata_tampered`: preserve record/pack and audit evidence; do not bypass
  the HMAC check.
- `policy_changed`: request is `needs_operator`; inspect whether a pinned
  branch was already pushed, then explicitly decide whether to resubmit.
- `unexpected_objects`: reject the upload; rebuild from a clean, non-alternate
  SHA-1 checkout.
- `pack_limits_exceeded`: establish a common base; raise caps only after
  reviewing repository size and resource limits.
- `private_network_rejected`: inspect all DNS answers. Enable private
  networking only for an intentionally self-managed forge.

## Recovery after crash

Restart the broker without deleting state. Reconciliation validates MAC, pack,
and policy; queries remote branch and PR state; and performs only missing steps.
Never manually change state JSON. A policy change after a push intentionally
stops at `needs_operator`.

## Token rotation

Drain or pause writes, then use `rotate-pat` on VPS or
`sudo fieldwork-local token` locally. Both validate forge reachability and fail
closed. Pending-record MAC-key rotation is separate and requires an empty
pending set.
