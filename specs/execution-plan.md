# agentic-workflow — execution plan

> **Purpose.** This is the *build* plan: how to take the current scaffold to a complete, working system,
> broken down to the task level, for **both** `agentic-engineer` and `agentic-management`. It is the
> companion to `plan.md` (which holds the architecture, the locked decisions `D-*`, and the invariants
> `I-*`). Where this document says "see D-x / I-x", the rationale lives in `plan.md`; here we focus on
> *what to build, in what order, and how we know it's done.*
>
> Audience: the maintainer (Staff SWE). Conventions: English artifacts, kebab-case, `jq`+`git` required.

---

## 0. Current state — honest audit

The scaffold exists but is **not a working system yet**. What is real vs. what is a shell:

| Area | Status | Gap to close |
| --- | --- | --- |
| `agentic-core` hooks (`safety-guard`, `emit-event`, `session-bearings`) | Written, plausible | Untested on a real session; deny-list needs false-positive tuning |
| `agentic-core` `verify-gate.sh` | Written but **minimal** | The phase/gate state machine is shallow: no explicit re-entry handling (P4→P2), no per-check staleness, coarse runaway guard |
| `agentic-core` libs (`state.sh`, `checkpoint.sh`, `profile.sh`) + `bin/` wrappers | Written | Untested end-to-end; schema not exercised |
| `agentic-engineer` orchestrator SOP + subagents + command | Written | Never run against a repo; superpowers skill wiring unverified; worktree-first ordering unconfirmed; **new `qa` subagent not yet created** (currently 4: worktree/planner/executor/reviewer) |
| `agentic-management` `agentic-ba` skill | **Stub** | No real docs→OpenSpec proposal logic |
| `agentic-management` `agentic-pm` skill + `pm-runner.sh` | **Skeleton** | Selection/dependency logic, progress schema, success-signal gating, compaction, budgeting all TODO |
| `bin/{install,update,uninstall}.sh` | Written | Untested against a clean `~/.claude`; marketplace registration unverified |
| Observability beyond NDJSON | Not started | SSE + SQLite + dashboard (deferred) |
| Tests / smoke harness | **None** | No way to prove any of the above works |

**Conclusion:** the engineer is scaffolded but unproven; the management side is essentially unbuilt below
the SKILL descriptions. This plan closes both, engineer first (it is a dependency of PM), then management.

---

## 1. System decomposition

Three plugins, two "models", one hard boundary that must stay clear:

```
 MONOREPO (this repo = the TOOLING)                 TARGET PROJECT (the user's repo = the STATE)
 ┌───────────────────────────────────┐              ┌──────────────────────────────────────────┐
 │ packages/agentic-core   (kernel)  │   operates   │ <repo>/                                    │
 │ packages/agentic-engineer (M1)    │ ───────────► │   openspec/  ← durable mgmt memory (I-11)  │
 │ packages/agentic-management (M2)  │              │     specs/            (source of truth)    │
 │ bin/ install·update·uninstall     │              │     changes/{id}/     (active proposals)   │
 └───────────────────────────────────┘              │     changes/archive/  (history)            │
                                                     │     .pm/progress.json (PM cursor)          │
   installed into ~/.claude (or --target)            │     .pm/outcomes/{id}.json (engineer→PM)   │
                                                     │   <worktree>/.agentic/state.json           │
                                                     │                 ← ephemeral eng memory(I-4) │
                                                     └──────────────────────────────────────────┘
```

- **`openspec/` lives in the target project**, created by `openspec init` there — *not* in this monorepo.
  The monorepo is tooling; `openspec/` is the target's state. (The monorepo may have its own `openspec/`
  only for self-development.)
- **`agentic-engineer` depends on `agentic-core`** (uses its hooks/libs). When both install, their hooks
  merge in settings.
- **`agentic-management` depends on both** (BA writes OpenSpec; PM dispatches the engineer).

### The two models, side by side

| | `agentic-engineer` (inner) | `agentic-management` (outer) |
| --- | --- | --- |
| Unit of work | One feature / one OpenSpec change | A backlog of changes |
| Shape | Orchestrator + subagents + full harness (9 components) | Orchestrator + subagents; **deterministic shell** driver |
| Session model | Window-bounded, single run | Long-running via *many ephemeral* engineer runs (`I-1`) |
| Memory | Ephemeral `.agentic/` in worktree, dies at P5 (`I-4`) | Durable OpenSpec `specs/`+`changes/` (`I-11`) |
| Skills | `agentic-engineer` | `agentic-ba`, `agentic-pm` |
| Runs how | Interactive (human) **or** `auto` (PM-driven) | CLI batch (`pm-runner.sh`) |

