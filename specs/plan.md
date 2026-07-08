# agentic-workflow — implementation plan

> **Read this first.** This is the source-of-truth document for the repository: the architecture,
> the locked decisions (`D-*`), the invariants (`I-*`), the milestone scope, and the build roadmap.
> Code, scripts, and the other docs are downstream of this file. When code and this document
> disagree, one of them is a bug — reconcile deliberately, don't paper over it.

---

## 1. What this is

`agentic-workflow` is a **Claude Code plugin marketplace** that automates a multi-role engineering
workflow. It does not use the Claude Agent SDK. Instead, the nine components of a long-running agent
harness are hand-built out of primitives Claude Code already exposes — **hooks, files, subagents, and
the CLI** — and glued together with deterministic shell.

It ships three plugins:

| Plugin | Role | Milestone |
| --- | --- | --- |
| `agentic-core` | Shared kernel: safety, verification, observability, and state/checkpoint/profile libraries. Every other plugin depends on it. | M1 (done, scaffolded) |
| `agentic-engineer` | Autonomous **single-feature** pipeline: worktree → plan → execute → verify → review. Runs interactively *or* headless. | M1 (scaffolded) |
| `agentic-management` | **BA + PM** automation over OpenSpec: turn docs/design into change proposals with testable acceptance criteria, then drive a deterministic outer loop that dispatches the engineer (whose `qa` subagent turns those criteria into tests) per change without context bloat. | M2 (stub) |

The design goal is a system that can implement one feature *correctly and safely* on its own, and then
be wrapped by an outer loop that can run *thousands* of features back-to-back without a single
long-lived agent session accumulating context.

### Non-goals

- No Claude Agent SDK, no bespoke agent framework. We wrap Claude Code, superpowers, and OpenSpec.
- We do **not** reimplement brainstorming/planning/execution/review skills (superpowers has them, `D-3`)
  or a ticket/spec system (OpenSpec has one, `D-4`).
- Not a chat product. The engineer's "intelligence" is bounded and audited; correctness comes from
  real verification and deterministic control flow, not from a clever prompt.

---

## 2. Architecture at a glance

Two nested loops. The **inner loop** (engineer) builds one feature. The **outer loop** (PM) is plain
shell that spawns a *fresh, ephemeral* engineer per change and throws its context away on exit.

```
 OUTER LOOP  (agentic-management / pm-runner.sh — deterministic shell, ~0 context)
 ┌────────────────────────────────────────────────────────────────────────────┐
 │  while (pending OpenSpec changes):                                          │
 │    1. agentic-ba sync        (only if source docs changed) → openspec/changes│
 │    2. next_change()          (deterministic: deps + priority + progress.json)│
 │    3. claude -p  ── FRESH EPHEMERAL PROCESS ──────────────┐                 │
 │                    /agentic-engineer:engineer             │  context dies    │
 │                       --change <id> --mode auto           │  when the        │
 │                                                            │  process exits   │
 │    ┌───────────────────────────────────────────────────┐ │                 │
 │    │ INNER LOOP (agentic-engineer — one feature)        │ │                 │
 │    │  P0 worktree → P1 plan → P2 execute → P3 verify     │ │                 │
 │    │  → P4 review → P5 lifecycle                          │ │                 │
 │    │  (enforced the whole way by agentic-core hooks)     │ │                 │
 │    └───────────────────────────────────────────────────┘ │                 │
 │                    ◄──────────────────────────────────────┘                 │
 │    4. openspec archive <id>  → update progress.json (append-only)            │
 │    5. every K iterations: one bounded `claude -p` compaction to re-prioritize│
 └────────────────────────────────────────────────────────────────────────────┘

 ENFORCEMENT LAYER (agentic-core hooks — the same in both loops)
   SessionStart   → session-bearings.sh   (get-bearings: cwd, profile, project rules, state, git log)
   PreToolUse     → safety-guard.sh        (deny destructive ops; fail-closed; runs before permissions)
   PostToolUse    → emit-event.sh          (NDJSON event stream; fire-and-forget; always exit 0)
   Stop/Subagent  → verify-gate.sh         (block "stop before green"; runaway guard → needs_human)
```

