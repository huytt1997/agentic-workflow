# agentic-management — execution plan

> **Scope.** The implementation plan to take `agentic-management` from its current partial state to a
> working BA + PM system. This is narrower and more concrete than `execution-plan.md` §5 (PART III) —
> it is grounded in what is **actually on disk today** and specifies the exact contracts, files, and
> tests needed to finish. Architecture/rationale lives in `plan.md` (`D-*`, `I-*`); the master task
> IDs (`T-M1…T-M11`, `T-E8`) come from `execution-plan.md`.
>
> Convention: English artifacts, kebab-case, `jq` + `git` + `openspec` + `claude` required.

---

## 0. Current state — accurate audit (management package only)

The surprising, important fact: **`pm-runner.sh` is already ~90% implemented.** The gaps are the two
skills, the plugin manifest, and one cross-package wire on the engineer side.

| Component | On disk today | Verdict |
| --- | --- | --- |
| `bin/pm-runner.sh` | **Substantially built**: preflight, `progress.json` init, deterministic `next_change()` (deps + priority), `handle_change()` with full outcome-contract gating, budgets, retry/backoff, escalation policy, periodic compaction, dry-run | **Test + harden**, don't rebuild |
| `.claude-plugin/plugin.json` | **Missing** | Create — nothing loads without it |
| `skills/agentic-ba/SKILL.md` | **Missing** | Build — biggest greenfield piece |
| `skills/agentic-pm/SKILL.md` | **Missing** | Build — the human/agent entry point that wraps `pm-runner.sh` |
| Engineer writes `openspec/.pm/outcomes/<id>.json` | **Not wired** (engineer P5 doesn't emit it) | **Blocker** — without it, `pm-runner` sees "no outcome file" and marks every change `failed` |

**Consequence for sequencing:** the PM loop's *logic* is done, but it cannot succeed end-to-end until
(a) the engineer emits the outcome contract, and (b) `agentic-ba` produces changes with the frontmatter
the loop reads. Those two are the real work.

---

## 1. Build order (critical path)

```
 ① plugin.json ─────────────► management plugin loads at all
 ② engineer outcome wire ───► pm-runner can gate success (else every change = failed)   [engineer-side]
 ③ agentic-ba ──────────────► produces changes + acceptance criteria + depends_on/priority
 ④ agentic-pm SKILL.md ─────► entry point; documents how to run pm-runner
 ⑤ pm-runner test + harden ─► dry-run → single change → multi-change backlog
 ⑥ full-loop acceptance ────► BA → PM → engineer → archive, flat context
```

- **② is the top blocker** for any real run and is small (an engineer P5 addition). It assumes the
  engineer already runs in `--mode auto` (WS-B). If the engineer isn't proven yet, do that first.
- **③ `agentic-ba` is independently buildable/testable** (validate its output with `openspec validate`)
  without a working engineer — good parallel track.
- **⑤/⑥** need both ② and ③.

---

## 2. The contracts `pm-runner.sh` already establishes

`pm-runner.sh` is the source of truth for the integration surface. Everything else (BA, engineer,
plugin) must conform to these. Read this section as the spec the other pieces are written against.

### 2.1 `progress.json` — the PM cursor (bounded, `I-1`)

Path: `openspec/.pm/progress.json` (auto-created). Shape:

```json
{ "schema": "pm-progress/1",
  "done": [], "failed": [], "blocked": [], "cursor": null,
  "meta": { "<id>": { "attempts": 0, "last_status": "success|needs_human|failed|archive_failed",
                       "reason": "<=200 chars", "ts": "<iso8601>", "cost_usd": 0 } },
  "budget": { "cost_cap_usd": null, "wall_clock_cap_min": null, "spent_usd": 0, "elapsed_min": 0 } }
```

History is append-only per bucket; the loop only ever reads the bucket arrays + a small `meta` slice, so
footprint stays flat regardless of how many changes have completed.

### 2.2 Engineer → PM outcome contract (the wire to build in ②)

`pm-runner` reads `openspec/.pm/outcomes/<id>.json` and gates on it (never on the process exit code — a
model refusal / `needs_human` is invisible from the exit status). It passes the engineer the absolute
path via env `AGENTIC_PM_OUTCOME_FILE`. The engineer's P5 (auto mode) must write, **before** worktree
cleanup:

```json
{ "schema": "pm-outcome/1", "change_id": "<id>",
  "status": "success | needs_human | failed",
  "reason": "<blocking_reason | null>",
  "checkpoints": <int>, "pr": "<url|branch|null>", "ts": "<iso8601>",
  "verification": { "large_passed": true, "tests_written": <int>, "levels": ["component","integration","e2e"] } }
```

`pm-runner` archives **only** when `status=="success"` AND `verification.large_passed==true`. Anything
else → `blocked` (needs_human / contract violation) or `failed` (→ retry policy).

### 2.3 Change frontmatter convention (what `next_change()` reads)

`pm-runner` parses YAML frontmatter at the top of each change's `proposal.md`. `agentic-ba` **must** emit:

```markdown
---
depends_on: [other-change-id, another-id]   # optional; omit or [] if none
priority: 50                                 # optional int, default 100; lower = earlier
---
# <proposal title>
...
```

Selection is deterministic: eligible = deps all `done` and not in `done`/`failed`/`blocked` → lowest
`priority` → lowest id (lexicographic tiebreak).

### 2.4 OpenSpec surface + directory layout (verified CLI usage in `pm-runner`)

- Active changes: `openspec/changes/<id>/` (directories). Archived: `openspec/changes/archive/`.
- Archive (non-interactive): `openspec archive <id> --yes`.
- Validate (strict): `openspec validate <id> --strict`.
- The target project must have run `openspec init` first (creates `openspec/`, `specs/`).
- `openspec/` lives in the **target project**, not the monorepo (`plan.md` boundary).

> Confirm `openspec` CLI flags against the installed version before relying on them (`pm-runner` notes
> they were verified in 2026; treat as version-sensitive).

### 2.5 `pm-runner.sh` config surface (env vars — the PM's knobs)

| Env var | Default | Meaning |
| --- | --- | --- |
| `PM_ENGINEER_CMD` | `/agentic-engineer:engineer --change {id} --mode auto` | prompt to launch one engineer run; `{id}` substituted |
| `PM_MODEL` | (unset) | top-level session model (engineer pins per-subagent models itself) |
| `PM_ALLOWED_TOOLS` | `Task,Bash,Edit,Write,Read,Grep,Glob,TodoWrite` | headless allow-list (`D-10`) |
| `PM_PERMISSION_MODE` | `acceptEdits` | never `bypassPermissions`; `safety-guard` is the hard backstop |
| `PM_MAX_TURNS` / `PM_MAX_BUDGET_USD` | (unset) | per-change process caps |
| `PM_COST_CAP_USD` / `PM_TIME_CAP_MIN` | (unset) | cumulative loop caps |
| `PM_COMPACT_EVERY` | `0` | re-prioritize every K done changes (0 = off) |
| `PM_MAX_RETRIES` / `PM_BACKOFF_SEC` | `1` / `5` | retry policy on failure |
| `PM_ON_FAIL` / `PM_ON_BLOCK` | `continue` / `stop` | escalation after retries / on needs_human |
| `PM_BA_SYNC` / `PM_DOCS_GLOB` | `0` / `docs` | run BA sync when docs changed |
| `PM_DRY_RUN` | `0` | show selection/dispatch decisions without launching the engineer |

---

## 3. Workstream A — package plumbing

- **T-M12 — `.claude-plugin/plugin.json`.** Create the manifest (name `agentic-management`, description,
  version; declare dependency on `agentic-core` and `agentic-engineer`; register the `agentic-ba` /
  `agentic-pm` skills and the `bin/` dir). Mirror the structure of the other two plugins' manifests.
  Acceptance: `jq . packages/agentic-management/.claude-plugin/plugin.json` is valid; after install +
  `/reload-plugins`, the two skills are listed and `pm-runner` is on PATH.
- **T-M12b — marketplace + install.** Confirm `agentic-management` is in the root
  `.claude-plugin/marketplace.json` and that `bin/install.sh` links it. Acceptance: a clean `--target`
  install exposes all three plugins.

---

## 4. Workstream B — `agentic-ba` (docs/design → OpenSpec changes)

The biggest greenfield piece. Maps to OpenSpec **explore + propose**. It must emit changes that conform
to §2.3 (frontmatter) and §2.2's premise (testable acceptance criteria for the engineer's `qa`).

