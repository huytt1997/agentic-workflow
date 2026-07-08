# Roadmap & current state (work objectives)

_Applicability: read to know **what to build next** and where the project actually stands._
_Authoritative source: [specs/execution-plan.md](../../specs/execution-plan.md) (task-level build plan) and [specs/plan.md](../../specs/plan.md) §9._

## ⚠️ Honest current state

**This repository currently contains only the two planning docs** (`specs/plan.md`,
`specs/execution-plan.md`), plus `README.md`, `.claude/`, and `.envrc`. The `packages/`, `bin/`, and
`.claude-plugin/` scaffold described in the specs' layout **does not exist on disk yet.** The specs
describe the _target_ system; building the scaffold and wiring it is the work.

execution-plan.md §0 calls the kernel hooks/libs "written" and the engineer "scaffolded" — treat that as
the _intended_ M0 baseline, not the repo's reality. When the specs and the tree disagree, one of them is a
bug; reconcile deliberately (the specs' own rule), don't paper over it.

## Milestones

| Milestone | Contains                                    | Done when                                                                             |
| --------- | ------------------------------------------- | ------------------------------------------------------------------------------------- |
| **M0**    | Scaffold (all files exist)                  | _Per specs, "done"; not yet present in this repo._                                     |
| **M1a**   | WS-A kernel hardening + tests               | `state.sh` / `safety-guard` / `verify-gate` / `checkpoint` pass fixture/unit tests    |
| **M1b**   | WS-B engineer end-to-end (incl. new `qa`)   | Passes WS-B acceptance on a real repo, both modes; `qa` writes tests, FAST+LARGE run  |
| **M1c**   | WS-E install / profiles                     | Clean install + symlink dev loop works                                                |
| **M2a**   | WS-C `agentic-ba`                           | Real docs → valid, idempotent OpenSpec changes with testable acceptance criteria      |
| **M2b**   | WS-D `agentic-pm` loop                      | Multi-change backlog to completion, flat context, outcome-gated                       |
| **M3**    | Observability                               | SSE + SQLite event bus + Vite/React dashboard                                         |

## Workstreams & dependency order

`WS-A` core hardening → `WS-B` engineer end-to-end → `WS-C` agentic-ba → `WS-D` agentic-pm loop.
`WS-E` install/packaging and `WS-F` observability + test harness are parallelizable.
**Hard gate: do not start WS-D (PM) until WS-B (engineer) passes acceptance on a real repo** — a PM that
dispatches an unproven engineer just multiplies failures.

## Correctness-critical build risks

- `verify-gate` re-entry / stale-green bug: a P4→P2 cycle must null downstream checks, and each check must
  carry the SHA it was computed at (per-check staleness). Highest-priority kernel task (T-C5 / T-C6).
- Success-signal gap: PM must gate on the engineer→PM **outcome contract**
  (`openspec/.pm/outcomes/<id>.json`), not the process exit code (T-E8 / T-M7).
- `safety-guard` false positives stalling runs → build the fixture suite (T-C9).

## Suggested first sprint (smallest path to a provably working engineer)

1. Kernel under test: **T-C3 + T-C9 + T-C12** (state, safety fixtures, checkpoint).
2. Fix verify-gate re-entry / staleness: **T-C5 + T-C6**.
3. Wire the engineer orchestrator end-to-end incl. the new `qa` subagent: **T-E1…T-E8 + T-E12**.
4. **WS-B acceptance** on a small real repo (auto mode first — it is the PM path).
5. Then the PM loop: **T-E8 outcome contract + T-M5…T-M7** over a 3-change backlog.

## Open decisions to confirm while building

Worktree-first ordering (P0 before P1) · verify auto-detect heuristics beyond Node · `depends_on`
mechanism (front-matter vs. manifest) · PM policies (retry/backoff, `needs_human` park-vs-stop, compaction
`K`, budget caps) · exact superpowers skill IDs · QA dispatch granularity (per-task vs. batched) + `qa`
model/effort. Full list: execution-plan.md §10.
