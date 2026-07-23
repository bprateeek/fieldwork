---
name: pr-delivery
description: Commit and deliver a Fieldwork change through protocol v2.
---

Ensure the worktree is clean and all intended files are committed. Create a JSON
input containing `slug`, a `fieldwork/...` branch, `title`, and `body`; optionally
include `common_base_oid`. Run `fieldwork-pr-build <file>` inside the sandbox.
Then, as a separate top-level Bash call, run
`/usr/local/bin/fieldwork-pr-upload <request-id>`. Report whether the broker
returned `queued`, `done`, or an error code. Never push directly.
