---
name: agentic-engineer
description: Orchestrator SOP for the agentic-engineer single-feature pipeline. Drives P0 worktree -> P1 plan -> P2 execute -> P3 verify -> P4 review -> P5 lifecycle, in interactive or auto mode, by dispatching the worktree/planner/executor/qa/reviewer subagents and driving state via agentic-state + agentic-checkpoint.
---

# agentic-engineer orchestrator SOP

## Overview

This SKILL is the **deterministic orchestrator** for one feature, front to back. It is not a
subagent itself: it is the SOP the top-level `/engineer` command follows. It dispatches the five
scoped subagents (`worktree`, `planner`, `executor`, `qa`, `reviewer` — defined in
`../../agents/*.md`, feature `subagents-scoped`) through six phases, with model/effort **pinned at
each dispatch** (D-6, works around Claude Code bug #44385: `model:` frontmatter is ignored). State
lives in `.agentic/state.json` inside the worktree, read/written only through the `agentic-state`
CLI; phase/task checkpoints go through `agentic-checkpoint`. The `verify-gate.sh` Stop/SubagentStop
hook (plan 04) is the actual enforcer of "no stop before green" (I-3) — this SOP cooperates with
that gate by setting the checks and phase it expects, but the gate is what makes non-compliance
impossible, not this document.

**Announce at start:** "I'm using the agentic-engineer orchestrator SOP to implement this feature."

## Model / effort pin table (D-6)

| Phase | Subagent | Model / effort | Superpowers skill(s) |
| --- | --- | --- | --- |
| P0 | `worktree` | haiku / low | `using-git-worktrees` |
| P1 | `planner` | opus / high | `brainstorming` (interactive only) + `writing-plans` |
| P2 | `executor` | sonnet / medium | `executing-plans` (or `subagent-driven-development` when the plan is subagent-shaped) |
| P2 (per task) & P3 | `qa` | sonnet / medium | `test-driven-development` + `verification-before-completion` |
| P4 | `reviewer` | opus / high | `requesting-code-review` (2-stage) |

Pin the model and effort explicitly in the `Task` tool dispatch for every phase above — never rely
on subagent frontmatter alone (bug #44385).

## Mode + input resolution (T-E1)

Resolve mode and input **before P0**:

- Default mode is **`interactive`** unless the invocation passes `--mode auto`.
- **`auto`** requires `--change <id>`; `openspec/changes/<id>/` becomes the source of truth for
  the rest of the run, and the run **never pauses** for a human.
- **`interactive`** takes a free-form feature request and pauses once, at P1->P2, for human plan
  approval.

Record both immediately: `agentic-state init <feature-slug> --mode {interactive|auto} [--change
<id>]`. Every later phase reads `mode` and `change_id` back from state rather than re-deriving them,
so a resumed/reopened run behaves identically.

**needs_human precondition (T-E9, feature `needs-human-escalate`):** before dispatching *any*
phase, run `agentic-state get needs_human`. If it is `true`, **stop immediately** and surface
`agentic-state get blocking_reason` to the human/PM — **do not retry, do not dispatch**. The full
check-early / stop-don't-retry / write-outcome-with-needs_human contract this precondition refers
to is spelled out in its own section below (feature `needs-human-escalate`).

## Worktree-first ordering (T-E10)

**worktree-first: P0 (worktree) runs before P1 (plan).** This is a documented divergence from the superpowers
default (which plans first, then isolates); we invert it so that **all work — including the plan
artifacts themselves — happens inside the isolated worktree from the first byte** (I-6). Once P0
returns `WORKTREE_PATH`, every subsequent phase, subagent dispatch, and file write happens with
that path as the working directory.

## needs_human escalation — check-early, stop-don't-retry (T-E9, feature `needs-human-escalate`)

The per-phase runaway guard that **sets** `needs_human` lives in `verify-gate.sh` (plan 04,
feature `gate-runaway`, T-C7): once the *current* phase's gate has failed too many times in a row,
the hook sets `needs_human=true` + a human-readable `blocking_reason` in state, and then **ALLOWS
the stop** — the agent's turn ends cleanly instead of hanging in an infinite retry loop. This SOP
owns what happens on the **next re-entry**, after that gate-allowed stop:

1. **Check first, at the top of every phase.** Before dispatching *any* subagent for *any*
   phase — P0 through P5, on first entry and on every re-entry (including a `reopen P2` bounce back
   from P3/P4, T-C5) — run `agentic-state get needs_human` before doing anything else in that
   phase.
2. **If `true`: stop immediately, do not retry.** Do not dispatch the subagent for this phase, do
   not advance to the next phase, and never loop back into the same phase again either — the run
   is over until a human clears `needs_human`. Read the detail with
   `agentic-state get blocking_reason`.
3. **Surface `blocking_reason`, mode-appropriately:**
   - **interactive:** print `blocking_reason` to the human directly and stop the session — this is
     the human/PM-facing escalation path.
   - **auto:** there is no human attached, so the escalation must reach the PM through the same
     channel a normal completion would — call
     `lib/write-outcome.sh "$WORKTREE_PATH" <change_id> needs_human <checkpoints> <tests_written>
     "$(agentic-state get blocking_reason)"` (feature `auto-outcome`'s script; this records
     **`status: needs_human`**, which forces `verification.large_passed:false` — never a
     self-contradictory "success" record), then clean up the worktree/`.agentic/` exactly as a
     normal P5 auto exit would (I-4). The PM then sees a well-formed `needs_human` outcome record,
     not a hang or a crash, and must not retry this change automatically.
4. This check runs *before* the phase's own steps below on every entry; it does not replace them —
   a normal (non-escalated) re-entry proceeds straight into that phase's numbered steps.

Acceptance: forcing the runaway guard (plan 04) produces a clean escalation on the next re-entry —
the SOP stops without retrying, surfaces `blocking_reason`, and (auto) leaves a `status:
needs_human` outcome record behind — never an infinite retry loop (T-E9).

## P0 — worktree (T-E2)

1. Dispatch the `worktree` subagent (haiku / low, skill `using-git-worktrees`) with the feature
   slug (or `--change <id>` in auto). It creates an isolated worktree on a new branch with a clean
   baseline and returns `WORKTREE_PATH`.
2. From **inside** the returned worktree:
   - `agentic-state init <feature> --mode <mode> [--change <id>]`
   - `agentic-state set worktree_path "\"$WORKTREE_PATH\""`
   - `agentic-state phase P0`
   - `agentic-checkpoint checkpoint P0 baseline --green`

Acceptance: a worktree on a new branch exists with a clean baseline and state initialized inside
it, before any planning happens.

## P1 — plan (T-E3, the key mode-split decision)

Dispatch the `planner` subagent (opus / high).

- **interactive:** `brainstorming` (Socratic back-and-forth with the human) -> `writing-plans` ->
  **STOP and wait for explicit human approval** before moving to P2. Do not proceed to P2 without
  it; record the approval (e.g. an approval flag) so the gate can check it.
- **auto:** skip `brainstorming` entirely. Read
  `openspec/changes/<id>/{proposal,design,specs,tasks}.md`; for anything the change doesn't
  specify, write `assumptions.md` documenting the gap and the assumption made; then run
  `writing-plans`. Proceed straight to P2 — **no checkpoint pause, no human approval**.
- **Both modes:** auto-detect the project's fast/component/large verify commands (feature
  `detect-verify`, `lib/detect-verify.sh <project-dir>` — this SOP calls that script and records
  its output into `verify_cmds`, it does not reimplement the heuristic here) and register every
  plan task with `agentic-state task-add <id> <title>`.

Acceptance: interactive halts for approval with a plan present; auto proceeds straight to P2 having
read the change, written `assumptions.md` for any gaps, and recorded verify cmds + tasks.

## P2 — execute (T-E4, executor -> qa per task)

1. `agentic-state phase P2`.
2. Dispatch the `executor` subagent (sonnet / medium, skill `executing-plans`) to implement **one
   task at a time** — feature code only, never test files.
3. After each task, dispatch `qa` (sonnet / medium, skills `test-driven-development` +
   `verification-before-completion`) to:
   a. write/update the **component test** for that task, and
   b. run **FAST verify** = lint + typecheck + component test (component step only when the
      project configures one; `component: null` from `detect-verify` falls back to lint+typecheck).
4. On pass: `agentic-state task-set <id> verified` then `agentic-checkpoint checkpoint P2 <id>
   --green`.
5. On fail: `agentic-state check-set fast fail`, then **route the fix** — a failing *test* is
   `qa`'s to fix, a failing *implementation* goes back to `executor` (bounded retries) — then
   re-verify until `agentic-state check-set fast pass`.

The gate (`verify-gate.sh`) blocks stopping while tasks remain or `fast` is red — this SOP does not
need to re-implement that check, only to keep driving tasks/checks honestly.

Acceptance: a 3-task plan yields 3 tasks each with a passing component test written, 3 green
checkpoints, and zero remaining tasks before P3 is allowed.

## P3 — verify large (T-E5, QA-owned)

1. `agentic-state phase P3`.
2. Dispatch `qa` to ensure the broader tests exist (integration/e2e, whichever the project
   configures) and run **LARGE verify** = the full suite (lint + typecheck + component +
   integration + e2e — the same component tests `qa` wrote in P2 are included).
3. Pass: `agentic-state check-set large pass` + `agentic-checkpoint checkpoint P3 large --green`.
4. Fail: `agentic-state check-set large fail`, then `agentic-state reopen P2` (nulls the
   downstream `large`/`review` checks so a later stop can't pass on a stale green, T-C5) and return
   to P2. If the tree is broken beyond repair, `agentic-checkpoint revert-last-green` (I-5).

Acceptance: an injected failure forces P2 re-entry and cannot be skipped; the large suite includes
the component tests `qa` wrote in P2.

## P4 — review (T-E6)

1. `agentic-state phase P4`.
2. Dispatch the `reviewer` subagent (opus / high, skill `requesting-code-review`, 2-stage,
   **read-only — no Edit/Write**) to review the diff against the specs/plan.
3. Approve: `agentic-state check-set review pass`.
4. Changes requested: `agentic-state check-set review changes_requested`, then
   `agentic-state reopen P2` and return to P2. The run cannot terminate on a stale review — a
   *fresh* review must pass after every re-entry.

Acceptance: a spec-violating diff yields `changes_requested` and the run cannot terminate until a
fresh review passes.

## P5 — lifecycle + cleanup (T-E8)

1. `agentic-state phase P5`.
2. **interactive:** summarize the work done and **stop for the human to merge**.
3. **auto:** open a PR / merge on green per policy, then **write the outcome record** — the call
   site is `lib/write-outcome.sh <target> <change_id> <status> <checkpoints> <tests_written>`
   (feature `auto-outcome` owns the script and its `pm-outcome/1` schema; this SOP only wires the
   call, before cleanup). After the outcome file is written, remove the worktree and `.agentic/`
   (I-4 — engineer state is ephemeral) and hand control back to the PM.

Note: this normal-completion P5 only runs when `needs_human` is `false`. If any earlier phase's
`needs_human` check (see "needs_human escalation" above) fired, the run already stopped there —
`status: needs_human` was written by that path, not this one, and P5 never dispatches.

Acceptance: after auto success, no engineer state remains outside the archived change, and the
outcome file exists before the worktree is removed.

## Subagents referenced (defined in feature `subagents-scoped`)

This SOP dispatches — by name and role only; the agent-definition files themselves
(`../../agents/{worktree,planner,executor,qa,reviewer}.md`) are authored by feature
`subagents-scoped`, not here:

- **worktree** — haiku/low, `using-git-worktrees`, creates the isolated worktree (P0).
- **planner** — opus/high, `brainstorming` + `writing-plans`, produces the plan + registers tasks (P1).
- **executor** — sonnet/medium, `executing-plans`, implements feature code one task at a time (P2).
- **qa** — sonnet/medium, `test-driven-development` + `verification-before-completion`, writes test
  files only and runs FAST (P2 per task) and LARGE (P3) verification.
- **reviewer** — opus/high, `requesting-code-review`, read-only 2-stage review (P4).

## Forward references (not implemented by this SOP)

- **`detect-verify`** — the Node-first verify auto-detect script (`lib/detect-verify.sh`) called
  in P1; this SOP calls it, it does not implement the detection heuristic (T-E7).
- **`auto-outcome`** — the `openspec/.pm/outcomes/<id>.json` writer (`lib/write-outcome.sh`) called
  at P5 auto, before cleanup; this SOP only wires the call site (T-E8).
- **`needs-human-escalate`** — the full `needs_human`/`blocking_reason` escalation contract; this
  SOP only states the pre-dispatch check (T-E9) above and defers the detail to that feature.

## Constraints restated (I-6, I-10)

Every subagent writes only inside the active worktree; the single exception is durable OpenSpec
artifacts under `openspec/` in `auto` mode. The target project's own `CLAUDE.md` / rules win over
this plugin's defaults (I-10) — the orchestrator never overrides them.
