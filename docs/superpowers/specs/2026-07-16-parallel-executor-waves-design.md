# Parallel executor waves (P2)

- **Date:** 2026-07-16
- **Status:** designed, **build deferred** until M1b (engineer live acceptance) passes
- **Affects:** `agentic-core` (state schema, P1 gate), `agentic-engineer` (P2 orchestration, executor + qa)
- **Closes open decision:** `depends_on` mechanism (front-matter vs. manifest) — see §11

## 1. Problem

P2 dispatches one `executor` for one task at a time. Tasks with no dependency on each other are
still executed strictly serially, so a plan of N independent tasks costs N sequential
executor→qa round-trips. The proposal: dispatch executors concurrently for independent tasks.

## 2. What serial execution is silently buying us

This is the central insight of the design and every constraint below follows from it.

**Serial execution gives integration-by-construction.** Task B is written on top of task A's already
merged, already green code. B's executor *sees* A's changes; B's component test exercises the
genuinely integrated tree. Nobody designed this property — it falls out of the ordering for free.

Parallelism destroys it. Every task in a wave is written against a base that excludes its siblings.
Two tasks can each be green in isolation and broken together. Most of the machinery in this spec
exists to buy back a property we currently get for nothing, which is also why the speedup is much
smaller than a naive "N tasks in parallel = N× faster" estimate (§9).

## 3. Locked decisions

| #   | Decision                                                                                   | Rationale                                                                                                                |
| --- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| 1   | **Isolation: one git worktree per parallel task**                                          | Keeps I-5 and I-7 honest: a wrong independence guess becomes a *detected merge conflict*, never a lost write. (D-12 is still amended, but by decision 3, not this one — see §8.) |
| 2   | **Planner declares `depends_on` + `files` per task**                                        | Two independent signals; file overlap is a cheap pre-dispatch check, `depends_on` catches behavioural coupling.          |
| 3   | **Merge-back: optimistic batch, bisect on red**                                            | Merges are inherently serial; verifying after every merge would eat most of the win. Bisect only on the rare red path.   |
| 4   | **Spec now, build after M1b**                                                              | The payoff depends entirely on planner prediction quality, which is unmeasurable until the engineer runs live (§10).     |
| 5   | **No file-ownership enforcement**                                                          | Worktree isolation already contains the damage. Measure how often predictions are wrong before building a hook for it.   |
| 6   | **Wave QA is mandatory after merge**                                                       | Post-merge FAST cannot detect logic coupling (§6.5). Without this step I-7 is violated in spirit.                        |
| 7   | **Never resolve a merge conflict**                                                         | LLMs are unreliable at conflict resolution. Abort and re-execute on a correct base (§6.6).                               |

## 4. Non-goals

- Parallelising P1, P3, or P4. Only P2 task execution is in scope.
- Cross-feature parallelism. That is the PM outer loop's concern, not the engineer's.
- A file-ownership enforcement hook (decision 5). Revisit only if measurement justifies it.
- Fixing the SubagentStop gate defect — that is a prerequisite with its own spec (§5).

## 5. Blocking prerequisites

Neither is caused by this design; both must land before any of it can be built.

### 5.1 `verify-gate.sh` cannot distinguish Stop from SubagentStop

`hooks.json` registers `verify-gate.sh` for both `Stop` and `SubagentStop` from a single entry, and
the hook deliberately never reads its stdin event (`verify-gate.sh:12-17` documents this as a
feature — not parsing stdin is what makes malformed payloads harmless). But `hook_event_name` lives
in that payload. Consequences today, in the **serial** pipeline:

- An executor finishing task 1 of 3 triggers SubagentStop → the P2 branch runs → `tasks-remaining`
  returns 3 (the orchestrator only marks a task `verified` *after* qa passes, which is after the
  executor has already returned) → the gate blocks the worker (`verify-gate.sh:156-160`). The
  executor is told to keep going when its job is done. It either does more work (violating
  one-task-at-a-time) or spins until `gate_attempts` exceeds 25 and escalates `needs_human`.

