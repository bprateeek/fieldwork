# Backup and restore

Back up broker authority and lifecycle state as one consistency set:

- credential and broker config;
- policy and content-addressed CA store;
- `keys/pending-mac.key`;
- permanent request ledger;
- pending metadata, sidecars, and packs;
- tombstones;
- audit log and bot state/config where applicable.

On VPS these live under `/etc/fieldwork-pr-broker`,
`/var/lib/fieldwork-pr-broker`, `/etc/fieldwork-bot`, and
`/var/lib/fieldwork-bot`. Stop agent sessions and broker sockets before a
filesystem-level backup so metadata, packs, and MACs are mutually consistent.

Local mode stores the same classes in named Compose volumes. Use Docker's
volume backup mechanism while `fieldwork-local down`; do not use
`fieldwork-local clean` until the backup is verified.

## Restore

1. Verify and install the exact compatible Fieldwork release.
2. Keep agent intake stopped.
3. Restore ownership and modes before starting services.
4. Restore the original MAC key with its pending records.
5. Start the broker and inspect reconciliation/status.
6. Resolve any `needs_operator` records.
7. Start approval transport and agent sessions.

The MAC key is not interchangeable. Losing or rotating it makes pending
metadata unverifiable. Drain pending work before an intentional key rotation.
The replay ledger should remain permanent; deleting it re-enables UUID replay.

## Credential incident

If a forge token may have escaped, revoke it at the forge first. A backup is not
a reason to restore a revoked credential. Install a new least-privilege token,
validate it with the rotation helper, and review audit/remote branches for
unexpected writes.
