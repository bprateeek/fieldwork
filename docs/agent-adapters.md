# Agent Adapters

Fieldwork's runner, repo layout, notifications, and PR broker are mostly
**agent-agnostic**. For agents that Fieldwork launches as a long-running
foreground process, the launch point is the **adapter**, a small executable
behind a tiny contract. Add a new adapter, set
`FIELDWORK_AGENT_ADAPTER=<name>`, and Fieldwork will run that agent instead of
Claude Code through the same `fieldwork-agent@<slug>.service` unit.

This page is the contract and a checklist for adding a Fieldwork-launched
adapter. If you just want to use the broker from your own agent code without
integrating with the rest of Fieldwork, see the advanced broker-only operator guide:
[`broker-standalone.md`](broker-standalone.md).

## Codex Is Not An Adapter In This Milestone

Codex support uses the official Codex Desktop + SSH model. The Desktop app
connects as the `fieldwork` Linux user and starts the real `codex` CLI/app
server through that user's login shell. Fieldwork provisions the remote PATH,
runner sockets, `XDG_RUNTIME_DIR`, linger, and Codex sandbox Unix-socket
allowlist, but it does not own the Codex process lifecycle or the local
Desktop remote-project list.

That is why there is no `lib/agents/codex-remote-control`, no
`fieldwork-codex@.service`, no `FIELDWORK_AGENT_ADAPTER=codex`, and no `codex`
PATH shim. Codex readiness lives under `fieldwork setup --agent codex`,
`fieldwork status`, and `fieldwork doctor --remote [slug] --explain`, not under
the adapter contract below. Direct VPS `codex remote-control` and a
Fieldwork-owned Codex mobile controller are future experiments, not the V1
adapter path.

## Where adapters live

```text
lib/agents/<name>           # in the repo (shipped + installed)
~/.fieldwork/infra/agents/<name>   # symlinked on workstation + VPS by install.sh
```

The reference adapter is [`lib/agents/claude-remote-control`](../lib/agents/claude-remote-control).

Inspect adapters with:

```sh
fieldwork adapter list
fieldwork adapter doctor claude-remote-control
```

## The contract

`lib/scripts/fieldwork-agent-session` is the systemd-invoked launcher. For
each per-repo session it picks an adapter name and execs it:

```text
~/.fieldwork/infra/agents/<adapter-name> <repo-slug> <repo-dir>
```

Your adapter must:

1. **Exec a single long-running foreground process.** Do not background,
   fork-and-exit, or detach. `systemd` keeps the adapter alive via
   `Restart=on-failure` on the `fieldwork-agent@<slug>.service` template
   unit. If you fork-and-exit it will be restarted in a tight loop.

2. **Commit work under `$FIELDWORK_BRANCH_PREFIX`** (default `fieldwork`).
   The branch prefix is exported by `fieldwork-agent-session` and the broker
   enforces the same prefix on every PR request. Anything else is rejected.

3. **Never receive the GitHub write token.** PRs go through the broker
   (`lib/scripts/fieldwork-pr-submit`, or your agent's own equivalent that
   POSTs to the broker socket). In the default install, the broker submit
   socket is writable by the agent user's primary group so it survives sandbox
   user-namespace group stripping. The agent user is not in any group that can
   read the PAT file.

4. **Honor `FIELDWORK_SKIP_LOCAL_HOOKS`** for any hooks/notifications you ship.
   When set, the adapter is running in a non-local context (e.g. cloud /
   GitHub Action / remote-control) and hooks that only make sense locally
   should no-op. The Claude adapter relies on Claude Code's own
   `CLAUDE_CODE_REMOTE` for the same effect; new adapters can read either.

5. **Validate `<repo-slug>` if you act on it.** `fieldwork-agent-session`
   already enforces `^[a-z0-9][a-z0-9-]{0,30}$` before exec, so the adapter
   inherits a validated value, but treat it as untrusted defensively if you
   pass it to a shell.

The adapter receives exactly two positional arguments (`<slug>`, `<repo-dir>`)
and inherits the agent user's environment plus `FIELDWORK_*` variables set by
the session wrapper. There is no other implicit input.

`fieldwork-agent-session` also reads non-secret capacity config from
`~/.fieldwork/agent.conf`:

```text
capacity=3
```

The value is parsed as plain `key=value`, never sourced as shell, defaults to
`2`, and is clamped to `1..4`. The validated value is exported to adapters as
`FIELDWORK_AGENT_CAPACITY`.

## Process models

Not every agent is a long-running session. An adapter declares how Fieldwork
drives it with a header line near the top of `lib/agents/<name>`:

```text
# fieldwork-process-model: remote_control_daemon
```

`fieldwork-agent-session` reads it and routes accordingly. An unset or unknown
header defaults to `remote_control_daemon`, so existing adapters are unaffected.

| Process model           | Agent (today) | How Fieldwork drives it                                   |
|-------------------------|---------------|-----------------------------------------------------------|
| `remote_control_daemon` | Claude        | long-running per-repo `fieldwork-agent@<slug>.service`     |
| `desktop_relay`         | Codex         | provisioned env only; no Fieldwork-owned process or unit  |
| `one_shot_job`          | Aider         | queued tasks run to completion by `fieldwork-task-dispatcher` |
| `interactive_shell`     | (manual)      | attach over SSH/tmux; escape hatch, no unit               |