Why this shape is the whole point: a single agent session that "manages" thousands of tickets will
accumulate context until it hits the window limit, and compaction alone degrades (summary-of-summary).
By making the outer loop deterministic shell and each unit of LLM work a throwaway process, the context
footprint of change #1 equals that of change #100,000. See `I-1`.

---

## 3. Locked decisions (`D-*`)

These are settled. Changing one is a deliberate act that ripples through the scaffold.

| ID | Decision | Rationale / notes |
| --- | --- | --- |
| **D-1** | Ship as a **Claude Code plugin marketplace**, not an SDK app. | Hard constraint: no Agent SDK. Reuse Claude Code's hook/subagent/CLI surface. |
| **D-2** | Three packages: `agentic-core` (kernel) + `agentic-engineer` + `agentic-management`; core is a shared dependency. | Clean seam between "enforcement kernel" and "role pipelines". |
| **D-3** | Use **`obra/superpowers`** skills *inside* the subagents rather than reimplementing brainstorm/plan/execute/review. | Superpowers already has `brainstorming`, `writing-plans`, `subagent-driven-development` (2-stage review), `requesting-code-review`, `using-git-worktrees`. |
| **D-4** | Use **`Fission-AI/OpenSpec`** as the spec/ticket substrate, not a bespoke `/tickets` system. | `openspec/changes/{id}/` for proposals + `openspec/specs/` as source of truth + `changes/archive/`. Propose→apply→archive gives a *natural* bound on active work. |
| **D-5** | Support **both interactive and headless (`auto`) modes** per invocation, selected by `--mode`. | Same pipeline; humans drive it locally, PM drives it in batch. |
| **D-6** | **Model + effort assigned per role**, and the model is pinned **explicitly at each dispatch**. | Cost/quality balance (see §5). Pinning at dispatch is a workaround for Claude Code bug #44385 (`model:` frontmatter silently ignored). |
| **D-7** | Within-feature state is a single JSON file, `.agentic/state.json`, inside the worktree. | Plays the `feature_list.json` role from Anthropic's long-running-agents pattern: one durable source of truth for phase/tasks/checks. |
| **D-8** | **Verification is enforced by a Stop/SubagentStop hook** (`verify-gate.sh`) — "no stop before green". | The agent cannot end its turn while a phase gate is red. Exit-2 / `{"decision":"block","reason":…}` re-injects a continuation prompt. |
| **D-9** | **All destructive-op denial lives in one PreToolUse hook** (`safety-guard.sh`). | Single choke point. Fail-**closed** on a matched dangerous pattern; fail-**open** on a parse error (never brick a session because `jq` choked). |
| **D-10** | Headless safety = **PreToolUse allow-list + `permissions.allow`**, never a global `--dangerously-skip-permissions`. | `PermissionRequest` does not fire in headless (`-p`). PreToolUse deny runs *before* permission-mode, so it blocks even under skip-permissions and can only tighten, never loosen. Also guards the `curl … | bash` RCE/prompt-injection vector. |
| **D-11** | Observability now = **PostToolUse NDJSON emitter**; SSE + SQLite + dashboard deferred. | `emit-event.sh` writes `events.ndjson` (and optionally POSTs to `$AGENTIC_SSE_URL`). Rich dashboard is M3. |
| **D-12** | **Git checkpoint after every phase and every green task**; the *only* rollback is revert-to-last-green. | Marker `[agentic:ckpt]`. Ties to `I-5`. No partial/dirty rollbacks. |
| **D-13** | Install/update/uninstall via `bin/*.sh` with `--target` (default `~/.claude`) and `--mode {symlink|copy}`. | Symlink mode for live editability during development; registers the local marketplace in settings. |
| **D-14** | The **PM outer loop is deterministic shell** spawning fresh `claude -p` per change; adaptivity comes from *periodic bounded compaction*, never a persistent session. | This is the structural answer to context bloat. Ties to `I-1`. |

