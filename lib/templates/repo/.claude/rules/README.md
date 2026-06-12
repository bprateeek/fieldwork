# `.claude/rules/`

Drop short markdown files here that should be loaded as additional context for every Claude session in this repo. Examples:

- `auth.md`: "All auth flows go through `lib/auth.ts`. Never roll your own JWT validation."
- `migrations.md`: "Migrations must be reversible. Never drop a column without a deprecation migration first."
- `mobile-only.md`: "This package is mobile-only; React DOM imports are forbidden."

## Conventions

- One concern per file. Smaller is better.
- Lead with the rule, follow with one or two sentences of context.
- Don't restate things already in `CLAUDE.md`. That's already loaded.
- Don't put project status here (use `MEMORY.md` / project memories for that).

## Loading

Files in this directory are loaded by Claude Code's project-level context mechanism. Verify in your version with `claude --debug` if needed.