There is an unresolved fork that only a live run settles. Nothing in production ever sets
`AGENTIC_STATE` — it appears only in tests — so both `state.sh:16` and `verify-gate.sh:64` fall back
to `$(pwd)/.agentic/state.json`:

- If hooks run with cwd = the worktree → the over-blocking above.
- If hooks run with cwd = the original project dir → the state file is not found, the hook fails open
  at `verify-gate.sh:65`, and **I-3 is not enforced at all**.

Both branches are bad. Expected fix: read `hook_event_name` from stdin and scope the
task-completeness check to `Stop` only, leaving `SubagentStop` to gate only what a worker is
actually responsible for. This also removes the `gate_attempts` race that N concurrent workers would
otherwise create.

### 5.2 `.agentic/` is not excluded from git

Nothing in `worktree.md` establishes a `.gitignore` or `.git/info/exclude` entry, so `git add -A`
(`checkpoint.sh:30`) commits `.agentic/state.json` into the feature branch on every checkpoint. This
blocks §6.7 (task worktrees nested under `.agentic/tasks/`), which would otherwise be committed into
the feature branch.

## 6. Design

### 6.1 Schema change (`agentic-core`)

Task records gain two fields:

```json
{ "id": "t1", "title": "…", "status": "pending", "depends_on": [], "files": [] }
```

CLI: `agentic-state task-add <id> <title> [--depends-on a,b] [--files "src/foo.ts,src/bar/**"]`

Both default to empty, so every existing call site keeps working unchanged.

**Load-bearing default: a task with empty `files` is never parallelized.** An undeclared footprint is
an unpredictable one, so absent declaration fails safe to serial.

### 6.2 `agentic-state next-wave` (new, deterministic)

Wave selection is graph math and the orchestrator is an LLM, so this is jq-backed shell, unit-tested
by fixtures like the rest of the kernel:

1. `ready` = tasks where `status != "verified"` and every `depends_on` id is `verified`.
2. If `ready` is empty but unverified tasks remain → dependency cycle → exit non-zero; the
   orchestrator escalates `needs_human`.
3. From `ready`, greedily select a pairwise **file-disjoint** subset, capped at
   `AGENTIC_MAX_PARALLEL` (default 3). **Greedy in plan order** (the order `task-add` recorded them),
   so the same state always yields the same wave — determinism is the point of putting this in shell.
4. Any ready task with empty `files` is returned **alone**.
5. Emit a JSON array of task ids.

### 6.3 P1 gate addition

Validate the task DAG before P2 admits any work: every `depends_on` id resolves to a real task, and
the graph is acyclic. Malformed graph blocks P2. Same conditional shape as the existing `e2e_plan`
gate.

### 6.4 P2 wave loop

```
phase P2
loop:
  needs_human check                       # unchanged precondition
  wave = agentic-state next-wave
  if |wave| == 0 and tasks remain  -> needs_human (cycle)
  if |wave| == 1                   -> today's serial path, byte for byte
  if |wave| >  1                   -> parallel path (6.5)
```

**A wave of 1 is today's path unchanged**: executor → qa → `task-set verified` → green checkpoint.
This is deliberate. A serial-shaped plan carries *zero* new risk, and the parallel machinery only
engages when the planner actually found independence.

### 6.5 The parallel path

1. `base` = current feature-branch HEAD (the last green checkpoint).
2. For each task: `git worktree add .agentic/tasks/<id> -b <branch>/task-<id> <base>`.
3. Dispatch N `executor` subagents **in one message** (sonnet/medium each, pinned per D-6), one per
   task worktree.
4. As each executor returns, dispatch `qa` **inside that task worktree** (component test + FAST).
   These qa dispatches are themselves parallel — each is confined to its own worktree, so N tasks
   run N independent FAST suites concurrently. This is where the wall-clock win actually comes from,
   not from the executors alone.