---

## 4. Invariants (`I-*`)

Decisions can be revisited; invariants are load-bearing. If any of these is violated, the system is
unsafe or unsound, not merely suboptimal. `I-1`…`I-7` are the ones an engineer run must never break;
`I-8`…`I-11` are system-wide.

| ID | Invariant |
| --- | --- |
| **I-1** | The PM control loop **MUST be deterministic shell**. LLM work happens only in **ephemeral sub-steps with fresh context**, and **every per-iteration read MUST be bounded** — never load full `progress.json` history, full `openspec/specs/`, or an unbounded `git log`. Load a pending slice + a compact rollup only. |
| **I-2** | **Every destructive operation passes through `safety-guard.sh` (PreToolUse).** A matched dangerous pattern fails **closed** and cannot be loosened by any permission "allow". |
| **I-3** | **No agent stops before the current phase's gate is green** (`verify-gate.sh`). Stopping red is not an option the model can take. |
| **I-4** | **Engineer state is ephemeral.** It lives in the worktree (`.agentic/`) and is deleted with the worktree at P5. Nothing engineer-scoped persists outside the worktree. |
| **I-5** | **The only rollback mechanism is `git reset --hard` to the last green checkpoint.** No hand-rolled partial reverts. |
| **I-6** | **While a feature worktree is active, all writes stay inside it.** The single exception is durable OpenSpec artifacts under `openspec/` (mode=auto). |
| **I-7** | **Verification is real.** Gates run the project's *actual* fast (lint/typecheck) and large (test/e2e) commands. An agent never self-asserts "tests pass" in place of running them. |
| **I-8** | **Hooks are fast and observers are fire-and-forget.** Target < ~100 ms; PostToolUse always exits 0 and never blocks the agent. Slow/failed observers must not stall the pipeline. |
| **I-9** | **Plugin components resolve paths via `${CLAUDE_PLUGIN_ROOT}`.** No hard-coded install locations. A `CLAUDE.md` *inside* a plugin is ignored by Claude Code and must not be relied on. |
| **I-10** | **The target project's own guidelines win.** Its `CLAUDE.md` / rules (injected at SessionStart by `session-bearings.sh`) take precedence over the plugins' defaults. |
| **I-11** | **Durable, cross-feature state is OpenSpec's responsibility** (`openspec/specs/` as source of truth + `changes/archive/` as history). The engine never invents a parallel long-term store. Pairs with `I-4`. |

---

## 5. The nine harness components → concrete mechanism

The "no SDK" constraint means each classic harness component is built by hand. This table is the
contract between the abstract harness model and the files in this repo.

| # | Harness component | How it is realized here |
| --- | --- | --- |
| 1 | **Orchestration loop** | `agentic-engineer` SKILL (orchestrator SOP, phases P0–P5) for the inner loop; `pm-runner.sh` deterministic shell for the outer loop. |
| 2 | **Tools** | Specialized **subagents** dispatched via the `Task` tool; `agentic-core/bin/` wrappers on PATH (`agentic-state`, `agentic-checkpoint`, `agentic-profile`); superpowers skills used inside subagents. |
| 3 | **Memory / durable state** | `.agentic/state.json` for within-feature truth (`feature_list.json` role); **OpenSpec** `specs/` + `changes/` for cross-feature durable memory (`I-11`). |
| 4 | **Context management** | Fresh ephemeral `claude -p` per change (PM); bounded per-iteration reads (`I-1`); `get-bearings` on SessionStart; worktree isolation. Correctness never depends on compaction. |
| 5 | **Verification loops** | `verify-gate.sh` (Stop/SubagentStop, block-until-green) plus a dedicated **`qa`** subagent that authors test files and runs the *real* fast (lint + typecheck + component test) and large (full suite) project commands (`I-7`). |
| 6 | **State persistence** | `state.sh` (JSON CLI) + `checkpoint.sh` git checkpoints after each phase and green task (`D-12`). |
| 7 | **Error recovery** | `revert-last-green` checkpoint (`I-5`); bounded retries in P2; runaway guard `AGENTIC_GATE_MAX` (default 25) → sets `needs_human`; PM `failed` bucket + escalation. |
| 8 | **Safety enforcement** | `safety-guard.sh` (PreToolUse deny, fail-closed, `I-2`) + headless allow-list model (`D-10`). |
| 9 | **Lifecycle management** | P5 cleanup: remove worktree + ephemeral state (`I-4`); best-effort `WorktreeRemove` event; PR/merge handoff back to PM in `auto`. |