### 4.1 Design

- **Skill `skills/agentic-ba/SKILL.md`** = an orchestrator SOP that, given a docs glob, produces/updates
  OpenSpec changes. It should invoke a dedicated analysis subagent for the heavy reading/writing.
- **Subagent `agents/ba-analyst.md`** (opus / high — analysis quality matters): reads spec docs + UI
  design, writes `proposal.md` (with frontmatter), `design.md`, `tasks.md`, and `specs/` deltas per unit
  of work. Tools: Read, Grep, Glob, Write, Bash (to run `openspec validate`). Writes only under
  `openspec/` (allowed by the `I-6` OpenSpec exception).

### 4.2 Tasks

- **T-M1 — change-id convention + doc→change mapping.** Stable, kebab-case ids derived from doc
  sections; a mapping table so re-runs are **idempotent**. Acceptance: two runs over unchanged docs
  produce identical ids and no spurious new changes.
- **T-M2 — proposal generation with testable acceptance criteria.** For each unit: valid
  `proposal.md`/`design.md`/`tasks.md` + `specs/` deltas, **including concrete, verifiable acceptance
  criteria / scenarios** — the target the engineer's `qa` turns into tests (the BA↔QA closed loop).
  Emit `depends_on` + `priority` frontmatter (§2.3). Acceptance: `openspec validate <id> --strict`
  passes for every change; a human finds each proposal faithful; every change carries acceptance
  criteria concrete enough for `qa` to author tests without guessing.
