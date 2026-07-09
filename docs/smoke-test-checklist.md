# Manual live smoke-test checklist — WS-B acceptance (§4.3)

> **Who runs this and when:** a human, once, on a small real target repo, after plan 07's automated
> phase-walk (`tests/integration/run-integration.sh`) is green. This is **not** a `verify_cmd` or
> `verify_cmd_e2e` — it is never scripted, never dispatched by an agent, and never gates a commit.
> `tests/integration/checklist_test.sh` only checks that *this document* exists and mentions the
> right things; it does not run any of the steps below.

## Why this checklist exists (read before running)

specs/execution-plan.md §4.3 lists six WS-B acceptance items. Plan `07-phase-walk-acceptance`'s
deterministic simulated harness (`tests/integration/{phase_walk,phase_walk_reentry,
phase_walk_safety,phase_walk_rollback,phase_walk_events}.sh`, all wired into
`tests/integration/run-integration.sh`) already proves, with **no LLM and no network**, the parts
that are pure kernel-script state-machine behaviour:

| §4.3 item | Already proven by the phase-walk harness (no live run needed) |
| --- | --- |
| 3 — hooks fire | `phase_walk_safety.sh` feeds `safety-guard.sh` a destructive command and asserts a fail-closed deny exit; `phase_walk.sh`/`phase_walk_reentry.sh` assert `verify-gate.sh` blocks every red stop condition, incl. P4->P2 re-entry nulling stale checks |
| 4 — rollback | `phase_walk_rollback.sh` breaks the tree then asserts `checkpoint.sh revert-last-green` restores the last `--green` checkpoint and the tree is clean |
| 5 (partial) — events | `phase_walk_events.sh` asserts `emit-event.sh` produces valid NDJSON |

**What only a live run can prove** — real subagent dispatch (the `Task` tool actually invoking
`worktree`/`planner`/`executor`/`qa`/`reviewer`), real model behaviour (does the planner actually
brainstorm, does the reviewer actually request changes, does `qa` actually write a useful test),
and an actual `claude -p` / interactive Claude Code process running the orchestrator SOP end to
end. That is what this checklist exercises. Do not consider WS-B "done" from the phase-walk harness
alone — both must pass.

## Out of scope for this build pass

`bin/install.sh` / packaging (WS-E, T-I*) is **not built yet** in this build pass, so there is no
`/plugin install` flow to use. Exercise the plugin via the dev-loop invocation instead
(`.claude/rules/dev-workflow.md`):

```bash
claude --plugin-dir packages/agentic-core --plugin-dir packages/agentic-engineer
```