---

## 6. The engineer pipeline (inner loop)

Orchestrated by `packages/agentic-engineer/skills/agentic-engineer/SKILL.md`. The orchestrator dispatches
subagents; it does not write feature code itself. Per-role model/effort is chosen for cost and quality:

| Phase | Subagent | Model / effort | Tools | Purpose |
| --- | --- | --- | --- | --- |
| **P0 Worktree** | `worktree` | `haiku` / low | Bash, Read | Create isolated worktree on a new branch, run project setup, verify a clean baseline. Returns `WORKTREE_PATH`. Mechanical → cheapest model. |
| **P1 Plan** | `planner` | `opus` / high | Read, Grep, Glob, Write, Bash | Interactive: Socratic brainstorm → specs + fine-grained plan. Auto: read the OpenSpec change, write `assumptions.md` for gaps, then the plan. Detect and record `verify_cmds.fast` / `.component` / `.large`. Register each task. Design quality is set here → best model. |
| **P2 Execute** | `executor` | `sonnet` / medium | Read, Grep, Glob, Edit, Write, Bash | Implement the plan **one task at a time** (feature code only). After each task, hand off to `qa` for tests + fast verify. Throughput work → balanced model. |
| **P2 (per task) & P3 QA** | `qa` | `sonnet` / medium | Read, Grep, Glob, Edit, Write, Bash | **Owns tests + verification.** Per task (**FAST**): write/update the component test for the task, then run **lint + typecheck + component test** (component only if the project configures it); green → checkpoint, red → route the fix (test bug → `qa` fixes; impl bug → back to `executor`). At **P3 (LARGE)**: ensure integration/e2e tests exist, then run the full suite. No LLM judgment substitutes for running the real commands (`I-7`); fail → back to P2, `revert-last-green` if the tree is broken. |
| **P4 Review** | `reviewer` | `opus` / high | Read, Grep, Glob, Bash (**no Edit/Write**) | Two-stage review (spec compliance, then code quality). Reports only. `changes_requested` → back to P2. Read-only by design. |
| **P5 Lifecycle** | *(orchestrator)* | — | — | Interactive: summarize and stop for the human to merge. Auto: open PR / merge on green, then hand control back to PM. Remove the worktree and its `.agentic/` state (`I-4`). |

State transitions are recorded via `agentic-state` (`phase`, `task-add/task-set`, `check-set`), and each
phase/green task is `agentic-checkpoint`-ed. If `agentic-state get needs_human` is `true` (verify-gate
escaped a runaway loop), the orchestrator stops and surfaces the blocking reason instead of retrying.

**Separation of duties in P2/P3:** `executor` writes *feature* code; `qa` writes *test* code and runs
verification. **FAST** (per task, the P2 gate) = lint + typecheck + **component test** (the component
step is included only when the project configures component/unit testing). **LARGE** (the P3 gate) = the
full suite: lint + typecheck + component + integration + e2e, as the project provides. `checks.fast`
stays green only when every FAST step passes.

### Mode differences