- **T-M3 — update/diff on doc change.** When docs change, diff against existing changes and update only
  what moved; never silently drop scope; never touch archived changes. Acceptance: editing one doc
  section updates exactly one active change and leaves the rest (and `archive/`) untouched.
- **T-M4 — dependency + priority expression.** Ensure the frontmatter BA writes is exactly what
  `pm-runner`'s `next_change()` parses (`depends_on: [..]`, `priority: <int>`). Acceptance: a two-change
  dependency authored by BA causes `pm-runner --dry-run` to select them in topological order.
- **T-M-BA-skill — `SKILL.md` + invocation shape.** The skill must be runnable both interactively and
  headlessly, matching how `pm-runner`'s `maybe_ba_sync` calls it: a `claude -p "Use the agentic-ba
  skill to sync OpenSpec changes from the project docs under: <glob> …"` with `--allowedTools
  "Task,Read,Write,Bash,Grep,Glob"`. Acceptance: that exact command produces/updates valid changes.

---

## 5. Workstream C — `agentic-pm` skill (wraps `pm-runner.sh`)

`pm-runner.sh` is the engine; `agentic-pm` is the operator-facing skill that explains and launches it.

- **T-M13 — `skills/agentic-pm/SKILL.md`.** Document: prerequisites (`openspec init` in target; BA has
  produced changes; the outcome wire exists); the config surface (§2.5); how to do a **dry-run first**;
  how to interpret the summary (`done`/`blocked`/`failed`, spend, time); where state lives
  (`openspec/.pm/`). It should also describe when to run BA sync vs. rely on `PM_BA_SYNC`. Acceptance: a
  new operator can go from a fresh target project to a running loop using only this skill.
- **T-M13b — a thin `commands/` entry (optional).** A `/agentic-management:run` slash command that
  shells out to `pm-runner.sh` with sensible defaults, for parity with the engineer's slash command.
  Acceptance: the command starts a dry-run by default and prints next steps.

---

## 6. Workstream D — engineer-side outcome contract (cross-package, the missing wire)

This lives in `agentic-engineer` but is the gating dependency for management. It is the outcome half of
master task **T-E8**.

- **INT-1 — write the outcome file in P5 (auto mode).** In the engineer's P5, when `--mode auto`, read
  `AGENTIC_PM_OUTCOME_FILE` (fall back to `openspec/.pm/outcomes/<change_id>.json`) and write the §2.2
  record **before** removing the worktree. Populate `status` from the run result (`success` only if
  `verify-gate` let it finish green; `needs_human` if the runaway guard tripped; else `failed`),
  `verification.large_passed` from `checks.large`, `tests_written` / `levels` from what `qa` produced,
  and `pr`/`checkpoints`. Acceptance: after an auto engineer run, a well-formed outcome file exists and
  `pm-runner`'s `handle_change()` classifies it correctly (success→archive, needs_human→blocked).
- **INT-2 — env passthrough sanity.** Confirm the engineer run inherits `AGENTIC_PROJECT_ROOT` and
  `AGENTIC_PM_OUTCOME_FILE` from `pm-runner`, and that its own `openspec/` operations target the same
  project dir. Acceptance: the outcome file lands where `pm-runner` reads it.

---

## 7. Workstream E — `pm-runner.sh` finish + harden

Mostly verification of already-written logic; a few edges to close.

- **T-M5/T-M6/T-M7/T-M8/T-M9/T-M10 — verify the implemented behavior** (selection, ephemeral dispatch,
  outcome gating, retry/escalation, compaction, budgeting) against real runs. These are **coded**; the
  task is to prove them, not write them. Acceptance: each behavior demonstrated by a targeted test
  (§8).
- **T-M11 — bounded-read discipline audit.** Confirm no unbounded reads crept in: `progress.json`
  buckets/`meta` slice only, active-changes listing (not `archive/`), compaction over the **rollup**
  only. Acceptance: review checklist passes; compaction input size is independent of `done` count.
- **T-M-E1 — edge hardening.** Confirm: stale outcome files are removed before each run (they are);
  `set -euo pipefail` doesn't abort mid-loop on an expected non-zero (engineer failures are caught with
  `set +e` around the dispatch — verify); `archive` failure routes to `blocked` (it does); missing
  `openspec`/`jq`/`claude` preflight-fails cleanly. Acceptance: a forced failure in each spot yields the
  intended verdict, not a crash.
- **T-M-E2 — observability tie-in.** The per-change NDJSON log (`openspec/.pm/logs/<id>.<ts>.ndjson`)
  and the `total_cost_usd` extraction already feed budgeting; confirm these align with `agentic-core`'s
  event stream so the future dashboard (M3) can consume both. Acceptance: cost per change is recorded in
  `progress.json.meta`.

---

## 8. Testing & acceptance

Build a small **fixture target project** (its own `openspec/`, a couple of trivially-buildable changes)
and drive the loop in stages:

1. **Dry-run selection** (`PM_DRY_RUN=1`): author 3 changes with a dependency (via BA or by hand) →
   confirm `pm-runner` selects them in topological/priority order and would dispatch the right prompt.
2. **Single change, real** (engineer + INT-1): one change to green → outcome file written →
   `openspec archive` runs → `progress.done` updated → tests committed in the target repo.
3. **Multi-change backlog** (≥3, with a dep): runs to completion, archiving each, **flat context
   footprint** (change #1 == change #N). Verify `openspec/changes/` shrinks as `archive/` grows.
4. **Block path**: force a `needs_human` (or a `success` with `large_passed:false`) → routed to
   `blocked`, **not** archived; `PM_ON_BLOCK=stop` halts with the reason surfaced.
5. **Fail path**: force a process failure → retry with backoff up to `PM_MAX_RETRIES`, then `failed`
   per `PM_ON_FAIL`.
6. **Budget cap**: set a low `PM_COST_CAP_USD` → loop stops cleanly with a summary.
7. **BA idempotence + update**: re-run BA on unchanged docs (no new changes); edit one doc section
   (exactly one change updates).
8. **Compaction**: set `PM_COMPACT_EVERY=2` → a bounded re-prioritization runs after every 2 done, input
   size independent of history.

**Definition of done (management):** a maintainer points `agentic-ba` at a target project's docs, runs
`pm-runner.sh`, and a backlog of changes is built, QA-verified, and archived autonomously — safely, with
budgets respected and no long-lived agent session.

---

## 9. Open decisions to confirm

1. **`plugin.json` dependency declaration** — does the marketplace/install flow enforce the
   core+engineer dependency, or is it advisory? (T-M12)
2. **BA subagent model** — opus/high for proposal analysis (default) vs. sonnet to cut cost. (T-M2)
3. **`depends_on`/`priority` location** — frontmatter in `proposal.md` (current `pm-runner` assumption)
   vs. a separate manifest. If changed, update `pm-runner`'s parser. (T-M4)
4. **PM policy defaults** — `PM_MAX_RETRIES`, `PM_ON_FAIL`/`PM_ON_BLOCK`, `PM_COMPACT_EVERY`, budget
   caps for the intended workloads. (T-M8/T-M9/T-M10)
5. **OpenSpec CLI version** — confirm `openspec archive --yes` / `validate --strict` against the
   installed version. (§2.4)
6. **BA↔spec granularity** — one OpenSpec change per doc section vs. per feature; how spec deltas map to
   `qa` test levels. (T-M2)

---

## 10. Suggested first sprint (management)

Smallest sequence to a **provably working loop**:

1. **T-M12** — write `plugin.json` so the package loads.
2. **INT-1** — wire the engineer to emit the outcome contract (unblocks all gating).
3. **T-M1 + T-M2 + T-M-BA-skill** — stand up `agentic-ba`: docs → valid changes with acceptance criteria
   + `depends_on`/`priority`, validated by `openspec validate`.
4. **Test steps 1–2** — dry-run selection, then one real change end-to-end (BA → PM → engineer →
   archive).
5. Then **T-M13** (agentic-pm skill) + **test steps 3–8** to prove the full backlog, block/fail/budget
   paths.

`pm-runner.sh` is already carrying most of PART III — the leverage now is BA (③) and the engineer
outcome wire (②). Start there.
