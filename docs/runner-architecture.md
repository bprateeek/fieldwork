# Runner and client architecture

Fieldwork uses root-owned system services for every operation that must execute
outside or before the agent sandbox.

## Inventory

Installed in `/usr/local/lib/fieldwork`:

- agent session selector and all `lib/agents/*` adapters;
- task dispatcher and task runner;
- event poller;
- verify/prepare socket runners, implementations, and pipelines.

Installed in `/usr/local/bin`:

- `fieldwork-verify`
- `fieldwork-pr-prepare`
- `fieldwork-pr-build`
- `fieldwork-pr-upload`

All four are root-owned boundary clients. The managed Bash hook admits the
builder only as
`/usr/local/bin/fieldwork-pr-build .fieldwork/local/pr-build-request.json`;
the builder scrubs Git configuration and accepts only validated request data
before writing the untrusted spool.

## System units

`lib/systemd/install-boundary.sh` installs system units in
`/etc/systemd/system`, substitutes the configured agent identity, disables
stale user-unit copies, reloads systemd, and enables the verify/prepare sockets,
event timer, and dispatcher.

Verify and prepare listen at:

```text
/run/fieldwork/fieldwork-verify.sock
/run/fieldwork/fieldwork-pr-prepare.sock
```

The socket owner/mode restricts callers to the agent user. The services use
absolute root-owned `ExecStart` paths and a fixed environment. They do not
inherit the agent session's no-new-privileges/user-namespace state, which lets
the verify runner create its narrower bubblewrap sandbox.

The dashboard is disabled in hard-boundary mode. Rootless Docker may use the
user manager, but no Fieldwork boundary service does.

## Secure spool

Linux uses:

```text
/run/user/<uid>/fieldwork/spool/<request-id>/
```

macOS uses:

```text
/private/var/run/fieldwork/<uid>/spool/<request-id>/
```

The macOS LaunchDaemon recreates the volatile root and UID-owned 0700 parent at
boot. Clients derive the UID with `getuid()`, never an environment variable,
and walk every component from the fixed root using no-follow directory opens.

Operation-specific contents are exact:

- upload: `meta.json` and `pack`;
- verify/prepare: their single request file.

Extra entries, symlinks, unexpected owners, broad modes, and oversized files
are rejected.

## Prepare flow

When the sandbox cannot commit, `fieldwork-pr-prepare` sends only a validated
request UUID over the fixed socket. The root-owned runner reads the exact spool
file, validates that the checkout is under the configured projects root,
creates the `fieldwork/...` branch, stages exactly the requested relative
paths, commits with the configured identity, and leaves a clean checkout.

Prepare is intentionally separate from upload. The upload metadata contains no
checkout path.

## Adapter selection

`fieldwork-agent-session` accepts a validated adapter name and resolves it only
under `/usr/local/lib/fieldwork/agents`. An agent-writable adapter or symlink
cannot influence hard-boundary startup. The Claude adapter launches with only
the remote-control daemon flags supported by the pinned CLI. Root-owned managed
settings enforce the sandbox, customization lockdown, immutable delivery
instructions, and exact boundary-client policy.

## Codex VPS note

VPS Codex may connect to the three fixed Unix sockets through its named socket
allowlist. Local Codex lacks a per-command exclusion and equivalent managed tool
policy, so local hard-boundary mode is Claude-only.