---

## 2. Workstreams & dependency order

Six workstreams. Build top-to-bottom; within a workstream, tasks are ordered.

```
 WS-A  agentic-core hardening ───────┐  (everything depends on the kernel)
                                     ▼
 WS-B  agentic-engineer end-to-end ──┼──► must be PROVEN before PM can use it
                                     ▼
 WS-C  agentic-ba (docs → OpenSpec) ─┤  (produces the changes PM consumes)
                                     ▼
 WS-D  agentic-pm deterministic loop ┘  (consumes changes, dispatches engineer)
 WS-E  install / profiles / packaging   (parallelizable, needed for real testing)
 WS-F  observability + test harness      (cross-cutting; start the test harness early)
```

Rule of sequencing: **do not start WS-D (PM) until WS-B (engineer) passes its acceptance on a real repo.**
PM that dispatches an unproven engineer just multiplies failures.

---

## 3. PART I — `agentic-core` (kernel) execution

The kernel is what makes every run safe and honest. It is shared, so correctness here has the highest
leverage.

### 3.1 State model — `state.sh` / `.agentic/state.json`

Full schema (the `feature_list.json` role, `D-7`; ephemeral, `I-4`):

```json
{
  "schema": "agentic-state/1",
  "feature": "<slug>",
  "created_at": "<iso8601>",
  "phase": "P0|P1|P2|P3|P4|P5",
  "mode": "interactive|auto",
  "change_id": "<openspec-id|null>",
  "worktree_path": "<abs path|null>",
  "verify_cmds": { "fast": "<lint+typecheck cmd|null>", "component": "<component/unit test cmd|null>", "large": "<full suite cmd|null>" },
  "checks":      { "fast": "pass|fail|null", "large": "pass|fail|null", "review": "pass|changes_requested|null" },
  "tasks":       [ { "id": "t1", "title": "...", "status": "pending|in_progress|verified|failed" } ],
  "checkpoints": [ { "phase": "P2", "label": "t1", "sha": "...", "green": true, "ts": "..." } ],
  "gate_attempts": 0,
  "needs_human": false,
  "blocking_reason": null
}
```

**Tasks**
- **T-C1** Add `mode`, `change_id`, `blocking_reason` to `cmd_init` and to the CLI (get/set already cover
  arbitrary dot-keys; add explicit setters for clarity). Acceptance: `agentic-state show` on a fresh init
  contains all keys above.
- **T-C2** Add `state.sh checkpoints-add` / `last-green` helpers backing `checkpoint.sh` so the checkpoint
  list is a first-class part of state (not only git log). Acceptance: a green checkpoint appears in both
  `git log` and `state.checkpoints`.
- **T-C3** Unit-test `state.sh` with a throwaway `AGENTIC_STATE=/tmp/...` file: init → phase transitions →
  task lifecycle → `tasks-remaining` counts correctly. Acceptance: a `bats`/shell test passes.

### 3.2 Verification gate — `verify-gate.sh` (the big one)

Current logic is a coarse per-phase switch. Deepen it into an explicit state machine. This is the item
most responsible for "the agent actually finishing correctly."

**Gate contract (per phase, evaluated on every Stop / SubagentStop):**

| Phase | Block (force continue) when… | Allow stop when… |
| --- | --- | --- |
| P0 | worktree_path unset while phase==P0 | worktree recorded |
| P1 | (interactive) plan not written; (both) `verify_cmds.fast`/`large` unset | plan written + verify cmds recorded; interactive additionally requires human-approval flag |
| P2 | `tasks-remaining != 0` OR `checks.fast == fail` | all tasks `verified` AND `checks.fast == pass` |
| P3 | `checks.large != pass` | `checks.large == pass` |
| P4 | `checks.review == changes_requested` | `checks.review == pass` |
| P5 | cleanup not done (worktree still present in auto) | cleaned up / handed off |
| else | never | always |

**Tasks**
- **T-C4** Introduce an explicit `gate_reason` per block that names the *phase + condition*, so the
  re-injected prompt is specific (already partly done; make it exhaustive per the table).
- **T-C5** **Re-entry handling:** when P4 sets `review=changes_requested`, the orchestrator moves back to
  P2; the gate must then evaluate P2 rules again and **reset stale checks** (`checks.large=null`,
  `checks.review=null`) so a later stop can't pass on a green flag from the *previous* pass. Add a
  `state.sh reopen <fromPhase>` that nulls downstream checks. Acceptance: simulated P4→P2→P3→P4 cycle
  cannot terminate until *fresh* large+review are green.