| Aspect | `interactive` | `auto` (headless, PM-driven) |
| --- | --- | --- |
| Input source | Free-form human request | `--change <id>` → `openspec/changes/<id>/` is the source of truth |
| P1 brainstorming | Yes (Socratic, with the human) | No — read the change; write `assumptions.md` for gaps |
| Plan approval (P1→P2) | **Stop for human approval** | Proceed directly |
| Human pauses | Allowed at gates | Never pause for input |
| P5 handoff | Summarize, stop for human merge | PR/merge on green, return control to PM |
| Permissions | Interactive permission prompts | PreToolUse allow-list + `permissions.allow` only (`D-10`) |

---

## 7. The management loop (outer loop) — M2

Deterministic shell in `packages/agentic-management/bin/pm-runner.sh` (currently a **skeleton**). The
loop holds ~0 context; each engineer run is a throwaway `claude -p` process.

Sketch of one iteration (all reads bounded, `I-1`):

1. **BA sync** (only if source docs changed): `agentic-ba` regenerates `openspec/changes/` proposals,
   each carrying **testable acceptance criteria** — the target the engineer's `qa` subagent turns into
   tests.
2. **Select** the next change deterministically: dependency order + priority, skipping `done`/`failed`
   recorded in `openspec/.pm/progress.json`.
3. **Dispatch** a fresh ephemeral engineer:
   `claude -p "/agentic-engineer:engineer --change <id> --mode auto" --output-format stream-json`.
   Context is discarded when the process exits. (Inside that run, `qa` writes tests and drives FAST/LARGE
   verify — but to PM it is still one throwaway process.)
4. **Archive + record**: gate on the engineer's *actual* success signal from
   `openspec/.pm/outcomes/<id>.json` (status + `verification.large_passed`, not the process exit code) →
   `openspec archive <id>` → append to `progress.json`. Archiving therefore guarantees the change was
   **built and QA-verified** (tests authored + LARGE green); those tests ship with the feature in the repo.
5. **Periodic compaction**: every K iterations, run *one* bounded `claude -p` that reads a compact rollup
   + recent outcomes and rewrites a short re-prioritized plan. Adaptive intelligence, zero accumulation.

Why bloat is structurally impossible here, and where the *real* limits are:

- **Not context.** Change #1 and change #100,000 have identical footprint; the shell loop keeps 0 context
  and state lives in files. OpenSpec's `archive/` keeps the *active* `changes/` dir small automatically.
- **The real ceilings at thousands of tickets are cost, wall-clock time, and error accumulation.** N
  sequential `claude -p` runs cost real money and real hours, and one bad ticket may need a human. Budget
  and escalation policy — not context — are the things to engineer next (see §9 M2 TODOs).

**Per-iteration read discipline (the three bloat sources and their bounds):**

| Source | Risk after 1000 tickets | Bound |
| --- | --- | --- |
| `progress.json` | 1000 entries; loading the whole file re-reads 999 stale ones each iteration | Load only the pending slice + a compact rollup; append-only history is never re-read wholesale |
| `openspec/changes/` | grows with pending work | `openspec archive` moves finished changes to `changes/archive/`; iterate only over *active* changes |
| `openspec/specs/` | genuinely grows (accumulates system-wide spec) | BA/engineer load only the slice relevant to the current change; never the whole spec; `git log -n <small>` only |

---

## 8. Repository layout

