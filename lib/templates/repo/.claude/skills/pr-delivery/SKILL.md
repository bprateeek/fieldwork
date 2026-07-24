---
name: pr-delivery
description: Verify, commit, and deliver a Fieldwork change through the checkout-blind protocol-v2 broker.
---

# /pr-delivery

Open or update a PR without exposing forge credentials to the agent checkout.
Never run `git push` or use a removed `fieldwork-pr-submit` client.

Before changing Git state, print the complete list of dirty paths and one short
paragraph explaining why they belong in this delivery. Then continue through
the steps below without a second chat confirmation; the broker's
`approval=require` policy is the authoritative human gate.

## 1. Verify

Run this as its own top-level Bash call, exactly:

```bash
/usr/local/bin/fieldwork-verify "$PWD"
```

If it fails, stop and report the output. Do not bypass or replace the verifier.

## 2. Prepare the commit when the sandbox cannot commit

Create a fresh UUID. Under
`/run/user/<uid>/fieldwork/spool/<prepare-request-id>/`, write the only file,
`request.json`, mode 0600:

```json
{
  "request_id": "<fresh uuid v4>",
  "created_at": "<UTC YYYY-MM-DDTHH:MM:SSZ>",
  "repo_path": "/home/fieldwork/projects/<slug>",
  "branch": "fieldwork/<short-feature-name>",
  "paths": ["<every dirty repo-relative path, and no others>"],
  "message": "<commit message>"
}
```

The branch must not already exist when using the prepare runner. Paths may not
be absolute or contain `..`. Invoke the root-owned prepare client as a separate
top-level Bash call with the UUID—not a file path:

```bash
/usr/local/bin/fieldwork-pr-prepare <prepare-request-id>
```

If the intended branch already exists, commit normally only when the active
sandbox permits it. Otherwise stop for operator guidance; never bypass the
runner by weakening the sandbox.

## 3. Build the protocol-v2 request

Ensure every intended change is committed and the worktree is clean. Write
`.fieldwork/local/pr-build-request.json`:

```json
{
  "schema_version": 2,
  "slug": "<slug>",
  "branch": "fieldwork/<same branch>",
  "title": "<PR title>",
  "body": "<summary and verification>"
}
```

Run the sandboxed builder:

```bash
/usr/local/bin/fieldwork-pr-build .fieldwork/local/pr-build-request.json
```

Record the UUID it prints.

## 4. Upload in a separate call

Run the excluded uploader as a new top-level Bash call:

```bash
/usr/local/bin/fieldwork-pr-upload <request-id>
```

Report `queued`, `done`, or the fixed broker error code. A queued request must
be approved through the isolated approval path before any branch push occurs.
The broker reconstructs and scans the non-thin pack, checks the operator-owned
policy/base, and opens or updates the PR. Never combine build and upload in one
shell command.