- **T-C6** **Per-check staleness:** stamp each check with the git SHA it was computed at
  (`checks.fast_at`, etc.). The gate treats a check as `null` if HEAD advanced past its SHA. Acceptance:
  editing code after a green fast check re-blocks until fast is re-run.
- **T-C7** **Runaway guard refinement:** keep `AGENTIC_GATE_MAX` (default 25) but count attempts *per
  phase* and record `blocking_reason` when escalating to `needs_human`. Acceptance: exceeding the cap sets
  `needs_human=true` + a human-readable `blocking_reason`, and the gate then allows stop.
- **T-C8** Keep fail-open on missing `jq`/state (never brick a real session). Acceptance: no state file →
  gate allows immediately.

### 3.3 Safety guard — `safety-guard.sh` (PreToolUse, `I-2`/`D-9`)

Current deny catalog is solid; the risk is false positives stalling the pipeline and gaps under headless.

**Deny catalog (keep + verify):** `rm -rf` on root/home/system; recursive delete of root/home; fork bomb;
`mkfs`/`dd of=/dev/…`/redirect to block device; `curl|wget … | sh` (RCE / prompt-injection, `D-10`); `git
push --force` / `--delete`; `chmod 777` on root-ish; writes to `.git`/`.ssh`/`.aws`/`.gnupg`/`/etc`/`.env`;
**worktree confinement** (writes must stay under the active worktree, OpenSpec artifacts excepted, `I-6`).

**Tasks**
- **T-C9** Build a **fixture suite** of ~30 command/edit inputs (dangerous → expect exit 2; benign →
  expect exit 0) and run `safety-guard.sh` against each via piped JSON. Acceptance: 100% of the fixtures
  classify as intended; document any deliberately-allowed edge.
- **T-C10** Emit **structured** decisions where useful (`hookSpecificOutput.permissionDecision`) in
  addition to exit codes, for clearer surfacing than raw exit-2. Acceptance: a denied Bash op shows a
  clear reason in the transcript.
- **T-C11** Confirm confinement reads `WORKTREE_PATH` env first, then `state.get worktree_path`, and that
  `realpath -m` handles non-existent paths. Acceptance: a write to `../outside` is denied; a write to
  `openspec/…` is allowed.

### 3.4 Checkpoints — `checkpoint.sh` (`D-12`/`I-5`)

**Tasks**
- **T-C12** Verify `checkpoint`, `list`, `last`, `revert-last-green` against a scratch git repo; marker
  `[agentic:ckpt]`. Acceptance: after two green checkpoints and a broken edit, `revert-last-green` returns
  HEAD to the last green SHA and the tree is clean.
- **T-C13** Ensure checkpoints are **the only** rollback path used anywhere (audit SKILL/agents for stray
  `git reset` guidance). Acceptance: grep shows rollback references route through `agentic-checkpoint`.

### 3.5 Observability emitter — `emit-event.sh` (`D-11`) & session bearings

**Tasks**
- **T-C14** Confirm PostToolUse emitter is fire-and-forget (always exit 0), writes one NDJSON line per
  event to `$AGENTIC_HOME/events.ndjson` (default `~/.agentic`), and optionally POSTs to
  `$AGENTIC_SSE_URL` without blocking. Acceptance: a run produces well-formed NDJSON; unsetting the URL
  changes nothing; a slow/unreachable URL does not stall the agent (`I-8`).
- **T-C15** `session-bearings.sh` (SessionStart, `I-10`): inject cwd, active profile, a reminder that the
  **target project's** rules win, the current `.agentic/state.json` summary, and a *bounded* `git log -5`.
  Acceptance: a fresh session prints bearings; long histories are truncated.

### 3.6 Profiles — `profile.sh`

**Tasks**
- **T-C16** Detect direnv/`CLAUDE_CONFIG_DIR`; if the target project pins a profile via `.envrc`, use it,
  else default. Acceptance: with and without `.envrc`, `agentic-profile` reports the right config dir.

---

## 4. PART II — `agentic-engineer` execution (both modes)

