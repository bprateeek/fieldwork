# Approval gate

Approval is a broker-owned policy property. New wiring defaults to
`approval=require`; automatic delivery must be selected explicitly.

## Required approval

On upload the broker authenticates the transport, validates metadata, loads and
locks policy, scans title/body, reconstructs the pack in quarantine, enforces
caps and ancestry, and persists:

- the canonical metadata record;
- policy digest and pack digest;
- HMAC over that record;
- broker-only pack;
- `queued` state.

It does not push a branch, create a PR/MR, or perform any other forge write.
Denial and expiry delete the pending pack and create terminal tombstones without
a forge write.

Approve or deny locally:

```sh
sudo fieldwork-local approve <request-id>
sudo fieldwork-local approve <request-id> deny
```

VPS Telegram approval sends an HMAC-authenticated, replay-resistant request over
the group-restricted approve socket.

## Approval revalidation

Approval does not trust enqueue-time validation alone. Under the per-slug lock
the broker:

1. verifies record HMAC and stored-pack digest;
2. compares the complete current policy digest;
3. rescans title and body;
4. refetches the named base;
5. rebuilds quarantine from the stored pack;
6. repeats object-set, cap, ancestry, and secret checks;
7. checks for an already-pushed pinned branch and existing PR;
8. performs only missing forge operations.

A changed policy yields `needs_operator`. If the branch was already pushed
before a crash, the result reports the possible orphan and does not create a PR
under changed policy.

## Automatic approval

`approval=auto` uses the same state machine. The broker persists metadata,
pack, HMAC, and `approved` state before its first forge write. A crash is
reconciled idempotently; it cannot double-push or create duplicate PRs.

## Status

```sh
/usr/local/bin/fieldwork-pr-upload --status <request-id>
```

States are `queued`, `approved`, `pushed`, `pr_created`, `done`,
`denied`, `expired`, `failed`, or `needs_operator`. Terminal status
includes a PR URL or fixed error code. Tombstones default to 30-day retention;
request UUIDs remain permanently reserved.

## Bot isolation

The approval bot can read pending metadata, write notification sidecars, consume
typed notifications, and reach only the approve socket. It cannot access the
forge token, policy, pack, MAC key, local bearer, submit transport, or Docker
socket. Mutating visible metadata cannot authorize a write because broker
approval verifies the HMAC and pack digest.
