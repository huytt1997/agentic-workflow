---
name: agentic-pm
description: Operate pm-runner.sh — the deterministic PM outer loop that builds a backlog of OpenSpec changes via ephemeral engineer runs, gated on the outcome contract.
---

# agentic-pm

`pm-runner.sh` is the engine; this skill explains how to run it safely.

## Prerequisites

1. The target project has run `openspec init` (creates `openspec/`, `specs/`).
2. `agentic-ba` has produced changes with acceptance criteria + `depends_on`/`priority` frontmatter.
3. The engineer emits the outcome contract in P5 auto mode (already wired via
   `agentic-engineer/lib/write-outcome.sh`).
4. `jq`, `git`, `claude`, and `openspec` are on PATH. Set `AGENTIC_PROJECT_ROOT` to the target dir.

## Always dry-run first

```
AGENTIC_PROJECT_ROOT=/path/to/target PM_DRY_RUN=1 pm-runner.sh
```

This prints the selection + the engineer command it *would* run, launches nothing, spends nothing.
When the selection order looks right, drop `PM_DRY_RUN` (or set it to `0`) to run for real.

## Config surface (knobs)

Key env vars (full table in 00-overview.md): `PM_ENGINEER_CMD`, `PM_ALLOWED_TOOLS`, `PM_PERMISSION_MODE`
(`acceptEdits`, never `bypassPermissions`), `PM_MAX_RETRIES`/`PM_BACKOFF_SEC`, `PM_ON_FAIL`/`PM_ON_BLOCK`,
`PM_COST_CAP_USD`/`PM_TIME_CAP_MIN`, `PM_COMPACT_EVERY`, `PM_BA_SYNC`/`PM_DOCS_GLOB`, `PM_DRY_RUN`.

## Reading the summary

The loop ends with `pm-runner summary: done=N blocked=M failed=K spent_usd=…`.
- `done` — archived successfully.
- `blocked` — `needs_human` or a success/contract violation; NOT archived. With `PM_ON_BLOCK=stop` the
  loop halts and surfaces the reason.
- `failed` — exhausted retries.

## Where state lives

All under the target's `openspec/.pm/`: `progress.json` (cursor + buckets + meta), `outcomes/<id>.json`
(engineer→PM contracts), `logs/<id>.<ts>.ndjson` (per-run logs). Nothing persists in a long-lived
session — that is the point (I-1/D-14).

## Deferred

Live end-to-end against a real `claude -p` engineer is deferred (00-overview.md D-B); the mechanism is
fixture-verified with a stub engineer.
