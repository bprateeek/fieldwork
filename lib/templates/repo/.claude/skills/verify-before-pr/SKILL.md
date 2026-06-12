---
name: verify-before-pr
description: Run all deterministic local checks (lint, typecheck, tests, gitleaks, semgrep) before opening a PR. Refuses to proceed if any check fails. Required by pr-delivery.
---

# /verify-before-pr

Runs the local gates that mirror PR-time CI checks so the PR opens green instead of failing minutes after submission.

## What this skill does

Execute the verify wrapper against the current project directory:

```bash
/home/fieldwork/.local/bin/fieldwork-verify "$CLAUDE_PROJECT_DIR"
```

The wrapper is excluded from the agent sandbox (see `~/.claude/settings.json` → `sandbox.excludedCommands`) and runs the fixed pipeline of lint → typecheck → tests → gitleaks → semgrep, with each inner step confined inside its own network-off sandbox (bwrap or `systemd-run --user`).

Invoke the command exactly as shown: absolute path, single directory argument, nothing before it. The sandbox exclusion is a literal prefix match on the command string; any prefix (`cd ... &&`, `env ...`, quoting the binary path, `;` chains) re-enables the per-call sandbox and the call fails with a bwrap error.

In Fieldwork remote sessions every other plain Bash command is expected to fail with `bwrap: No permissions to create new namespace`. That is by design and is not a reason to skip this skill, declare Bash broken, or abandon the PR flow.

## On non-zero exit

Report the wrapper's stderr **verbatim** and stop. Do **not**:

- retry,
- auto-fix (no `--fix`, no `gofmt -w`, no `cargo fmt`),
- fall back to direct `npm` / `go` / `cargo` / `pytest` invocations,
- stage, commit, push, or open a PR.

The user reads the failure and decides what to fix; the next session continues from there.

## Exit codes

| Code | Stage |
|---|---|
| 0 | ok. Proceed to `pr-delivery` |
| 10 | lint |
| 11 | typecheck |
| 12 | tests |
| 13 | gitleaks (`protect --staged`) |
| 14 | semgrep (`p/owasp-top-ten` on changed files) |
| 20 | abuse / inner-sandbox unavailable |
| 30 | deps missing. Run onboarding maintenance |

`deps-missing` (exit 30) means `node_modules` (or stack equivalent) is absent. The wrapper does **not** install deps inside an agent session; that happens during onboarding or a separate maintenance command.

## On success

Skill returns clean. The `pr-delivery` skill stages the intended paths, commits, writes the broker request file, and invokes `fieldwork-pr-submit`.