This loads both plugins (the engineer depends on the core's hooks/libs) for the current session
without installing anything. After editing any agent/hook/skill file on disk mid-session, run
`/reload-plugins` before continuing.

## Prerequisites

- [ ] A small **real** target repo (not this monorepo) with a trivial Node project (or whatever
  stack — `detect-verify.sh` is Node-first; a non-Node repo will fall back to `null`/skip, which is
  fine for a first smoke run but a Node fixture like `tests/fixtures/npm-sample` exercises FAST +
  LARGE most fully).
- [ ] `openspec init` has been run in that target repo (durable BA/PM state, `I-11`) — needed for
  item 2 (auto mode) below; not required for item 1 (interactive, free-form feature request).
- [ ] Launched via the dev-loop command above, from inside the target repo (or with `--add-dir`
  pointing at it), so `${CLAUDE_PLUGIN_ROOT}` resolves to this monorepo's `packages/*` while the
  working directory is the target repo.

## 1. Interactive mode: one small real feature, end to end

- [ ] Run `/engineer` (mode defaults to `interactive`) with a free-form small feature request.
- [ ] **P0 worktree:** confirm a new git worktree + branch exists with a clean baseline before any
  planning happens (`agentic-state get worktree_path`, `phase` == `P0`).
- [ ] **P1 plan:** confirm the `brainstorming` Socratic back-and-forth actually happens (a real
  model asking real questions, not a canned plan), then `writing-plans` produces a plan file, then
  the session **stops and waits** for your explicit approval before P2 — approve it.
- [ ] **P2 execute:** confirm the `executor` subagent implements one task at a time (feature code
  only), and `qa` writes a component test per task and runs FAST (lint + typecheck + component)
  after each — eyeball that the test file actually appeared and is not a stub that always passes.
- [ ] **P3 verify:** confirm `qa` runs LARGE (full suite, including the component tests it wrote in
  P2) before the gate allows P4.
- [ ] **P4 review:** confirm the `reviewer` subagent is read-only (no Edit/Write tool calls) and
  actually reads the diff against the plan/spec before approving.
- [ ] **P5 lifecycle:** the session summarizes the work and **stops for you to merge** — merge it
  yourself; confirm the feature branch/PR contains both the feature code and the tests `qa` wrote
  (durable code artifact, per 00-overview.md's memory layering).

## 2. Auto mode: one hand-written OpenSpec change to green, no human input

- [ ] Hand-write a small `openspec/changes/<id>/{proposal,design,specs,tasks}.md` in the target
  repo (no `openspec` CLI generation needed this pass — `openspec archive`/`validate` are M2/WS-D,
  out of scope).
- [ ] Run `/engineer --mode auto --change <id>`.
- [ ] Confirm the run **never pauses** for input: no brainstorming, no P1->P2 approval stop, no P5
  merge prompt — it runs P0 through P5 unattended.
- [ ] Confirm it reads the change's `proposal`/`design`/`specs`/`tasks` docs and, for anything the
  change doesn't specify, writes `assumptions.md` documenting the gap.
- [ ] Confirm it reaches P5 and completes without human input.

## 3. Prove each hook fires (the live parts the simulated harness cannot reach)

The phase-walk harness already proves the state-machine *logic* of each hook (see table above)
using the shipped scripts directly, with no LLM. Use this live run only to confirm the hooks are
correctly **registered and firing** inside a real subagent session (real `PreToolUse`/`Stop`
events, not a script feeding JSON on stdin):

- [ ] **Safety, even under skip-permissions:** during `--mode auto` (which runs under a
  headless/skip-permissions-style allow-list per `D-10`), have the executor/qa subagent attempt (or
  simulate attempting) a destructive command (e.g. `rm -rf` on a scratch path) and confirm
  `safety-guard.sh` denies it — the deny cannot be loosened by any permission "allow" (`I-2`).
- [ ] **Gate refuses every red stop condition:** try to let the session stop early (e.g. interrupt
  after P2 with tasks still open, or before FAST/LARGE are green) and confirm `verify-gate.sh`
  blocks the stop (`I-3`) rather than silently ending the turn.
- [ ] **Events land in NDJSON:** after the run, check `$AGENTIC_HOME/events.ndjson` (or the
  configured events path) has real entries from the live session's tool calls, and each line is
  valid JSON (`jq -e . <line>`).
- [ ] **Per-subagent `SubagentStop` isolation (flagged in code review, live-only — the phase-walk
  harness only invokes the gate at orchestrator checkpoint boundaries, never at a real per-subagent
  `SubagentStop`):** during P2, confirm the `executor` subagent's own `SubagentStop` does not get
  wrongly blocked on `checks.fast` before `qa` has had a chance to run and set it — i.e. the gate's
  P2 check should not force `executor` into a retry loop for a check it doesn't own. If it does
  block incorrectly, that's a real bug in the SOP's phase-vs-subagent gating and should be filed as
  a follow-up before `agentic-management` (WS-D) is unblocked.

## 4. Prove rollback in a live run

- [ ] During (or after) the auto or interactive run, deliberately break the tree (e.g. hand-edit a
  file to introduce a syntax error and commit it) inside the worktree.
- [ ] Run `agentic-checkpoint revert-last-green` (or trigger the same path the orchestrator would
  take on an unrecoverable P3 failure, per the SOP's P3 step 4).
- [ ] Confirm the tree is restored to the last `--green` checkpoint and `git status --porcelain` is
  clean afterward — same invariant `phase_walk_rollback.sh` proves mechanically, now proven with a
  live agent-driven worktree.

## 5. Prove cleanliness

- [ ] **Interactive:** after you merge at P5, confirm the worktree used for the feature is removed
  and `.agentic/` does not persist anywhere outside it (`I-4`) — nothing engineer-scoped survives
  the session.
- [ ] **Auto:** after the run completes, confirm:
  - `.agentic/` and the worktree are gone.
  - The outcome file was written **before** cleanup, at
    `openspec/.pm/outcomes/<change-id>.json` in the target repo (schema `pm-outcome/1`,
    written by `lib/write-outcome.sh` — see `packages/agentic-engineer/lib/write-outcome.sh`).
    Confirm `status` is `success` (or `needs_human`/`failed` if you deliberately forced an
    escalation), `verification.large_passed` matches `status`, and `verification.tests_written` is
    > 0 for a run where `qa` wrote tests.

## 6. Prove QA writes tests

- [ ] During P2, confirm `qa` wrote a real component test for each task (not a no-op) and that test
  runs as part of FAST (lint + typecheck + component) before the per-task checkpoint goes green.
- [ ] Confirm the same test(s) also run as part of LARGE at P3 (the full suite includes what `qa`
  wrote in P2 — LARGE never re-writes or skips them).
- [ ] **Negative check:** deliberately introduce a component-level bug (or ask `qa`/the executor to
  leave one task's implementation broken) and confirm the deliberately failing component test
  **blocks the per-task gate** — the run cannot proceed to the next task, let alone P3, until the
  fix lands and the test goes green.

## After the run

- [ ] Note any real bug surfaced (kernel or engineer-plugin) in the owning plan, not here — this
  checklist documents *how to prove* WS-B, it is not itself a bug tracker.
- [ ] If every item above passed on both modes, WS-B acceptance (§4.3) is satisfied and
  `agentic-management` (PM outer loop, WS-D) is unblocked per the roadmap's hard gate.
