# Development

This page is for contributors working on Fieldwork itself.

## Repo Layout

```text
bin/fieldwork              Main CLI dispatcher and shared helpers.
lib/cli/                   CLI command modules sourced by bin/fieldwork.
lib/scripts/               Installed user scripts: onboarding, agent session, verify, prepare, submit, bot.
lib/broker/                PR broker daemon, systemd socket units, PAT rotation, standalone install.
lib/systemd/               VPS bootstrap and user service templates.
lib/templates/repo/        Files copied into onboarded repositories, including Claude skills.
lib/claude/                Global Claude settings installed into ~/.claude.
schema/                    Runtime request contracts.
examples/                  Broker client examples.
tests/                     Static checks and focused validation tests.
docs/                      Public docs.
```

## Important Runtime Boundaries

- `fieldwork` is the agent user. It owns repo checkouts and calls tokenless clients.
- `fieldwork-pr-broker` is the broker user. It owns the forge credential and opens PRs/MRs.
- `fieldwork-bot` is the Telegram bot user. It owns the Telegram token and approval HMAC secret.
- The verify and pr-prepare runners run as systemd user socket-activated services for the agent user.
- The broker submit socket is installed with the agent user's primary group so it remains reachable inside Claude's sandbox user namespace.
- The approve socket is installed with the bot group so the agent cannot approve its own PR request.

## Local Checks

Run the static suite before opening a PR:

```sh
tests/static-checks.sh
```

Focused tests:

```sh
python3 tests/broker-validation-tests.py
python3 tests/pr-prepare-validation-tests.py
python3 tests/bot-tests.py
```

The static suite checks shell syntax, Python syntax, broker schema validity, runner unit invariants, broker socket-group defaults, CLI help, and docs expected by tests.

## Documentation Checks

When changing docs:

- Keep [../README.md](../README.md) short. It is the landing page, not the manual.
- Move long setup, debugging, or architecture detail into `docs/`.
- Do not claim behavior that is not implemented.
- Mark planned behavior clearly as planned.
- Keep command names aligned with `fieldwork --help`.
- Verify every linked doc exists.

Useful grep passes:

```sh
rg -n 'stale PR-flow phrase|TODO|draft marker' README.md docs
rg -n 'fieldwork (setup|onboard|start|status|report|setup-notify|sync-vps|verify-security|doctor|bot-status|smoke)' README.md docs
```

## README Demo GIF

The README hero is generated from [demo source](demo/hero.yml) with demoframe:

```sh
npm install
npm run demo:check
npm run demo:render
```

`npm run demo:render` writes render QA files under `docs/demo/dist/`, copies the primary GIF to `docs/assets/hero.gif`, then uses ImageMagick's `magick` CLI to mask the area outside the phone frame transparent.

## CLI Surface

The user-facing command surface is:

```text
fieldwork setup
fieldwork doctor [--remote] [--explain]
fieldwork setup-notify [--remote] [--topic <ntfy-topic>] [--yes]
fieldwork setup-notify --telegram-bot [--yes]
fieldwork sync-vps [--dry-run] [--yes] [--force-install]
fieldwork verify-security [repo-slug]
fieldwork report [repo-slug]
fieldwork smoke <owner/repo> [--yes]   # GitHub only
fieldwork bootstrap-vps [--print-path] [--verbose] [--log-file <path>]
fieldwork install-broker [--print-path] [--verbose] [--log-file <path>]
fieldwork onboard <project> [--slug <slug>] [--branch fieldwork/init] [--no-workflows] [--with-approval-gate] [--status] [--reset-state] [--reseed-templates]
fieldwork start <repo-slug>
fieldwork status [repo-slug] [--verbose]
fieldwork bot-status
```

Update [cli-reference.md](cli-reference.md) when this changes.

## Template Changes

Repo templates live under `lib/templates/repo/`. Onboarded repos receive copies, not live links. If a template skill or hook changes, existing repos may need:

```sh
fieldwork onboard <project> --reseed-templates
```

Document migration-sensitive template changes in [troubleshooting.md](troubleshooting.md) or the release notes for the PR.

## Broker Changes

Broker behavior is runtime security behavior. When editing `lib/broker/server.py`, also check:

- [broker-contract.md](broker-contract.md)
- [threat-model.md](threat-model.md)
- [approval-gate.md](approval-gate.md), if queueing or approval behavior changes
- `schema/pr-request.schema.json`
- `tests/broker-validation-tests.py`

Never add a broker path that lets the agent push without validation.

## Runner Changes

Runner behavior is documented in [runner-architecture.md](runner-architecture.md). When editing verify or prepare scripts, check:

- `lib/scripts/fieldwork-verify`
- `lib/scripts/fieldwork-verify-runner`
- `lib/scripts/fieldwork-verify-pipeline`
- `lib/scripts/fieldwork-pr-prepare`
- `lib/scripts/fieldwork-pr-prepare-runner`
- `lib/scripts/fieldwork-pr-prepare-impl`
- `schema/pr-prepare-request.schema.json`
- `tests/pr-prepare-validation-tests.py`

The prepare runner must keep `core.hooksPath=/dev/null`. The runners must not read broker, bot, deploy-key, or notification secrets.

## Git Hygiene

Docs-only changes should stay docs-only. Runtime code changes require focused tests and a security-boundary check.

Before final review:

```sh
git diff --stat
tests/static-checks.sh
```
