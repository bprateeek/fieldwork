# Fieldwork hard-boundary delivery

Work only in the current repository. Commit all intended changes before delivery.
The upload phase is exactly two separate top-level tool calls:

1. `/usr/local/bin/fieldwork-pr-build .fieldwork/local/pr-build-request.json`
   and note the printed request ID.
2. `/usr/local/bin/fieldwork-pr-upload <request-id>` (excluded uploader).

Never try to combine those commands in one shell expression. The broker rebuilds
and scans the Git pack and may queue it for human approval.
