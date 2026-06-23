# CLI Reference

One-line index of every `fieldwork` subcommand and where to read more. Commands that are not covered in another doc (`dashboard`, `report`, `start`, `status`) get a full section here.

For the guided path, start with `fieldwork quickstart` and follow what it prints.
Use `fieldwork setup` directly when you want the step-by-step setup-only path.

## Index

| Command           | One line                                                                                                        | Authoritative doc                                                                  |
| ----------------- | --------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `quickstart`      | Resumable public setup + repo onboarding path; skips completed phases from its local phase ledger.              | [quickstart.md](quickstart.md), [§ `fieldwork quickstart`](#fieldwork-quickstart-ownerrepo) below |
| `setup`           | First-run command center; connects the VPS, prepares the server, and prints the next action when it needs help. | [setup.md](setup.md)                                                               |
| `provision`       | Create a VPS (Hetzner) via the `hcloud` CLI + cloud-init, write the SSH alias, and hand off to `setup`.         | [first-time-infrastructure.md](first-time-infrastructure.md)                       |
| `uninstall`       | Guided teardown for Fieldwork-managed local, remote, broker, and approval-bot assets.                           | [uninstall.md](uninstall.md)                                                       |
| `health`          | One-glance OK/not-OK across local, VPS, agents, broker, sockets, token, approvals. Soft daily check.            | [§ `fieldwork health`](#fieldwork-health) below                                    |
| `dashboard`       | Open a read-only localhost dashboard backed by VPS Fieldwork state.                                             | [§ `fieldwork dashboard`](#fieldwork-dashboard) below                              |
| `doctor`          | Diagnose local + remote state; prints next action and remaining follow-ups.                                     | [troubleshooting.md](troubleshooting.md)                                           |
| `setup-notify`    | Configure optional mobile notifications (ntfy by default; `--telegram-bot` for the approval-gate bot).          | [notifications.md](notifications.md), [approval-gate.md](approval-gate.md)         |
| `sync-vps`        | Sync the local Fieldwork checkout to the VPS over `rsync`.                                                      | [setup.md](setup.md)                                                               |
| `verify-security` | Audit the trust boundary: token modes, socket modes, broker hardening, notification isolation.                  | [threat-model.md](threat-model.md)                                                 |
| `eval`            | Run the no-VPS Docker evaluation harness. Evaluation only, not production.                                      | [evaluation.md](evaluation.md)                                                     |
| `log`             | Read the broker-owned audit JSONL log.                                                                          | [§ `fieldwork log`](#fieldwork-log-repo-slug---json---since-duration-or-utc) below |
| `adapter`         | List or diagnose Fieldwork agent adapters.                                                                      | [agent-adapters.md](agent-adapters.md)                                             |
| `report`          | Read-only, secret-redacted support report for developer-preview issues.                                         | [§ `fieldwork report`](#fieldwork-report-repo-slug) below                          |
| `smoke`           | Create a tiny PR through the broker without a coding agent. Proves the socket + PAT + push + PR path.          | [runbook.md](runbook.md)                                                           |
| `bootstrap-vps`   | Run the 10-phase VPS bootstrap (packages, systemd template, runners, …). Invoked on the VPS itself.             | [quickstart.md](quickstart.md)                                                     |
| `install-broker`  | Install the PR broker on the VPS (called as root). Invoked by setup or advanced operator flows.                 | [setup.md](setup.md), [broker-standalone.md](broker-standalone.md)                 |
| `onboard`         | Clone a repo to the VPS, apply templates, open the init PR, and start Claude service when configured.           | [setup.md](setup.md), [runbook.md](runbook.md)                                     |
| `refresh`         | Fast-forward the VPS checkout after merge; restart Claude service only when configured.                         | [§ `fieldwork refresh`](#fieldwork-refresh-repo-slug) below                        |
| `start`           | Start Claude service when configured; print Codex Desktop SSH instructions when configured.                     | [§ `fieldwork start`](#fieldwork-start-repo-slug) below                            |
| `status`          | Show repo, broker, runner, delivery-client, Claude, and Codex readiness.                                        | [§ `fieldwork status`](#fieldwork-status-repo-slug) below                          |
| `bot-status`      | Inspect the Telegram approval bot pipeline: polling, pending queue, sockets, and config.                        | [§ `fieldwork bot-status`](#fieldwork-bot-status) below                            |

`fieldwork --help` prints the same surface with full argument syntax.

---

## `fieldwork quickstart [owner/repo]`

```text
usage: fieldwork quickstart [owner/repo] [options]
```

Public, resumable first-run path. It is intentionally a thin orchestrator over
the existing commands: setup still owns local/VPS readiness and account prompts,
and onboarding still owns repo cloning, templates, init PR creation, and its
repo-side checkpoint.

Quickstart adds one local phase ledger under
`~/.config/fieldwork/quickstart/<profile>/`. Once setup succeeds, later
quickstart runs skip setup. Once onboarding succeeds for a repo, later
quickstart runs skip onboarding for that repo. Use `--status` to inspect the
ledger without changing anything, or `--reset-state` to remove quickstart's
phase ledger before running again.

Common forms:

```sh
fieldwork quickstart --agent codex
fieldwork quickstart <owner>/<repo> --agent codex --with-approval-gate
fieldwork quickstart <owner>/<repo> --dry-run
fieldwork quickstart <owner>/<repo> --status
```

Flags:

| Flag | Meaning |
|---|---|
| `--agent claude\|codex\|both` | Passed to `fieldwork setup`. |
| `--yes` | Passed to `fieldwork setup`. |
| `--skip-sync` | Passed to `fieldwork setup`. |
| `--force-install` | Passed to `fieldwork setup`. |
| `--branch fieldwork/init` | Passed to `fieldwork onboard`. Requires `<owner/repo>`. |
| `--no-workflows` | Passed to `fieldwork onboard`. Requires `<owner/repo>`. |
| `--with-approval-gate` | Passed to `fieldwork onboard`. Requires `<owner/repo>`. |
| `--reseed-templates` | Passed to `fieldwork onboard`. Requires `<owner/repo>`. |
| `--dry-run` | Run a read-only doctor preflight for quickstart without setup, onboarding, or ledger writes. |
| `--status` | Print quickstart phase state without running setup or onboarding. |
| `--reset-state` | Remove quickstart's local phase ledger before continuing. |

See [quickstart.md](quickstart.md).

---

## `fieldwork setup`

```text
usage: fieldwork setup [--agent claude|codex|both] [--yes] [--skip-sync] [--force-install]
```

Guided first-run command center. It checks local dependencies, SSH alias, VPS reachability, remote Fieldwork install, VPS bootstrap, account follow-ups, PR service readiness, temporary sudo cleanup, and next actions. If `--agent` is omitted, setup prompts in an interactive terminal and defaults to `claude`; non-interactive setup also defaults to `claude`.

Safe to rerun: completed checks are detected, and pending steps are rechecked before continuing. It prints the next manual action and, when useful, the command to run after that action completes.

Common flags:

| Flag | Meaning |
|---|---|
| `--agent claude\|codex\|both` | Configure Claude remote-control, Codex Desktop + SSH, or both. Persisted in `~/.fieldwork/agents`. |
| `--yes` | Accept guided yes/no prompts where setup can safely continue. |
| `--skip-sync` | Do not sync the local checkout to the VPS during this run. |
| `--force-install` | Force replacement of Fieldwork-managed installed assets during sync/install. |

Rerun speed controls:

| Environment variable                              | Meaning                                                                                                                                       |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `FIELDWORK_SSH_MULTIPLEX=0`                       | Disable Fieldwork's SSH ControlMaster reuse for the current command.                                                                          |
| `FIELDWORK_SSH_CONTROL_PERSIST=<seconds>`         | Set the OpenSSH `ControlPersist` value. Default is `600`; `0` means OpenSSH closes the master when the last session exits.                    |
| `FIELDWORK_SSH_DEBUG=1`                           | Print whether Fieldwork is using a control socket.                                                                                            |
| `FIELDWORK_SETUP_PROBE_TIMEOUT_SECONDS=<seconds>` | Bound the one-shot setup remote-state probe. Default is `8`; the watchdog is Bash 3.2-compatible.                                             |
| `FIELDWORK_CODEX_NPM_PACKAGE=<pkg>`               | Override the pinned Codex npm package used when setup offers to install Codex. Default is `@openai/codex@0.137.0`.                         |

Fieldwork stores SSH control sockets under `~/.cache/fieldwork/ssh-control/`.
If SSH multiplexing ever behaves oddly, this reset is safe:

```sh
rm -rf ~/.cache/fieldwork/ssh-control
```

The setup probe is in-memory only. Fieldwork does not write a setup state cache
or cache secret/auth validity on disk.

See [setup.md](setup.md).

---

## `fieldwork provision <provider>`

```text
usage: fieldwork provision hetzner [--type <t>] [--location <l>] [--name <n>]
                                   [--ssh-key-file <path>] [--dry-run] [--show-key]
       fieldwork provision hetzner --destroy [--name <server>] [--yes]
```

Creates the VPS that the rest of Fieldwork already knows how to configure, then
stops. It does **not** run `setup`. Only `hetzner` is supported today.
Bring-your-own VPS stays fully supported; provisioning is additive.

It uses the [`hcloud` CLI](https://github.com/hetznercloud/cli); Hetzner access
comes from `HCLOUD_TOKEN` or an active `hcloud` context. **Fieldwork never reads
or stores the token.** The server name, SSH-key name, and `managed-by=fieldwork`
/ `fieldwork-profile` / `fieldwork-ssh-host` labels all derive from the resolved
config object, so the command is deterministic and re-runnable.

What create does: validates the server name from `ssh_host`, uploads
`~/.ssh/id_ed25519.pub`, renders a minimal cloud-init (creates the `fieldwork`
user with sudo + the temporary passwordless-sudo rule `setup` expects, installs
the key), creates an Ubuntu 24.04 server, and appends a managed `~/.ssh/config`
alias with `StrictHostKeyChecking accept-new`. Re-running when the server already
exists just re-resolves the IP and re-writes the alias.

| Flag                    | Meaning                                                                                                                 |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `--type <t>`            | Hetzner server type (default `cx23`).                                                                                   |
| `--location <l>`        | Hetzner location (default `nbg1`).                                                                                      |
| `--name <n>`            | Override the server name (default: `ssh_host`).                                                                         |
| `--ssh-key-file <path>` | Public key to install (default `~/.ssh/id_ed25519.pub`).                                                                |
| `--dry-run`             | Print the plan + cloud-init without creating anything. The public key is shown redacted (type + comment + fingerprint). |
| `--show-key`            | With `--dry-run`, print the full public key instead of the redacted form.                                               |
| `--destroy`             | Delete the Fieldwork-managed server for this profile. Requires exactly one labelled match, or pass `--name`.            |
| `--yes`                 | Skip the destroy confirmation.                                                                                          |

Destroy deletes the server and its managed SSH key but leaves the `~/.ssh/config`
alias in place; `fieldwork uninstall` removes that block.

After create, continue with `fieldwork sync-vps` then `fieldwork setup`. See
[first-time-infrastructure.md](first-time-infrastructure.md).

---

## `fieldwork uninstall`

```text
usage: fieldwork uninstall [--dry-run] [--yes] [--quiet] [--local] [--remote] [--broker] [--bot] [--no-broker] [--purge] [--remove-system-users]
```

Guided teardown for Fieldwork-managed assets. The default scope removes
discovered local files, remote user services/scripts, broker/system services, and
approval-bot infrastructure after showing a plan.

It keeps repositories, SSH keys, non-Fieldwork SSH config, VPS users, Docker,
GitHub CLI, Claude Code, and user-authored Claude config. Use `--dry-run` to
preview without changing anything. `--quiet` suppresses successful/skipped
removal rows, but failures and the final manual-action checklist still print.

See [uninstall.md](uninstall.md).

---

## `fieldwork health`

```text
usage: fieldwork health
```

One-glance health summary, designed as a soft daily check (`doctor`/`status`/`bot-status` remain the deep-dive tools). It composes a single remote probe and, only when that probe is trusted, one bounded broker/bot snapshot, so it stays cheap and never hangs on an unreachable or stuck VPS.

It reports one line per area: local tooling, VPS reachability/freshness, GitHub auth, each configured agent, runner sockets, the broker, the broker token, and (when configured) the approval bot. Each line is `ok`, `needs` attention, `blocked`, or `info`.

Behaviour worth knowing:

- **Exit status is nonzero only when something is `blocked`** (for example, the VPS is unreachable). Items that merely need attention, or are optional and not configured, still exit `0`. It is a glance, not a strict gate.
- When the VPS is reachable but its Fieldwork checkout is stale or untrusted, you get a `needs` row pointing at `fieldwork sync-vps`. See [VPS reachable but untrusted](troubleshooting.md#vps-untrusted).
- When the VPS is unreachable, you get a single `blocked` row. See [VPS unreachable](troubleshooting.md#vps-unreachable).
- **Codex** coverage is CLI + login only; allowlist/sandbox delivery readiness stays in `fieldwork doctor`.
- The approval bot counts as `needs` only when it is configured (or has pending approvals) but not running; an unconfigured bot is reported as optional and excluded from the verdict.

---

## `fieldwork doctor [--remote] [repo-slug] [--explain] [--session-probe]`

```text
usage: fieldwork doctor [--remote] [repo-slug] [--explain] [--session-probe]
```

Read-only diagnostic companion to setup. With `--remote`, it checks the VPS and prints a phase-ordered diagnosis. With `--explain`, it includes why each missing piece matters.

Pass a repo slug with `--remote` to include verify dependency readiness for that checkout, such as Node/npm, Go, cargo, Python, and Node `node_modules`. The slug check also reports when the checkout is parked on the unmerged `fieldwork/init` branch (sessions stay gated until `fieldwork refresh`) or has uncommitted changes. When Codex is configured, the slug also lets doctor check whether local Codex Desktop state has recorded the VPS checkout folder `/home/fieldwork/projects/<slug>`.

`--session-probe` (requires `--remote`) runs claude headless inside a synthetic cage on the VPS (NoNewPrivs + a fresh user namespace, the same runtime the agent gets from `remote-control --sandbox`) and confirms `sandbox.excludedCommands` still rescue the fieldwork socket clients on the installed claude version. It is opt-in because it spends model tokens and needs a confirmed Claude login; run it after claude CLI updates.

Use this before manually debugging SSH, broker, notification, service, or Codex Desktop SSH failures. Codex checks include safe local Desktop state booleans, remote Codex CLI version/auth status, and sanitized app-server signals such as stale socket or ended app session. Doctor never prints Codex auth files, device codes, raw app-server logs, or token-shaped values.

---

## `fieldwork dashboard`

```text
usage: fieldwork dashboard [--local-port <port>] [--remote-port <port>] [--no-open]
```

Starts `fieldwork-dashboard.service` as a user service on the VPS, forwards it over SSH to `http://127.0.0.1:<local-port>/`, and opens that local URL in your browser. Keep the command running while using the dashboard; Ctrl-C closes the tunnel.

The remote server binds only to `127.0.0.1` and exposes read-only GET routes:

```text
/            browser dashboard
/api/status  JSON snapshot
/healthz     health probe
```

The snapshot comes from `fieldwork-status-snapshot`, which reads `~/.fieldwork/state/events`, `~/.fieldwork/state/resume-context`, `~/.fieldwork/project-journals`, and the broker audit JSONL log when the agent user's audit-read ACL allows it. It does not SSH, call `fieldwork status`, or invoke shell renderers.

Flags:

| Flag | Meaning |
|---|---|
| `--local-port <port>` | Local loopback port for the SSH tunnel. Default: `8765`. |
| `--remote-port <port>` | VPS loopback port used by the dashboard service. Default: `8765`. |
| `--no-open` | Print the URL without launching a browser. |

---

## `fieldwork onboard <owner>/<repo>`

```text
usage: fieldwork onboard <owner>/<repo> [--branch fieldwork/init] [--no-workflows] [--with-approval-gate] [--status] [--reset-state] [--reseed-templates]
```

Onboards a GitHub repo onto the VPS. It validates the repo shape, asks the broker to prove PAT reachability, clones with a read-only deploy key, applies repo templates, and opens the init PR through the broker. In Claude mode it also primes Claude workspace trust and remote-control consent and starts `fieldwork-agent@<slug>.service`. In Codex mode, Codex Desktop owns the live SSH connection and remote-project folder state.

Flags:

| Flag                   | Meaning                                                                                       |
| ---------------------- | --------------------------------------------------------------------------------------------- |
| `--branch <name>`      | Init PR branch. Must match the broker `fieldwork/...` branch policy.                          |
| `--no-workflows`       | Skip workflow templates so the broker PAT does not need Workflows read/write for the init PR and users can add CI manually later. |
| `--with-approval-gate` | Commit `.fieldwork/approval-gate` so future PR requests queue for Telegram approval.          |
| `--status`             | Inspect onboarding checkpoint without changing state.                                         |
| `--reset-state`        | Remove only the onboarding checkpoint and recompute from repo state.                          |
| `--reseed-templates`   | Re-apply Fieldwork-managed templates to an already onboarded repo after a Fieldwork upgrade.  |

See [setup.md](setup.md) and [approval-gate.md](approval-gate.md).

---

## `fieldwork setup-notify`

```text
usage: fieldwork setup-notify [--remote] [--topic <ntfy-topic>] [--yes]
usage: fieldwork setup-notify --telegram-bot [--yes]
```

Configures optional mobile notifications. The default mode configures ntfy locally or remotely. `--telegram-bot` installs the approval-gate bot daemon on the VPS.

See [notifications.md](notifications.md) and [approval-gate.md](approval-gate.md).

---

## `fieldwork verify-security [--remote] [repo-slug]`

```text
usage: fieldwork verify-security [--remote] [repo-slug]
```

`verify-security` always audits the configured VPS. `--remote` is accepted as
an explicit form for consistency with `doctor`, but there is no local-only mode.

## `fieldwork eval up|smoke|logs|down|clean`

Docker-backed, no-VPS evaluation harness. It uses fake GitHub behavior and no
real PAT. This is evaluation only and not a supported deployment topology.

See [evaluation.md](evaluation.md).

---

## `fieldwork log [repo-slug] [--json] [--since <duration-or-utc>]`

Reads the broker audit log from the configured VPS. The audit log records
broker lifecycle events such as request receipt, queue, approve/deny, push
attempt, PR open, rejection, and expiry.

Use `--json` for JSONL output. `--since` accepts values such as `30m`, `12h`,
`7d`, or UTC timestamps like `2026-05-20T00:00:00Z`.

---

## `fieldwork adapter list|doctor`

Lists shipped Fieldwork-launched agent adapters or diagnoses one adapter's
local launch requirements. Claude remote-control is the supported developer
preview adapter. Codex Desktop + SSH support is not an adapter; see
[agent-adapters.md](agent-adapters.md).

See [agent-adapters.md](agent-adapters.md).

Audits Fieldwork's remote security posture. It checks broker token permissions, submit and approve socket permissions, broker hardening directives, notification isolation, optional bot separation, and optional per-repo origin state.

See [threat-model.md](threat-model.md).

---

## `fieldwork refresh <repo-slug>`

```text
usage: fieldwork refresh <repo-slug>
```

Refreshes the VPS checkout after a PR merge. When Claude is configured, it restarts `fieldwork-agent@<slug>` so Claude mobile sees the merged default branch. When Codex is configured, it does not restart anything because Codex Desktop owns its SSH connection state.

It refuses dirty checkouts, reads `.fieldwork/default-branch` with `main` as the fallback, runs `git fetch --prune origin`, checks out the default branch, pulls with `--ff-only`, and restarts the matching Claude systemd user service only when Claude is configured.

Use this after merging a PR that was opened from mobile:

```sh
fieldwork refresh myrepo
```

---

## `fieldwork start <repo-slug>`

```text
usage: fieldwork start <repo-slug>
```

Starts the per-repo Claude Code systemd user session on the VPS via `systemctl --user start fieldwork-agent@<slug>` when Claude is configured, then waits for `is-active`. When Codex is configured, it prints Codex Desktop SSH connection instructions instead of starting a service. In `both` mode it does both and warns that concurrent Claude+Codex work on the same checkout is unsupported.

**When to use it.** For Claude, use it when the per-repo session isn't running and you want to drive it from Claude mobile. For Codex, use it as a reminder of the Codex Desktop SSH host, user, checkout path, and the `"Available from signed-in devices"` setting required for mobile access.

**Sample success output**

```text
== Remote session ==
  repo                  myrepo
  service               fieldwork-agent@myrepo
  [ok] remote Claude session is active

Next action:
  open Claude mobile and use session vps-myrepo
```

**Sample failure output**

```text
== Remote session ==
  repo                  myrepo
  service               fieldwork-agent@myrepo
  [!]  starting remote Claude session

Next action:
  fieldwork status myrepo
```

**Exit codes**

| Code | Meaning                                                                  |
| ---- | ------------------------------------------------------------------------ |
| 0    | service started and `is-active`                                          |
| 1    | service did not become active (run `fieldwork status <slug>` to inspect) |
| 2    | bad arguments (missing slug, invalid slug, extra positional)             |

**Notes**

- The slug is the repo name (the part after `<owner>/`), not `<owner>/<repo>`.
- The Claude session token, login state, and per-repo workspace trust must already exist; this command does not (re)authenticate.
- The session name `vps-<slug>` in Claude mobile maps 1:1 to the service `fieldwork-agent@<slug>`.
- Codex live connection state is owned by Codex Desktop.

---

## `fieldwork status [repo-slug]`

```text
usage: fieldwork status [repo-slug]
       fieldwork status <repo-slug> [--verbose]
       fieldwork status [repo-slug] --queue
```

Read-only view of configured agent readiness. Claude status includes the per-repo systemd service. Codex status includes CLI/login marker, SSH PATH, delivery clients, XDG runtime, runner sockets, Codex socket allowlist, and an in-sandbox socket probe when available. Live Codex connection state is owned by Codex Desktop.

**Without a slug**: lists every `fieldwork-agent@*.service` via `systemctl --user list-units`:

```text
== Remote sessions ==
  listing               fieldwork-agent@*.service

  UNIT                            LOAD   ACTIVE SUB     DESCRIPTION
  fieldwork-agent@myrepo.service  loaded active running Fieldwork agent session for myrepo
  fieldwork-agent@other.service   loaded active running Fieldwork agent session for other
…

Next action:
  fieldwork status <repo-slug>
```

**With a slug**: parses `systemctl --user show` and recent journal lines into a clean per-field summary:

```text
== myrepo ==

  Agent      ✓ running for 1d 4h
  Mobile     ✓ ready
  Sandbox    ✓ enabled
  Worktree   ✓ isolated
  Capacity   0/1
  Memory     122 MB
  Broker     ✓ reachable
  Approvals  ✓ bot active · 0 pending

Open:
  https://claude.ai/code/session_01KjB8xMUtqCi3Ups7LRcpX4

Next:
  fieldwork start myrepo

Debug:
  fieldwork status myrepo --verbose
```

If the agent service is not active, fields show `✗`/`-` and the footer suggests `fieldwork start <slug>`. If the unit is missing the footer suggests `fieldwork onboard`.

The `Broker` and `Approvals` rows are compact health hints for the PR/approval path. If they show `!`, run `fieldwork bot-status` for the deeper approval-bot pipeline check.

The `Last PR` row is best-effort: it reads the broker audit log non-interactively (`sudo -n`). Once setup removes the temporary passwordless-sudo grant this usually reads `unavailable (needs broker sudo on the VPS)`. That is expected, not a failure. When readable it shows the latest event for the repo (opened + URL, queued, rejected, denied, or expired).

**Without a slug**, the listing also includes a `Mobile -> PR queue` block: pending approval requests across all repos with their age. The same block is shown filtered to one repo by `fieldwork status <slug> --queue`.

**With `--queue`**: prints only the `Mobile -> PR queue` block (all repos, or filtered to a slug). Cannot be combined with `--verbose`. The queue is read from the broker's pending dir via the bot snapshot; if that needs sudo it prints a hint instead.

**With `--verbose` (alias: `--systemd``)**:  prints the raw systemd output for debugging:

```text
== Remote session (verbose) ==
  repo                  myrepo
  service               fieldwork-agent@myrepo.service

systemctl --user status:
● fieldwork-agent@myrepo.service - Fieldwork agent session for myrepo
     Loaded: loaded (…; enabled)
     Active: active (running) since …
…

journalctl -n 20:
…
```

**Exit codes**

| Code | Meaning                                                             |
| ---- | ------------------------------------------------------------------- |
| 0    | agent is active (slug form) or the listing succeeded (no-slug form) |
| 1    | agent is not active, not installed, or the VPS was unreachable      |
| 2    | bad arguments (invalid slug, extra positional, unknown flag)        |

**Notes**

- Does not change any state.
- For a deeper diagnostic that also covers the agent's environment (PATH, login state, broker socket reachability), use `fieldwork doctor --remote --explain`.
- For one-line repo-by-repo state across the whole VPS the no-arg form is fastest; for log tails on a specific service the slug form is the one.

---

## `fieldwork bot-status`

```text
usage: fieldwork bot-status
```

Read-only health view for the Telegram approval-gate pipeline. It combines root systemd service state, the bot's secret-free health file, pending approval files, and live socket probes.

**Sample healthy output**

```text
== Telegram approval bot ==

  Service          ✓ running
  Polling          ✓ healthy
  Last poll        12s ago
  Pending          2 requests
  Oldest pending   7m 42s
  Broker submit    ✓ reachable
  Approve socket   ✓ reachable
  Token config     ✓ present
  Chat binding     ✓ configured

Pending requests:
  1. owner/repo · fieldwork/fix-status-ui · 7m ago
  2. owner/cli · fieldwork/cli-decompose · 2m ago

Next:
  open Telegram and approve/deny pending requests
```

**Sample broken output**

```text
== Telegram approval bot ==

  Service          ✗ not running
  Polling          - unknown
  Last poll        23m ago
  Pending          1 request
  Oldest pending   23m 10s
  Broker submit    ✓ reachable
  Approve socket   ! socket present; sudo probe unavailable
  Token config     ✓ present
  Chat binding     ✓ configured

Fix:
  ssh -t fieldwork-vps "sudo systemctl restart fieldwork-bot.service"
  fieldwork doctor --remote
```

The bot writes `/var/lib/fieldwork-bot/bot-health.json` with timestamps, last poll/callback result, pending count, oldest pending age, and secret-free pending repo/branch summaries. `bot-status` does not rely on `systemctl is-active` alone; an active service with stale or failing Telegram polls still shows as unhealthy.

**Exit codes**

| Code | Meaning                                                               |
| ---- | --------------------------------------------------------------------- |
| 0    | approval-bot pipeline looks healthy; pending requests may still exist |
| 1    | service, polling, config, or socket health is broken or unknown       |
| 2    | bad arguments                                                         |

---

## `fieldwork report [repo-slug]`

```text
usage: fieldwork report [repo-slug]

Prints a read-only, secret-redacted support report for developer preview issues.
Pass a repo slug to include onboarding/checkout status for that repo.
```

Generates a structured, read-only snapshot of the local + remote Fieldwork install, intended to be pasted directly into a developer-preview support issue. Designed to redact secrets: no token bytes, no key bytes, no ntfy topic, no Telegram chat IDs.

**When to use it.** Filing a bug. Asking for help. After `fieldwork doctor` says "blocked" and you want a single artifact that captures the state for someone else to read. Before-and-after a setup change when you want to see what moved.

**What it checks.** In order:

- **Local**: `fieldwork_root`, `cli_path`, resolved config (`ssh_host`, `remote_user`, `projects_dir`, `default_branch`, `notify_provider`); presence of CLI deps (`bash`, `git`, `jq`, `ssh`, `scp`, `sed`, `grep`, `rsync`); `lib/scripts/fieldwork-onboard` executable; `lib/broker/server.py` present; `~/.fieldwork/notify.env` present.
- **SSH**: `ssh -G` resolution of `$FIELDWORK_SSH_HOST`; remote reachability (`ssh -o BatchMode=yes -o ConnectTimeout=5 ... true`).
- **Remote** (skipped if SSH is blocked): configured agents from `~/.fieldwork/agents`; `claude`, `codex`, and `gh` as applicable; `gh auth status`; `$FIELDWORK_PROJECTS_DIR` exists; `~/.fieldwork/notify.env` on the VPS; Claude systemd unit when configured; runner sockets and broker socket writable.
- **Repo** (only when a slug is passed): repo checkout exists; `.fieldwork/expected-origin` present; worktree clean; onboarding checkpoint at `.fieldwork/local/fieldwork-onboard-state.json` parses and lists completed steps.

**Sample output (clean install)**

```text
Fieldwork report
Generated: 2026-05-18T10:34:00Z
Secrets: omitted

== Local ==
  fieldwork_root: ~/fieldwork
  cli_path: ~/.local/bin/fieldwork
  ssh_host: fieldwork-vps
  remote_user: fieldwork
  projects_dir: /home/fieldwork/projects
  default_branch: main
  notify_provider: ntfy
  [ok] bash found
  [ok] git found
…
  [ok] local notification config present

== SSH ==
  [ok] SSH alias resolves
  resolved_host: 100.x.y.z
  resolved_user: fieldwork
  [ok] VPS reachable over SSH

== Remote ==
  [ok] remote Claude Code CLI installed
…
  [ok] broker socket writable

Next action:
  fieldwork setup
```

**Sample output (broken state)**

```text
…
== SSH ==
  missing SSH alias resolves
  blocked VPS reachable over SSH
== Remote ==
  skipped remote checks skipped because SSH is blocked

Next action:
  add Host fieldwork-vps to ~/.ssh/config, then rerun fieldwork setup
```

**Status legend**

| Row prefix | Meaning                                                                |
| ---------- | ---------------------------------------------------------------------- |
| `[ok]`     | check passed                                                           |
| `missing`  | expected artifact not found                                            |
| `blocked`  | reachable failure (e.g. SSH refused)                                   |
| `warn`     | present but in an unexpected shape (e.g. unparseable onboarding state) |
| `skipped`  | not run because a prerequisite earlier in the report failed            |

**Next-action selection.** The footer is a single recommended next step. The order of precedence: first concrete missing dep (e.g. install `jq`) → SSH alias missing → SSH blocked → onboarding checkpoint problem on the named repo → fall back to `fieldwork setup` (no slug) or `fieldwork smoke <owner>/<slug>` (with slug). It is a hint; read the full body before acting.

**Exit codes**

| Code | Meaning                                                                                                                  |
| ---- | ------------------------------------------------------------------------------------------------------------------------ |
| 0    | report printed (regardless of how many rows are `missing`/_reporting_ command, this is a _reporting_ command, not a _gating_ one) |
| 2    | bad arguments (invalid slug, extra positional, unknown flag)                                                             |

**What `report` does NOT do**

- It does not write to disk, change config, or restart services. Safe to run any time.
- It does not redact known-secret-shape strings from the output beyond not reading them in the first place. It does not echo PAT contents, key bytes, ntfy topics, or Telegram tokens because it never reads them. `verify-security` is what audits the on-disk shape of those secrets, including their modes and owners.
- It is not a replacement for `fieldwork doctor --remote --explain`. Doctor is the prescriptive sibling (per-phase guidance, repair commands); `report` is the descriptive one (snapshot for someone else to read).