```
agentic-workflow/
├── plan.md                              ← this file (read first)
├── README.md                            ← install / quickstart / deps
├── CLAUDE.md                            ← context for working ON the tooling (repo root)
├── .claude-plugin/marketplace.json      ← catalog of the 3 plugins
├── bin/
│   ├── install.sh                       ← --target (default ~/.claude), --mode {symlink|copy}
│   ├── update.sh
│   └── uninstall.sh                     ← preserves user data
└── packages/
    ├── agentic-core/                    ← shared kernel (required by the others)
    │   ├── .claude-plugin/plugin.json
    │   ├── hooks/
    │   │   ├── hooks.json               ← registers SessionStart/PreToolUse/PostToolUse/Stop/SubagentStop
    │   │   ├── session-bearings.sh      ← SessionStart: get-bearings + inject project rules (I-10)
    │   │   ├── safety-guard.sh          ← PreToolUse: destructive-op deny, fail-closed (I-2, D-9)
    │   │   ├── emit-event.sh            ← PostToolUse: NDJSON event stream, fire-and-forget (D-11)
    │   │   └── verify-gate.sh           ← Stop/SubagentStop: block-until-green + runaway guard (I-3, D-8)
    │   ├── lib/
    │   │   ├── state.sh                 ← .agentic/state.json CLI (feature_list.json role, D-7)
    │   │   ├── checkpoint.sh            ← git checkpoint/revert-last-green (D-12, I-5)
    │   │   └── profile.sh               ← direnv / CLAUDE_CONFIG_DIR detection
    │   ├── bin/                         ← PATH wrappers: agentic-state, agentic-checkpoint, agentic-profile
    │   └── observability/README.md      ← M3 placeholder
    ├── agentic-engineer/                ← M1 pipeline
    │   ├── .claude-plugin/plugin.json
    │   ├── skills/agentic-engineer/SKILL.md   ← orchestrator SOP (P0–P5)
    │   ├── agents/                      ← worktree, planner, executor, reviewer
    │   ├── commands/engineer.md         ← /agentic-engineer:engineer slash command
    │   └── hooks/engineer-hooks.json    ← best-effort WorktreeRemove lifecycle event
    └── agentic-management/              ← M2 (stub)
        ├── .claude-plugin/plugin.json
        ├── skills/agentic-ba/SKILL.md   ← docs → OpenSpec proposals (stub)
        ├── skills/agentic-pm/SKILL.md   ← deterministic loop contract (stub)
        └── bin/pm-runner.sh             ← deterministic outer-loop skeleton
```

Plugin structure facts this layout depends on: `.claude-plugin/plugin.json` +
`.claude-plugin/marketplace.json`; component dirs (`commands/`, `agents/`, `skills/<name>/SKILL.md`,
`hooks/hooks.json`, `bin/`) live at the **plugin root**; a plugin's own `CLAUDE.md` is ignored (`I-9`);
hook commands use `${CLAUDE_PLUGIN_ROOT}`; `bin/` is auto-added to the Bash PATH.

---

## 9. Milestones & acceptance criteria

### M0 — Scaffold ✅ (done)
All files above exist. Kernel hooks/libs written, engineer pipeline scaffolded, management stubbed,
install/update/uninstall present. **Not yet wired or tested on a real repo.**

### M1 — Engineer works end-to-end (current focus)
**Definition of done:**
- Installs cleanly via `bin/install.sh --mode symlink`; `/agentic-engineer:engineer` is available after
  `/reload-plugins`.
- Drives a **real feature on a real repo** in **both modes**:
  - `interactive`: brainstorm → plan → *human approves* → execute → verify → review → human merges.
  - `auto`: given an OpenSpec change, runs to green (or `needs_human`) with no human input.
- **Hooks demonstrably enforce**: `safety-guard` blocks a destructive command even under
  skip-permissions; `verify-gate` refuses to stop with unverified tasks / red fast verify / failed large
  verify / `changes_requested`.
- **Checkpoints + rollback** work: a broken tree can `revert-last-green` and recover.
- **State lifecycle is clean**: `.agentic/state.json` is created in the worktree and removed at P5;
  nothing engineer-scoped leaks outside (`I-4`).
- Events land in `events.ndjson`.

**Open work for M1:**
- Wire and smoke-test on a real repository (the big one).
- Deepen `verify-gate.sh`: the phase/gate state machine is currently minimal — harden edge cases
  (mid-task stops, re-entry after P4→P2, per-check staleness).
- Tune `safety-guard.sh` deny patterns against false positives that would stall the pipeline.