The inner loop. Orchestrator dispatches subagents via `Task`; hooks keep it honest. Per-role model/effort
(`D-6`), pinned **at dispatch** (bug #44385 workaround):

| Phase | Subagent | Model / effort | Superpowers skill | In → Out |
| --- | --- | --- | --- | --- |
| P0 | `worktree` | haiku / low | `using-git-worktrees` | feature slug → isolated worktree + clean baseline, returns `WORKTREE_PATH` |
| P1 | `planner` | opus / high | `brainstorming` (interactive) + `writing-plans` | request **or** OpenSpec change → specs + fine-grained plan + detected verify cmds + registered tasks |
| P2 | `executor` | sonnet / medium | `executing-plans` / subagent-driven-development | plan → implemented **feature** code, one task at a time; hands each task to `qa` |
| P2 (per task) & P3 | `qa` | sonnet / medium | `test-driven-development` + `verification-before-completion` | **writes test files** + **runs verification**: FAST (lint+typecheck+component) after each task; LARGE (full suite) at P3. Green → checkpoint; red → route fix |
| P3 | *(orchestrator + `qa`)* | — | — | `qa` runs the **real** large suite (lint+type+component+integration+e2e); orchestrator gates on the result |
| P4 | `reviewer` | opus / high | `requesting-code-review` (2-stage) | code + spec → approve / changes_requested (**no edits**) |
| P5 | *(orchestrator)* | — | — | merge/PR + cleanup, or stop for human |

> Superpowers skill IDs above should be confirmed against the installed version (e.g.
> `using-git-worktrees` vs `using-git-worktree`); the orchestrator names the skill inside each subagent.

### 4.1 The orchestrator SOP — build tasks

- **T-E1** **Mode + input resolution.** `interactive` unless `--mode auto`. In `auto`, `--change <id>` sets
  `openspec/changes/<id>/` as source of truth and the run never pauses. Record `mode` + `change_id` in
  state. Acceptance: both invocations initialize state correctly and honor the pause/no-pause rule.
- **T-E2** **P0 wiring.** Dispatch `worktree` (haiku); on return, from *inside* the worktree run
  `agentic-state init` → `set worktree_path` → `phase P0` → `checkpoint P0 --green`. Acceptance: a worktree
  on a new branch exists with a clean baseline and state initialized inside it.
- **T-E3** **P1 wiring + the mode split (the key engineer decision).**
  - `interactive`: `planner` runs `brainstorming` (Socratic) → `writing-plans` → **STOP for human
    approval** (set an approval flag the gate checks).
  - `auto`: `planner` **skips brainstorming**, reads `openspec/changes/<id>/{proposal,design,specs,
    tasks}.md`, writes `assumptions.md` for gaps, then `writing-plans`; proceeds without a checkpoint.
  - Both: **auto-detect** fast/large verify commands from the project (see T-E7) and record them; register
    each plan task via `task-add`.
  - Acceptance: interactive halts for approval with a plan present; auto proceeds straight to P2 having
    read the change and recorded verify cmds + tasks.
- **T-E4** **P2 wiring (executor → QA per task).** `executor` implements **one task at a time** (feature
  code only). After each task, dispatch `qa` to (a) write/update the **component test** for that task and
  (b) run **FAST verify = lint + typecheck + component test** (the component step only if the project
  configures component/unit testing). On pass: `task-set <id> verified` + `checkpoint P2 <id> --green`. On
  fail: `check-set fast fail`; **route the fix** — a failing *test* is `qa`'s to fix, a failing *impl* goes
  back to `executor` (bounded retries) — then re-verify to `pass`. The gate blocks stop while tasks remain
  / fast is red. Acceptance: a 3-task plan yields 3 tasks each with a passing component test written, 3
  green checkpoints, and zero remaining tasks before P3 is allowed.
- **T-E5** **P3 wiring (QA-owned large verify).** Dispatch `qa` to ensure the broader tests exist
  (integration/e2e as the project configures) and run **LARGE verify = the full suite** (lint + typecheck
  + component + integration + e2e). Pass → `check-set large pass` + checkpoint. Fail → `check-set large
  fail`, return to P2 (`reopen P2` nulls downstream checks, T-C5); if broken, `revert-last-green`.
  Acceptance: an injected failure forces P2 re-entry and cannot be skipped; the large suite includes the
  component tests `qa` wrote in P2.
- **T-E6** **P4 wiring.** `reviewer` (read-only) does 2-stage review vs specs. Approve → `review pass`;
  changes → `review changes_requested` → back to P2. Acceptance: a spec-violating diff yields
  `changes_requested` and the run cannot terminate until a *fresh* review passes.
- **T-E7** **Verify auto-detection heuristic** (used in P1). Detect from the project: Node
  (`package.json` scripts: lint/typecheck; a component/unit runner such as `test`/`test:unit`/
  `test:component`; integration/e2e; pnpm/yarn/npm), plus common fallbacks. Record `fast` (lint+typecheck),
  `component` (component/unit test cmd, if present), and `large` (lint+type+component+integration+e2e).
  **FAST at execute = `fast` + `component` when present**; a project without a component runner yields
  `component:null` and FAST falls back to lint+typecheck. Confirm the heuristic list with the maintainer.
  Acceptance: on a sample Node repo all detected commands run; a repo without component tests correctly
  yields `component:null`.
- **T-E8** **P5 lifecycle + cleanup.** `interactive`: summarize, stop for human merge. `auto`: open PR /
  merge on green per policy, **write the outcome record** (T-M-contract below), then remove the worktree +
  `.agentic/` (`I-4`) and hand back to PM. Acceptance: after auto success, no engineer state remains
  outside the archived change and the outcome file exists.
- **T-E9** **`needs_human` handling.** If set, stop and surface `blocking_reason` to human/PM; do not
  retry. Acceptance: forcing the runaway guard produces a clean escalation, not an infinite loop.
- **T-E10** **Worktree-first ordering decision.** Confirm keeping P0 (worktree) before P1 (plan), which
  diverges from the superpowers default but isolates all work from the first byte. Document the choice.

### 4.2 Subagents — new QA + prompt hardening

- **T-E12** **New `qa` subagent** (`agents/qa.md`; `sonnet` / medium; tools Read, Grep, Glob, Edit, Write,
  Bash; skills `test-driven-development` + `verification-before-completion`). Responsibilities: author and
  maintain **test files** (component tests in P2, integration/e2e in P3) and **run verification** (FAST per
  task, LARGE at P3), reporting pass/fail with the failing output. Constraints: writes **only test files**,
  stays inside the worktree (`I-6`), and does **not** modify feature code — implementation fixes route back
  to `executor`. Its FAST/LARGE runs are what drive `checks.fast` / `checks.large`. Acceptance: `qa`
  produces runnable tests, its verify runs set the checks, and it never edits non-test source.
- **T-E11** For each of `worktree`/`planner`/`executor`/`qa`/`reviewer`: pin scope (worktree-only writes),
  keep the `reviewer` read-only, restrict `qa` to test files, and make each subagent restate the target
  project's guidelines it must follow. Acceptance: reviewer never edits; `qa` only touches test files;
  `executor` never writes outside the worktree.

### 4.3 Engineer acceptance (WS-B gate) — must pass before PM

Run on a **real** repo:
1. Interactive: build a small real feature end-to-end with a human approving P1 and merging P5.
2. Auto: implement one hand-written OpenSpec change to green with **no** human input.
3. Prove each hook fires (safety blocks a destructive op even under skip-permissions; gate refuses every
   red stop condition; events land in NDJSON).
4. Prove rollback: break the tree, `revert-last-green`, recover.
5. Prove cleanliness: `.agentic/` gone at P5; outcome file written in auto.
6. Prove QA: `qa` writes a component test per task and it runs in FAST; the LARGE suite includes those
   tests; a deliberately failing component test blocks the per-task gate until fixed.

---

## 5. PART III — `agentic-management` execution (BA + PM)

The outer loop. This is the part that was a stub; here it is specified in full. Two skills + one
deterministic driver. The whole reason it can run over thousands of changes without bloat is `I-1`/`D-14`:
**deterministic shell + ephemeral `claude -p` per change + bounded reads.**

### 5.1 Memory layering (the clean separation)

- **Ephemeral engineer memory:** `writing-plans` output (2–5 min tasks, fine-grained) lives in
  `<worktree>/.agentic/` and dies with the worktree (`I-4`).
- **Durable management memory:** `openspec/changes/{id}/{proposal,design,specs}` + `openspec/specs/`
  (source of truth) + `changes/archive/` (history) (`I-11`).
- **Durable *code* artifact (new, via QA):** the **tests the `qa` subagent authors** during a run are
  committed *with* the feature at P5 merge — they live in the **target repo**, not in the ephemeral
  `.agentic/`. So every archived change leaves behind feature code **and** its tests, permanently. The
  spec is the durable *intent*; the tests are the durable *executable proof* of that intent.
- In `auto`, the planner **reads the OpenSpec change as input** instead of brainstorming from scratch. One
  `agentic-engineer`, two input sources. This is the seam that lets PM drive the engineer headlessly.

### 5.2 `agentic-ba` — docs/design → OpenSpec proposals

Maps to OpenSpec's **explore + propose** phases (`D-4`). Replaces the original `/tickets/ticket-{n}-
{feature}.md` idea; an OpenSpec *change* **is** a ticket, with history + archive for free.

**Contract**
- **Input:** the target project's specification docs and UI design (paths/globs configurable).
- **Output:** for each unit of work, an OpenSpec change at `openspec/changes/{id}/` containing
  `proposal.md`, `design.md`, `tasks.md`, and `specs/` deltas. `{id}` is a stable, kebab-case slug.
- **Testable acceptance criteria (the QA target — the key BA↔engineer handoff):** each change's `specs/`
  scenarios / `tasks.md` must state acceptance criteria as **concrete, verifiable behaviors**. This is
  exactly what the engineer's `qa` subagent turns into component/integration/e2e tests. BA describes *what
  correct looks like*; QA encodes it as executable tests; `verify-gate` enforces they pass. A change with
  no testable criteria is **incomplete** — PM should not dispatch it.
- **Update semantics:** when source docs change, *diff* against existing changes and update only what
  moved; never silently drop scope. History is the git trail + OpenSpec archive.
- **Validation:** every emitted change must pass `openspec` validation before PM will consume it.

**Tasks**
- **T-M1** Define the change-id convention + a mapping doc-section → change. Acceptance: two runs over the
  same docs produce stable ids (idempotent).
- **T-M2** Implement doc→proposal generation (a subagent, opus/high for analysis) that reads specs + UI
  design and writes a valid `proposal.md`/`design.md`/`tasks.md` + spec deltas, **including explicit
  testable acceptance criteria** (verifiable scenarios) in each change — the target the engineer's `qa`
  subagent writes tests against. Acceptance: `openspec` validates the output; a human finds the proposal
  faithful to the doc; **every change carries acceptance criteria concrete enough for `qa` to author
  tests without guessing.**
- **T-M3** Implement **update/diff** on changed docs: detect changed sections, update affected changes,
  leave archived ones alone. Acceptance: editing one doc section updates exactly one change.
- **T-M4** Declare **inter-change dependencies** in a machine-readable field (e.g. front-matter
  `depends_on: [id...]` in `proposal.md`) so PM can order them. Acceptance: a dependency is expressed and
  parseable by `pm-runner.sh`.

### 5.3 `agentic-pm` + `pm-runner.sh` — the deterministic outer loop

The user's coordination flow, made concrete and bloat-proof:

```
init/attach openspec + progress.json
while (pending changes remain):
  1. agentic-ba sync        # only if source docs changed → (re)generate/refresh openspec/changes/
  2. id = next_change()     # deterministic: satisfy depends_on, then priority, skip done/failed
  3. claude -p  ── FRESH EPHEMERAL PROCESS ──
        /agentic-engineer:engineer --change <id> --mode auto
        --output-format stream-json  (for observability)
        (headless perms = PreToolUse allow-list + permissions.allow, never global bypass — D-10)
  4. outcome = read openspec/.pm/outcomes/<id>.json     # SUCCESS-SIGNAL GATING (not just exit code)
     if outcome.status == success:      openspec archive <id>; progress.done += id
     elif outcome.status == needs_human: progress.blocked += id; ESCALATE per policy
     else:                               progress.failed += id; retry-with-backoff or stop per policy
  5. update progress.json (append-only); engineer context is GONE here
  6. every K iterations: one bounded `claude -p` compaction → re-prioritize remaining work
  7. enforce budget: if cost or wall-clock cap exceeded → stop + report
```

**The engineer→PM outcome contract** (resolves the "success signal" gap): in `auto` P5, *before* worktree
cleanup, the engineer writes a durable record (allowed by the OpenSpec/`.pm` exception to `I-6`). A
`success` status already implies **LARGE passed** — including the tests `qa` wrote — since `verify-gate`
would not let the run finish otherwise; the `verification` block makes that explicit and observable:

```json
// openspec/.pm/outcomes/<id>.json
{ "schema":"pm-outcome/1", "change_id":"<id>", "status":"success|needs_human|failed",
  "reason":"<blocking_reason|null>", "checkpoints":<n>, "pr":"<url|branch|null>", "ts":"<iso8601>",
  "verification": { "large_passed": true, "tests_written": <n>, "levels": ["component","integration","e2e"] } }
```

So **archiving a change guarantees it was built *and* QA-verified** (tests authored + LARGE green), and
those tests ship with the feature in the target repo.

**`progress.json` schema** (bounded reads only, `I-1`):

```json
{ "schema":"pm-progress/1",
  "done":[], "failed":[], "blocked":[], "cursor":null,
  "meta": { "<id>": { "attempts":0, "last_status":null, "cost_usd":null, "ts":null } },
  "budget": { "cost_cap_usd":null, "wall_clock_cap_min":null, "spent_usd":0, "elapsed_min":0 } }
```

**Tasks**
- **T-M5** **Selection algorithm.** Implement `next_change()`: filter active (non-archived) changes, honor
  `depends_on` (topological order), then priority, skipping `done`/`failed`/`blocked` from
  `progress.json`. Bounded reads only. Acceptance: given changes A→B→C with deps, PM dispatches in valid
  topological order and never re-runs a done id.
- **T-M6** **Ephemeral dispatch.** Wire the `claude -p` call with pinned `--allowedTools` / settings and
  `--output-format stream-json`. Prove context does not carry across iterations. Acceptance: two
  successive changes each start from zero context (verified via event stream / logs).
- **T-M7** **Success-signal gating.** Read `outcomes/<id>.json`; branch archive vs escalate vs retry on
  *actual* status, not the process exit code. Treat a `success` whose `verification.large_passed` is not
  `true` as a **contract violation** → do not archive, escalate. Acceptance: an engineer that sets
  `needs_human` is **not** archived (PM routes it to `blocked` and escalates); a malformed/inconsistent
  outcome never results in an archive.
- **T-M8** **Escalation + retry policy.** On `failed`: bounded retry with backoff, then stop-or-continue
  per config. On `needs_human`: stop the loop or park-and-continue per config, always surfacing the
  reason. Acceptance: policy is configurable and observed.
- **T-M9** **Periodic compaction.** Every K iterations, run one bounded `claude -p` that reads a *compact
  rollup* (pending slice + recent outcomes) and rewrites a short re-prioritized plan — never the full
  history. Acceptance: compaction input size is bounded and independent of tickets-done count.
- **T-M10** **Budgeting.** Track `spent_usd`/`elapsed_min` (fed by the event stream / per-run cost) against
  caps; stop + report when exceeded. Note: each engineer run now includes `qa` dispatches (per-task tests +
  LARGE), so per-change cost is **higher** than an impl-only run — size caps accordingly. Acceptance:
  setting a low cap halts the loop with a clear report.
- **T-M11** **Bounded-read discipline audit.** Confirm none of `progress.json`, `openspec/specs/`, or `git
  log` is ever read wholesale per iteration (the three bloat sources). Acceptance: a static check / review
  shows only slices + rollups + `git log -n <small>` are read.

### 5.4 The three bloat sources — bounds (must hold, `I-1`)

| Source | Risk at 1000 changes | Enforced bound |
| --- | --- | --- |
| `progress.json` | 1000 entries re-read each loop | pending slice + compact rollup only; history append-only, never re-read wholesale |
| `openspec/changes/` | grows with pending work | `openspec archive` shrinks the active dir automatically |
| `openspec/specs/` | genuinely accumulates | BA/engineer read only the slice for the current change; `git log -n <small>` only |

### 5.5 Management acceptance (WS-D gate)

1. `agentic-ba` turns a real doc set into valid OpenSpec changes (idempotent; updates on doc change),
   **each carrying testable acceptance criteria** concrete enough for the engineer's `qa` to write tests.
2. `pm-runner.sh` drives a **multi-change backlog** (≥3, with a dependency) to completion, archiving each,
   using the outcome contract — with **flat context footprint** (change #1 == change #N).
3. A `needs_human` change is escalated, not archived; a `failed` change follows the retry policy; a
   `success` with `verification.large_passed != true` is treated as a violation and **not** archived.
4. Budget caps halt the loop cleanly.
5. **End-to-end QA proof:** for at least one change, confirm the BA's acceptance criteria are reflected in
   the tests `qa` wrote, and that those tests are **committed to the target repo** alongside the feature
   (not lost with the worktree).

---

## 6. PART IV — install / profiles / packaging

**Tasks**
- **T-I1** `install.sh --target <dir=~/.claude> --mode <symlink|copy>`: `chmod +x` scripts; register the
  local marketplace (settings `extraKnownMarketplaces` via `jq`); print the `/plugin install …` + `/reload-
  plugins` commands. Symlink mode for live editing (`D-13`). Acceptance: clean `--target` gains the three
  plugins; symlink mode reflects on-disk edits after `/reload-plugins`.
- **T-I2** `update.sh`: git pull + re-link/copy + `openspec update` where relevant. Acceptance: an edit
  upstream propagates.
- **T-I3** `uninstall.sh`: remove links/dirs, **preserve user data** (`~/.agentic`, target `openspec/`).
  Acceptance: uninstall leaves no plugin traces but keeps events/state/specs.
- **T-I4** JSON validation gate: `jq . packages/*/.claude-plugin/plugin.json packages/*/hooks/*.json` in a
  pre-flight. Acceptance: malformed JSON fails the check.

---

## 7. PART V — observability

- **T-O1** (now) Ensure `emit-event.sh` NDJSON schema carries enough for cost/latency views (event type,
  tool, ts, session/subagent id, tokens/cost if available). Acceptance: a run yields a stream sufficient
  to compute per-role token/cost.
- **T-O2** (M3) SSE + SQLite event bus consuming `events.ndjson`. Acceptance: events queryable.
- **T-O3** (M3) Vite + React dashboard: per-run + per-role token/cost, phase timeline, gate/needs_human
  events. Acceptance: a completed engineer run renders end-to-end.

> Note: keep observability to the NDJSON→SSE→dashboard pipeline above. (No multi-account bridge — out of
> scope for this build.)

---

## 8. Milestones (sequenced) with deliverables

| Milestone | Contains | Deliverable / acceptance |
| --- | --- | --- |
| **M0** ✅ | Scaffold | Files exist (done) |
| **M1a** | WS-A: kernel hardening + tests | `state.sh`/`safety-guard`/`verify-gate`/`checkpoint` pass their fixture/unit tests (§3) |
| **M1b** | WS-B: engineer end-to-end (incl. `qa`) | Passes the WS-B acceptance on a real repo, both modes; `qa` writes tests, FAST includes component, LARGE runs the suite (§4.3) |
| **M1c** | WS-E: install/profiles | Clean install + symlink dev loop works (§6) |
| **M2a** | WS-C: `agentic-ba` | Real docs → valid, idempotent OpenSpec changes **with testable acceptance criteria** (§5.2) |
| **M2b** | WS-D: `agentic-pm` loop | Multi-change backlog to completion, flat context, outcome-gated (§5.5) |
| **M3** | Observability | SSE + SQLite + dashboard (§7) |

"Done" for the whole system = M1a→M2b green: a maintainer points BA at docs, runs `pm-runner.sh`, and a
backlog of features gets built, verified, reviewed, and archived autonomously — safely, and without a
single long-lived agent session.

---

## 9. Execution risks (build-time)

| Risk | Handling |
| --- | --- |
| Building PM on an unproven engineer | Hard gate: WS-D blocked until WS-B acceptance passes |
| `verify-gate` re-entry bug lets a run finish on stale green | T-C5/T-C6 (reopen + SHA staleness) — highest-priority kernel task |
| Success-signal gap (PM trusts exit code) | Engineer→PM outcome contract (§5.3) — resolved by design, must be implemented (T-E8/T-M7) |
| `safety-guard` false positives stall runs | Fixture suite T-C9; conservative, tunable deny list |
| Bug #44385 (model frontmatter ignored) | Pin model at dispatch (T-E-level) |
| Superpowers/OpenSpec skill IDs drift by version | Confirm IDs against installed versions (T-E, T-M) |
| Bounded-read discipline silently violated over time | Audit T-M11 + the §5.4 table as a review checklist |
| Real ceiling is cost/time/error-accumulation, not context | Budgeting T-M10 + escalation T-M8 |

---

## 10. Open decisions to confirm before/while building

1. **Worktree-first ordering** (P0 before P1) — keep the divergence from superpowers' default? (T-E10)
2. **Verify auto-detect heuristics** — which project types beyond Node, and the exact fast/large mapping?
   (T-E7)
3. **`depends_on` mechanism** — front-matter in `proposal.md` vs a separate manifest? (T-M4)
4. **PM policies** — retry count/backoff, stop-vs-park on `needs_human`, K for compaction, budget caps.
   (T-M8/T-M9/T-M10)
5. **Superpowers skill IDs** — pin exact names/versions the subagents invoke.
6. **QA dispatch granularity** — dispatching `qa` after *every* task (cleanest separation, more subagent
   calls → more tokens) vs. batching (e.g. `qa` writes/runs component tests for a group of tasks, or once
   at end of P2) . Default here is **per task**; confirm, and consider a `--qa-batch` override. Also confirm
   `qa`'s model/effort (default `sonnet`/medium; bump to high for complex suites). (T-E4/T-E12)

---

## 11. Suggested first sprint

Smallest sequence that yields a *provably working engineer* (the foundation everything else needs):

1. **T-C3 + T-C9 + T-C12** — get the kernel under test (state, safety fixtures, checkpoint).
2. **T-C5 + T-C6** — fix the verify-gate re-entry/staleness holes (the correctness-critical bug class).
3. **T-E1…T-E8 + T-E12** — wire the engineer orchestrator end-to-end, including the new `qa` subagent.
4. **WS-B acceptance (§4.3)** on a small real repo, auto mode first (it's the PM path).
5. Only then: **T-E8 outcome contract + T-M5…T-M7** to stand up the PM loop over a 3-change backlog.

Pick the entry point and I'll start implementing against these task IDs.
