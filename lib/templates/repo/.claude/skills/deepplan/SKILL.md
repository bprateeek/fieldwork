---
name: deepplan
description: Multi-round planning skill for non-trivial features. Asks structured clarifying questions, delegates an independent design pass to the planner subagent, then writes a plan and exits plan mode.
---

# /deepplan (per-repo)

For features touching auth, payments, schema, infrastructure, or more than ~3 files in this repo. Mirrors the global skill but committed so cloud + Action runs see it.

## Sequence

### Round 1: scope (4 questions)

1. Goal in one sentence.
2. Out of scope (2–3 bullets).
3. Hard constraints (deadlines, latency, compliance).
4. Acceptance criterion.

### Round 2: risk (3–4 questions)

1. Most likely failure mode + detection.
2. Rollback plan.
3. Security/auth implications.
4. Edge cases for tests.

### Round 3: only if Round 2 surfaces a real ambiguity

### Independent design pass

Delegate to the `planner` subagent with: goal, non-goals, constraints, Phase 1 findings, Round 2 risks. Ask for: approach, risks, rollback, 2 alternatives rejected.

### Write the plan

Lead with **Context** explaining why. Recommend one approach. Reference existing functions/utilities by file path. Include verification.

### Exit plan mode

Call `ExitPlanMode` after writing. Never use AskUserQuestion to ask for plan approval.
