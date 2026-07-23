# Broker protocol v2

Protocol v2 is checkout-blind. The broker receives metadata and a Git pack; it
does not accept a repository path and has no projects-root option.

## Metadata

```json
{
  "schema_version": 2,
  "request_id": "f02865ee-bbed-45cb-8b32-b1b987916105",
  "created_at": "2026-07-18T12:00:00Z",
  "slug": "example",
  "branch": "fieldwork/fix-widget",
  "title": "Fix widget",
  "body": "Summary and tests",
  "head_oid": "0123456789012345678901234567890123456789",
  "common_base_oid": "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
}
```

`common_base_oid` may be null for a full pack. Object IDs are SHA-1 only.
Unknown fields are rejected. The slug, branch, UUID, timestamp, title, UTF-8
body size, and OID shapes are validated before policy or forge access.

## Upload

`fieldwork-pr-build` requires a clean worktree, a `fieldwork/...` branch,
SHA-1 object format, and no object alternates/reference clone. It uses a fixed
Git environment and:

```sh
git pack-objects --revs --local --stdout
```

It intentionally does not use `--thin`. It publishes exactly `meta.json` and
`pack` into a private per-UID spool.

`/usr/local/bin/fieldwork-pr-upload <request-id>` walks that spool without
following symlinks, checks ownership/modes/type/size, and composes an exact
`multipart/form-data` POST with parts named `meta` and `pack`. The uploader
uses only Python standard-library sockets and never starts a subprocess.

VPS transport is a group-restricted Unix socket. Local transport is
`127.0.0.1:8377` with a bearer used for loopback/CSRF defense in depth.
Authentication is checked before a TCP body is read. Header, body, idle, and
total processing deadlines apply.

## Broker-owned policy

The slug selects a root/broker-owned policy record:

```json
{
  "schema_version": 1,
  "forge": "github",
  "project": "owner/example",
  "api_base_url": "https://api.github.com",
  "git_base_url": "https://github.com",
  "base_branch": "main",
  "approval": "require",
  "allow_private_network": false,
  "ca_bundle_ref": null
}
```

GitHub endpoints are constants. GitLab API and Git endpoints must be HTTPS and
share the same operator-confirmed host and port. Custom CA files are copied
into a content-addressed broker store. DNS resolution rejects a destination if
any answer is a forbidden address class unless private networking was
explicitly enabled; the accepted addresses are pinned for Git and REST.
Redirects are disabled.

Policy reads and writes use no-follow checks and per-slug locks. A digest of the
full policy is recorded with pending work. Any change before a forge write
moves the request to `needs_operator`.

## Quarantine

The broker fetches only the named base branch, indexes the uploaded pack into a
fresh quarantine object store with strict Git validation, and rejects thin
packs. It enforces:

- physical pack and object-count limits;
- per-object, total expanded, and delta-chain limits;
- no uploaded objects beyond the expected policy delta;
- `common_base_oid` is an ancestor of `head_oid`;
- the pinned head is a commit and the base relationship is current;
- secret scans over title, body, filenames, blobs, author/committer identity,
  and signature material.

Blob materialization uses OIDs and safe files in the quarantine directory; tree
filenames are never interpreted as output paths.

## Approval and durability

Every request reserves its UUID permanently. Pending records and packs enter the
same fsynced state machine in both approval modes:

```text
queued -> approved -> pushed -> pr_created -> done
   |          |                       |
   +-> denied +-> failed/needs_operator
   +-> expired
```

`approval=require` performs no forge write before approval. Denial and expiry
perform no forge write at all. Auto mode persists the pack, metadata, MAC, and
`approved` state before its first write.

Metadata is broker-owned and authenticated with a persistent broker-only HMAC
key over the canonical record and pack digest. Approval revalidates the MAC,
pack digest, policy, scans, quarantine, and base under the slug lock.

Reconciliation checks the remote branch OID and existing PR before doing only
the missing operation. It does not double-push or create a duplicate PR.
Terminal results are durable tombstones. Tombstones default to 30-day
retention; the replay ledger is permanent.

## Status and responses

```sh
/usr/local/bin/fieldwork-pr-upload --status <request-id>
```

This sends authenticated `POST /pr-status {"request_id":"..."}`. It returns the
current state and, for terminal states, the PR URL or fixed error code. After
tombstone retention, status returns `unknown_request`; replaying a UUID still
in the permanent ledger returns `duplicate_expired`.

Responses are JSON objects. Consumers must rely on `ok`, `state`,
`request_id`, `url`, and `error_code`, not human log text.

## Maintenance transport

Maintenance uses the same metadata-plus-pack contract. On VPS it is a
root:root 0600 Unix socket that is not enabled by default. Locally, root invokes
the broker container entrypoint. While maintenance is active, normal `/pr` and
`/approve` return 503, while status and reconciliation continue.
