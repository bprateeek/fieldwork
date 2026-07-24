# Typed notifications

The notification queue is not a general text relay. Producers may write only:

```json
{
  "schema_version": 1,
  "event": "queued",
  "request_id": "f02865ee-bbed-45cb-8b32-b1b987916105",
  "slug": "example",
  "error_code": null
}
```

Allowed events are `queued`, `approved`, `denied`, `pushed`,
`pr_created`, and `error`. Fields and lengths are validated; unknown fields,
unknown events, and malformed identifiers are rejected. There is no free-text
field.

The bot maps the enum to fixed templates. Captured process stderr, task prompts,
commit messages, filenames, PR bodies, and producer-supplied labels never become
Telegram text. Errors map to fixed codes.

## Ownership

Production producers are the broker and root-installed runners. The agent
cannot write the queue. The bot can consume/delete notification drops and write
its own dedupe/sidecar state, but it cannot mount:

- forge token;
- broker policy or CA store;
- pending pack;
- pending MAC key;
- local bearer;
- Docker socket.

Pending metadata is mounted read-only. Approvals use a separate restricted Unix
socket and HMAC secret.

## Configuration

Local:

```sh
sudo fieldwork-local telegram
```

The root-owned control plane collects configuration through a TTY, generates
the approval HMAC secret, and starts the bot profile.

VPS:

```sh
fieldwork setup-notify --telegram-bot
```

Treat Telegram as an approval transport, not as a confidentiality boundary.
Review the forge PR/MR before merge. If bot credentials may have escaped, rotate
the bot token and approval HMAC secret; rotating the forge token is a separate
broker operation.
