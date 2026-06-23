# Standalone Broker

> Advanced / operator path. The supported developer preview path is `fieldwork setup`.
> Use this guide only when you are integrating the PR broker with a non-Fieldwork
> agent or custom control plane.

The Fieldwork PR broker is a small Linux daemon that owns a GitHub PAT, listens
on a Unix socket for JSON PR requests from an unprivileged agent user, and
opens the PR on the agent's behalf. **You don't need the rest of Fieldwork to
use it.** Any coding agent (Claude, Codex, OpenAI Agent SDK, a CI runner, anything
that can write a JSON request) can submit PRs through it without ever holding a
GitHub token itself.

If you are running Fieldwork end-to-end, run `fieldwork setup` and use
[`setup.md`](setup.md) instead. Setup handles broker install for you. This page
is for **broker-only** installs.

## What you get

- A systemd-managed daemon (`fieldwork-pr-broker.service`) running as its own
  user, with the PAT in a 0600 file only it can read.
- A Unix socket at `/run/fieldwork-pr-broker/fieldwork-pr.sock`, group-writable
  by your agent user.
- A `rotate-pat` helper to (re)store the PAT without it ever passing through
  argv or environment.
- A documented JSON request contract (see [`broker-contract.md`](broker-contract.md))
  and [`../schema/pr-request.schema.json`](../schema/pr-request.schema.json).
- Replay protection (per-request UUID, stored ledger), per-repo rate limiting,
  secret-shaped body scanning via `gitleaks`, branch-prefix enforcement, and
  origin-spoofing checks. See [`threat-model.md`](threat-model.md).

The broker is agent-agnostic: it does not know or care which coding agent
produced the commit, only that the request satisfies the contract.

## Prerequisites

These must already be installed on the host. The standalone installer **does
not** install them. It only checks for them and fails fast if anything is
missing:

- Ubuntu 24.04 LTS (other systemd-based distros likely work; only 24.04 is
  tested in developer preview).
- `python3` (3.8+, stdlib only, no pip packages needed).
- `gh` (the GitHub CLI), used by the broker to create PRs.
- `gitleaks`, used by the broker to scan the PR body before opening.
- An unprivileged agent user that already exists on the host. The broker reads
  per-repo checkouts under that user's home; it does not need write access there.

If you already use Fieldwork's `bootstrap-vps.sh` you have all of these. If you
are wiring the broker into a different agent host, install them however your
distro prefers.

## Install

From a checkout of this repo on the target host:

```bash
sudo bash lib/broker/standalone-install.sh \
  --agent-user alice \
  --projects-root /home/alice/projects
```

Flags (all optional except `--agent-user`):

| Flag | Default | Purpose |
|---|---|---|
| `--agent-user` | (required) | Unprivileged user that will submit requests. Must already exist; the broker socket group is added to this user. |
| `--projects-root` | `/home/<agent-user>/projects` | Directory containing per-repo checkouts the broker may read and push from. |
| `--broker-user` | `fieldwork-pr-broker` | Broker daemon user. |
| `--broker-group` | agent user's primary group | Socket-access group for the submit socket. Leave unset unless you know your agent preserves supplementary groups. |
| `--verbose` | off | Stream raw install output instead of buffering to the install log. |
| `--log-file <path>` | auto | Override the install log path. |

After the install completes:

1. Store the broker's GitHub PAT (broker reads it from a 0600 file; this is the
   only path the PAT takes into the broker):

   ```bash
   sudo /usr/local/sbin/rotate-pat
   ```

2. Confirm the broker is up:

   ```bash
   systemctl status fieldwork-pr-broker.service
   ls -l /run/fieldwork-pr-broker/fieldwork-pr.sock
   # srw-rw---- 1 fieldwork-pr-broker alice ... fieldwork-pr.sock
   ```

3. Confirm the agent can see the socket group. By default this is the agent
   user's primary group, so no extra membership is needed. If you passed
   `--broker-group`, reconnect after install so the new group is visible:

   ```bash
   id alice
   ```

## Per-repo setup

For each repository the agent will work on, the checkout must:

- Live under `--projects-root` (default `/home/<agent-user>/projects/<slug>`).
- Contain a `.fieldwork/expected-origin` file with the HTTPS GitHub URL of the
  upstream repo (one line, e.g. `https://github.com/owner/repo.git`).
- Have its `origin` remote pointing at the same `owner/repo` (HTTPS or
  `git@github.com:`-style). The broker checks both and refuses if they don't
  match.

This is how the broker prevents an attacker who can change the local checkout's
remote from re-pointing pushes at a different repo.

## Submitting a PR

The agent assembles a JSON request that matches
[`../schema/pr-request.schema.json`](../schema/pr-request.schema.json) and POSTs
it to the broker's Unix socket.

### Python (reference client)

The repo ships [`../examples/broker-client.py`](../examples/broker-client.py),
~50 lines, stdlib only. Drop it into any agent project:

```bash
python3 examples/broker-client.py path/to/request.json
# prints https://github.com/owner/repo/pull/123
```

Request file:

```json
{
  "request_id": "2d7b8cf0-6c9d-42e2-a0e1-f8d3c4d5f678",
  "created_at": "2026-05-11T10:30:00Z",
  "repo_path": "/home/alice/projects/my-app",
  "branch": "fieldwork/fix-login-redirect",
  "title": "Fix login redirect after auth",
  "body": "Summary:\n- Preserve next URL during login.\n\nTests:\n- npm test"
}
```

`request_id` must be a fresh UUID. Duplicates are rejected with HTTP 409 as
replay protection. The branch prefix (`fieldwork` by default) is configurable
via `FIELDWORK_BROKER_BRANCH_PREFIX` at install time.

### curl

`curl` speaks Unix sockets directly; useful from shells and CI without writing
client code:

```bash
curl --unix-socket /run/fieldwork-pr-broker/fieldwork-pr.sock \
  -H 'Content-Type: application/json' \
  --data @request.json \
  http://localhost/pr
```

The `Host:` header is required by HTTP/1.1 but ignored by the broker; any value
works.

### Any other language

Open a `AF_UNIX SOCK_STREAM` socket, send a minimal HTTP/1.1 `POST /pr` request
with `Content-Length` and the JSON body, read the response. The wire format is
documented in [`broker-contract.md`](broker-contract.md). The reference Python
client is the smallest correct implementation worth copying.

## Operational notes

- **Logs:** `/var/log/fieldwork-pr-broker.log` (mode 0640, owned by the broker
  user). Includes request IDs, validation results, push attempts, and rejection
  reasons. **Does not include the PAT.**
- **Replay ledger:** `/var/lib/fieldwork-pr-broker/requests/<request_id>.json`,
  one file per accepted request, mode 0600.
- **Rate limit:** 12 PRs per hour per `owner/repo`, in-memory; resets on broker
  restart. Adjust with `FIELDWORK_BROKER_RATE_LIMIT_PER_HOUR` in the broker
  service environment. Bad values fall back to the default; values are clamped
  to `1..120`.
- **PAT rotation:** `sudo /usr/local/sbin/rotate-pat` prompts for the new PAT
  and writes it atomically; the broker re-reads on the next request.
- **Re-install:** `lib/broker/standalone-install.sh` is idempotent; rerun it
  after a Fieldwork upgrade to pick up new daemon code. The ledger, log, and
  PAT are preserved.

## Trust model in one paragraph

Two unix uids. The **broker user** holds the GitHub PAT and runs the daemon.
The **agent user** writes commits to checkouts under `--projects-root` and
submits JSON requests over a socket whose group it is in. Cross-uid auth is by
filesystem group on the socket. There are no shared secrets in env vars or
config files between them. The broker validates every request before any
GitHub-side action; rejected requests never touch `git push` or `gh pr create`.
Full detail in [`threat-model.md`](threat-model.md).

## Writing your own agent adapter

If you want your agent to plug into a Fieldwork host the way Claude Code does
(rather than just calling the broker directly from your own code), see
[`agent-adapters.md`](agent-adapters.md) for the adapter contract.