The numbered contract below is the `remote_control_daemon` contract (requirement
1, "exec a single long-running foreground process," applies to that model).
`one_shot_job` agents instead let Fieldwork own the queue, worktree/checkout,
environment injection, diff detection, commit, verify, broker submission, and
cleanup; the agent only edits files. They are launched by the task dispatcher,
not by the per-repo session unit, which exits cleanly if pointed at one.

## Aider (`one_shot_job`)

Aider has no remote-control transport, so it runs as a `one_shot_job`: you queue
a task and Fieldwork runs it to completion. **Fieldwork** owns the queue,
checkout, sandbox, diff detection, commit, verify, and broker submission; the
adapter (`lib/agents/aider`) only edits files.

Operator setup on the VPS:

1. Install aider into a system-path venv (kept out of `$HOME`, which the sandbox
   excludes): `python3 -m venv /opt/fieldwork/aider-venv && /opt/fieldwork/aider-venv/bin/pip install aider-chat`.
2. Configure the BYO model in `~/.fieldwork/aider.conf` (mode 600), parsed
   as `key=value`, never sourced:

   ```
   model = gpt-4o
   base_url = https://api.openai.com/v1
   api_key = sk-...
   # provider = ollama        # for a local Ollama endpoint (base_url only)
   ```

   Per-profile overrides go in a `[profile.NAME]` section.
3. Select the adapter: `FIELDWORK_AGENT_ADAPTER=aider`.

Submit work:

```sh
fieldwork task add <slug> "refactor the auth module"     # CLI, prompt over SSH stdin
fieldwork task list
fieldwork task discard <task-id>
```

How a task runs (`fieldwork-task-run`): the checkout is taken to a clean base;
aider runs **inside a bwrap sandbox** (egress open for the model API, but `$HOME`
excluded, `.git` read-only, and the broker socket + credentials unreachable),
edit-only (`--no-auto-commits`, repo `.aider.conf.yml`/`.env` neutralized); the
model key lives only in that one process's env and is redacted from logs. The
runner then refuses `.fieldwork/**`/`.claude/**`/`.git` edits, commits via the
prepare runner, verifies, and submits through the broker. On any failure the
checkout is restored and a `diff.patch` is kept for inspection; nothing is
submitted unverified.

**Residual risk:** the aider process can read its own environment (unlike the
broker-token isolation), and egress is open, so a hostile model endpoint or
prompt-injected content could exfiltrate the checkout. For maximum isolation run
a localhost Ollama endpoint.

## Adding a new adapter: checklist

A PR adding an adapter should include:

- [ ] **`lib/agents/<name>`**: the adapter executable. Keep it thin: shell
      `exec ...` is usually enough. The Claude adapter is 27 lines including
      the contract comment; treat that as a soft ceiling.
- [ ] **A doc note**: either a section in this file or a short
      `docs/adapters/<name>.md`. Cover:
      - What the adapter actually runs (one sentence).
      - Any environment variables it reads beyond the standard
        `FIELDWORK_*` set.
      - How an operator switches to it (`FIELDWORK_AGENT_ADAPTER=<name>` and
        where to set it for systemd, usually `Environment=` in the unit
        override or a drop-in).
      - Whether the adapter requires extra binaries on the host (e.g. a
        specific CLI version) and how it errors when they are missing.
- [ ] **A smoke test sketch**: even one bash one-liner that exits 0 when the
      adapter's launch command can be assembled (without actually running the
      agent) is enough for the static-checks suite to spot regressions. The
      Claude adapter is covered by the broker validation tests' import-only
      checks today; do the same minimum at least.
- [ ] **Updates to the install fingerprint list**:
      `FIELDWORK_FINGERPRINT_FILES` in `bin/fieldwork` and
      `FIELDWORK_TEST_FINGERPRINT_FILES` in `tests/static-checks.sh` must
      list every shipped file. Add the new adapter to both.

## Reference adapter walkthrough

[`lib/agents/claude-remote-control`](../lib/agents/claude-remote-control) is
the minimum viable adapter:

```bash
exec "$HOME/.local/bin/claude" remote-control \
  --name "vps-$slug" \
  --remote-control-session-name-prefix "vps-$slug" \
  --sandbox --spawn=worktree --capacity="$FIELDWORK_AGENT_CAPACITY"
```

That is the entire adapter. The Claude binary is the long-running foreground
process; the slug becomes the remote-control instance name; sandbox/worktree
flags constrain Claude to a fresh worktree per task, while
`FIELDWORK_AGENT_CAPACITY` bounds concurrent tasks for that repo service.
Branch prefix and hook skipping are handled by the surrounding Fieldwork
infrastructure, not the adapter.

Another Fieldwork-launched adapter for a different agent should look similarly thin. If your
adapter grows past ~50 lines, the complexity probably belongs in the agent
binary, not the adapter shim.

## What's deferred

- **Multiple Fieldwork-launched adapters in one session.** One adapter per
  Fieldwork agent user for now. If you need to run two managed services on the
  same host, give each its own agent user with its own agent config layout and
  adapter setting.
- **Headless adapter.** Implemented as the `one_shot_job` process model (Aider);
  see the Aider section above.
- **Forge adapters beyond GitHub.** The broker speaks `gh` today; a GitLab or
  Gitea broker would be a fork of `lib/broker/server.py` with the same trust
  model, not an agent adapter.