### M2 — Management (BA + PM)
**Definition of done:**
- `agentic-ba` turns source docs/design into valid OpenSpec change proposals.
- `pm-runner.sh` fleshed out from skeleton to production loop:
  - Real **selection**: dependency graph + priority; skip `done`/`failed`.
  - **`progress.json` schema** finalized; bounded reads only (`I-1`).
  - **Success-signal gating** (check `needs_human` / verify state, not just process exit).
  - **Periodic compaction** step (every K iterations).
  - **Cost + wall-clock budgeting** and an **escalation policy** on `needs_human`.
- Runs a multi-change backlog to completion with flat context footprint.

### M3 — Observability
- SSE + SQLite event bus consuming `events.ndjson`.
- Vite + React dashboard with token/cost visualization per run and per role.

---

## 10. Risks & mitigations

| Risk | Mitigation |
| --- | --- |
| **Context bloat over thousands of tickets** | Structurally prevented by `I-1`/`D-14`: deterministic shell loop + ephemeral `claude -p` + bounded reads + OpenSpec archiving. |
| **Real scale ceiling is cost / wall-clock / error accumulation** | M2 adds budgeting + escalation. Track cost per run via `emit-event.sh`; stop-or-escalate policy on `needs_human`. |
| **Claude Code bug #44385** (`model:` frontmatter silently ignored) | Pin the model **explicitly at each dispatch** (`D-6`), not only in frontmatter. |
| **Stop hook fires at every response end**, not just at task completion | `verify-gate.sh` only blocks when state shows a pending gate; it tolerates mid-task stops (`I-3`). |
| **Headless has no permission prompt** | Allow-list model (`D-10`); never global skip-permissions; PreToolUse deny is the backstop (`I-2`). |
| **Prompt injection via untrusted docs** (e.g. `curl … | bash`) | `safety-guard.sh` denies the RCE-pipe pattern; writes confined to the worktree (`I-6`). |
| **Runaway verify loop** | `AGENTIC_GATE_MAX` (default 25) → set `needs_human`, stop blocking, escalate. |
| **Observer hooks slowing the agent** | Observers are fire-and-forget, always exit 0, target < ~100 ms (`I-8`). |
| **Compaction degradation** (summary-of-summary) | Correctness never relies on compaction; durable truth is JSON/OpenSpec files re-derived each run. |

---

## 11. Dependencies

- **Claude Code** (Node.js runtime) with plugin + hooks support.
- **`obra/superpowers`** — engineering skills the subagents invoke (`D-3`).
- **`Fission-AI/OpenSpec`** — spec/ticket substrate (`D-4`), primarily M2.
- **`jq`** (required), **`git`** (required).
- **`direnv`** (optional) — `CLAUDE_CONFIG_DIR` profiles for dedicated CLI-account isolation.
- A Claude subscription and/or API access for `claude -p` runs.

---

## 12. Conventions

- **Language:** English for all code, scripts, skills, agent prompts, and docs. (Maintainer conversation
  may be Vietnamese; artifacts stay English.)
- **Shell:** POSIX-ish bash; require `jq`. Hooks fast and, where they are observers, fire-and-forget.
- **Paths in hooks:** always `${CLAUDE_PLUGIN_ROOT}`; never hard-code install locations.
- **Naming:** kebab-case for files, directories, plugins, skills, agents.
- **Don't reimplement** what superpowers or OpenSpec provide — wrap them.
- **Dev loop:** test a plugin without installing via `claude --plugin-dir packages/<name>`; after editing
  agent/hook files on disk run `/reload-plugins`; validate JSON with
  `jq . packages/*/.claude-plugin/plugin.json packages/*/hooks/*.json`. Expect subagent-driven runs to
  cost meaningfully more tokens than a single-agent session.

---

## 13. Immediate next steps

Pick the next fork:

1. **Wire + smoke-test the engineer on a real repo** (validates M1 end-to-end; highest signal).
2. **Deepen `verify-gate.sh`** — harden the phase/gate state machine and its re-entry edges.
3. **Start `agentic-ba`** — begin M2 by generating real OpenSpec proposals from docs.

(Optional, orthogonal: render the two loop diagrams from §2 to Excalidraw for the design doc.)