5. **Per-task red is handled inside the task worktree**, exactly as the serial path handles it today:
   a failing test routes to `qa`, a failing implementation routes back to that task's `executor`,
   bounded retries. A task that cannot reach green does **not** merge — its branch is discarded and
   the task stays `pending` for a later wave (§6.6's requeue path). One red task never blocks its
   siblings from merging.
6. Merge each **green** task branch into the feature branch, one at a time (§6.6 on conflict).
7. **Wave QA (mandatory).** Dispatch `qa` (sonnet/medium) against the **combined wave diff** on the
   merged feature branch. Its job is not to re-run the union of per-task tests — those already passed
   in isolation and will pass again. Its job is to find **logic coupling**: two file-disjoint tasks
   that changed the same function's behaviour, or the same contract from opposite sides. Where it
   finds coupling, it writes an integration test covering the interaction. Then it runs FAST.
8. Green → `task-set verified` for every task in the wave + `agentic-checkpoint checkpoint P2
wave-<n> --green`, where `<n>` is a monotonic wave counter for this run.
9. Red → §6.6.
10. Tear down task worktrees.

Step 7 is why this design costs what it costs. Post-merge FAST alone (lint + typecheck + component
tests) **cannot** detect logic coupling: component tests are per-task and scoped to that task's
files, so every one of them still passes on a tree that is broken at the seams. Treating a
post-merge FAST green as proof would be a self-assertion in disguise — precisely what I-7 forbids.

### 6.6 Failure policy: never resolve, always redo on a correct base

Uniform across both failure modes. No LLM ever touches a conflict marker, and no partial fix is ever
hand-rolled (the same philosophy as I-5).

| Failure                     | Response                                                                                                                                  |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **Merge conflict**          | `git merge --abort`; discard that task branch; mark the task `pending`. It re-runs in a later wave on the correct base. Its work is lost — a bounded, predictable cost. |
| **Wave QA red**             | Bisect: reset to `base`, re-merge one task at a time with FAST after each, to find where it breaks. Requeue from the breaking task onward. |

This fails in the right direction: a plan full of bad `files` predictions degenerates toward serial
execution, which is the behaviour you would have wanted for that plan anyway.

### 6.7 Task worktree siting

Nested at `<feature-worktree>/.agentic/tasks/<id>/`. This keeps writes literally inside the feature
worktree (I-6 stays textually true, no amendment needed) and gets them deleted with `.agentic/` at P5
(I-4). **Contingent on prerequisite §5.2** — without the exclusion, `git add -A` commits the task
worktrees into the feature branch.

### 6.8 Single-writer state discipline

**Parallel subagents never call `agentic-state`.** They do work and report; the orchestrator writes.

The orchestrator is a single sequential agent, so every state write serializes by construction and
the unlocked read-modify-write at `state.sh:70-73` never sees a concurrent writer. No locking is
needed — not because concurrent writes would be safe, but because the race is designed out. If this
rule is ever relaxed, `state.sh` needs real locking first.

### 6.9 Bounded report contract

Each parallel subagent writes its detail to `.agentic/tasks/<id>/report.json` and returns **one
structured line**: status, files actually touched, nothing else. No logs, no diffs, ever. The
orchestrator reads detail from the file only when it needs it.

Total tokens are unchanged by fan-in — three reports cost the same arriving at once or one at a
time. The risk this addresses is **synthesis burst**: the orchestrator must integrate N reports in a
single turn instead of N turns, and that is where state synthesis goes wrong. This is I-1's
bounded-read discipline, which the PM outer loop already lives under, applied to the engineer's wave
fan-in.

## 7. Failure modes

| Mode                                     | Containment                                                                           |
| ---------------------------------------- | ------------------------------------------------------------------------------------- |
| Wrong `files` prediction                 | Merge conflict → abort + requeue (§6.6). Contained by worktree isolation.             |
| Logic coupling (file-disjoint)           | Wave QA (§6.5 step 7) → bisect + requeue.                                             |
| Dependency cycle in the plan             | P1 gate (§6.3); at runtime `next-wave` exits non-zero → `needs_human`.                |
| Executor crash mid-wave                  | Task branch discarded; task stays `pending`; a later wave picks it up.                |
| Concurrent state writes                  | Designed out by §6.8.                                                                  |
| `gate_attempts` race across N workers    | Removed by prerequisite §5.1.                                                          |
| Orchestrator synthesis burst             | Bounded report contract (§6.9).                                                        |

## 8. Invariant and decision impact

| ID       | Impact                                                                                                                                     |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **I-1**  | Extended in spirit: bounded reads now also govern wave fan-in (§6.9). Not violated.                                                        |
| **I-4**  | Holds. Task worktrees are ephemeral, under `.agentic/`, deleted at P5.                                                                     |
| **I-5**  | Holds and is reinforced — every failure path resets and redoes rather than partially repairing (§6.6).                                     |
| **I-6**  | Holds textually, because task worktrees are nested inside the feature worktree (§6.7). This is the reason for that siting choice.          |
| **I-7**  | The invariant under most pressure. Wave QA (§6.5 step 7) exists specifically to keep it true.                                              |
| **I-3**  | Enforcement is *corrected* by prerequisite §5.1; the invariant itself is unchanged.                                                        |
| **D-7**  | Holds. One state file per feature; task worktrees get no state file of their own (§6.8).                                                   |
| **D-6**  | Holds. Every parallel executor and the Wave QA dispatch pin model/effort explicitly.                                                       |
| **D-12** | **Amended.** A wave of N produces **one** green checkpoint, not N, so `revert-last-green` rolls back to a wave boundary. A wave of 1 keeps per-task granularity. This is the only amendment the design requires. |

## 9. Expected payoff (estimated, not measured)

For a 3-task wave, assuming ~4 min model time per task and ~1.5 min per FAST run:

| Path                                | Wall clock  |
| ----------------------------------- | ----------- |
| Serial (today)                      | ~12 min     |
| Waves, before Wave QA was mandatory | ~5.5 min    |
| **Waves, with mandatory Wave QA**   | **~7 min**  |

These numbers are reasoned, not observed, and they assume **good predictions**. Every wave that hits
conflict-abort or Wave-QA-red is *slower* than serial for that wave. See §10.

## 10. Success metric and kill criteria

The entire payoff rests on one unmeasurable-until-M1b quantity: **how reliably the planner predicts
`files` and `depends_on` for code that does not exist yet.**

- **Primary metric — bisect rate:** the percentage of waves (size > 1) that hit conflict-abort or
  Wave-QA-red.
- **Secondary metric:** P2 wall-clock, waves vs. serial, on the same OpenSpec change.

**Kill criteria:** if the bisect rate exceeds ~30%, or P2 wall-clock does not improve by at least
~25%, **delete the feature** and leave P2 serial. Those thresholds are guesses and should be
re-set once real numbers exist; the discipline of having a kill criterion is the point, not the
specific numbers.

## 11. Open questions (resolve after M1b, with data)

- `AGENTIC_MAX_PARALLEL` default (3 is a guess).
- Is planner prediction quality good enough to clear §10 at all?
- Should Wave QA be a distinct subagent rather than a `qa` dispatch with a different prompt?
- Interactive mode gets a free human review of the wave plan at the existing P1 approval pause; auto
  mode has no such check. Does auto need a cheap sanity check on the declared graph beyond §6.3?

**Closed by this spec:** the roadmap's `depends_on` open decision (front-matter vs. manifest) is
resolved as **neither** — it lives in `state.json` task records, written via `task-add` flags
(§6.1), consistent with D-7.
