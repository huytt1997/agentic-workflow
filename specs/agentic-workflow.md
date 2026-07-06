# plan.md — `agentic-workflow`

> Implementation contract for the first build session. The invariants in §3 and the decision log in §4 govern every file; if a code choice contradicts one, the choice is wrong. Where a decision encodes a non-obvious trade-off, the rationale is given so it isn't "fixed" back. Sections marked `SPIKE` must be resolved before their dependent step.

---

## 1. Overview & references

A TypeScript monorepo that automates software workflows on top of the Claude Agent SDK. Two models ship first:

- **`harness-engineering`** — turns Claude Code into a senior engineer that, given one feature, autonomously runs **brainstorm → plan → execute → verify → review → merge** and self-verifies against machine-checkable acceptance until done. Usable **two ways**: as an `agentic-engineer` **skill** inside a Claude Code session, and as an `agentic-engineer` **CLI** for headless runs.
- **`project-management`** — reads docs + design, produces/maintains `/tickets` (+ OpenSpec), then drives the whole project ticket-by-ticket by invoking the harness. **CLI only** (no skill).

References that shape the design:

- **Agent SDK** `@anthropic-ai/claude-agent-sdk` (verified v0.3.186). `query({ prompt, options })`; sessions via `resume`; subagents via `agents`; hooks (`PreToolUse`/`PostToolUse`/…); permissions via `canUseTool` + `permissionMode`; `settingSources` loads `CLAUDE.md`/rules **relative to `$CLAUDE_CONFIG_DIR`**.
- **Long-running harness pattern** (Anthropic, "Effective harnesses for long-running agents"): initializer + incremental coding agent; `feature_list.json`-style ledger; progress file + git as recovery; end-to-end browser verification; "get up to speed" routine each session.
- **Nested subagents:** Claude Code caps nesting at **5 levels**; deep/wide trees cost ~7× tokens. Each fresh top-level `query()` resets nested depth to 0 (§16).
- **Account model:** the SDK reads user-scope settings **and credentials** from `$CLAUDE_CONFIG_DIR` (default `~/.claude`). This selects *which Claude account* a run uses (§5.3).

---

## 2. Goals

- Given one feature, the harness drives it to `merged` (or `paused`/`failed` with a clear reason) with **no silent stalls**, streaming thinking, edits, tools, the subagent tree, and a running token budget.
- Every acceptance criterion is **verified by code** (or explicitly `manual`, attested by the reviewer) before merge — coverage by a task is not enough.
- Runs are **safe on untrusted inputs** (Jira/Figma/web/repo-supplied MCP): no self-granted permissions, no credential exposure to agent shells, no auto-trust of repo-supplied tool servers.
- Runs are **crash-isolated**: one poisoned feature cannot take down a multi-hour batch.
- Model, effort, and account are **operator-tunable** without editing code.

---

## 3. Architectural invariants

Eight sentences. Every file obeys them.

1. **Process isolation per feature.** PM invokes the harness by **forking a child process** that opens a **new top-level** `query()`. Depth resets to 0 *and* a crash/OOM in one feature cannot kill the batch. Events cross the boundary as JSON over IPC. (An in-process `runFeature()` exists for dev/debug only.)
2. **Git is the source of truth.** `.harness/` is recoverable cache. Reconciliation order on resume: **git > gate result > acceptance verdict > `state.json`**.
3. **Gates are code; the controller is the arbiter.** Verification runs via `child_process` + exit codes read by the controller. Agents never self-report pass/fail and never write verdicts. Every acceptance binds a machine-checkable verify handle (or is `manual`).
4. **Ephemeral harness memory ⟂ durable PM memory.** `.harness/` persists across one feature's phases, then is deleted on merge. Cross-feature state lives in PM (OpenSpec + tickets + `progress.json`).
5. **Park-then-continue.** Under `--auto`, a permission block, an abort, or a budget exhaustion is **not** bypassed and is **not** a failure: the harness returns `paused`; PM parks the ticket, notifies, and continues to the next runnable ticket.
6. **No silent stall.** A dual watchdog (idle-event **and** hard per-tool/phase ceiling) guarantees every run progresses, pauses with a reason, or is killed with a reason. A hung tool can never disable the watchdog.
7. **Least privilege for agent shells.** The executor's `Bash` runs with a scrubbed environment (no credential vars, restricted `PATH`) plus hard-boundary `PreToolUse` hooks as defense-in-depth. Repo-supplied MCP servers are not auto-trusted.
8. **Auto posture ≠ bypass.** "Auto" phases (executor/verify/review) skip interactive prompts for their *sanctioned* tool surface only; out-of-allowlist actions still escalate (ask interactively / pause under `--auto`), and the hard hooks always apply.

---

## 4. Decision log

| #   | Decision | Rationale / trade-off |
| --- | --- | --- |
| D1  | PM→harness = **`child_process.fork` per feature**; `HarnessEvent` over IPC; in-process `runFeature()` is a dev/library mode | crash isolation for long unattended runs; depth reset holds in **any** process (`query()` is top-level), so isolation costs nothing in depth; child inherits `CLAUDE_CONFIG_DIR` |
| D2  | Scope is intrinsic to the model; `--target` overrides the **skill** install dir; the **bin is global** | harness skill→`<target>` (default `~/.claude`); bins on `PATH` |
| D3  | The `worktree` phase runs via a **dedicated Haiku subagent** that drives a controller-implemented `worktree` tool; the controller computes the base and **validates** the resulting worktree state | uniform observability (worktree shows in the tree with its own token cost) + cheap model + a place for enter-vs-create judgment, while the git mutation stays deterministic controller code — the subagent cannot branch off the wrong base |
| D4  | Worktree **base = the project's current branch** (`git symbolic-ref --short HEAD`); **never** defaults to `main`/`master`/`staging`; detached HEAD ⇒ `DetachedHeadError` (checkout a branch or pass `--base`) | feature branches off wherever the operator actually is, not an assumed trunk |
| D5  | e2e = **Playwright** | webServer auto-detected; JSON reporter parsed for per-test results |
| D6  | Auto-detect target monorepo config (turbo/nx/pnpm/single) | no hand-passed config |
| D7  | **Per-role permission posture.** `executor-lead`, `executor-leaf`, `reviewer`, and the `verify` gate run in **auto** posture (non-interactive for the sanctioned surface); `brainstorm`/`planner` are interactive-capable; `worktree`/`ingest` are mechanical | the "do the work" phases must not pester during autonomous runs; auto ⊆ allowlist, not `bypassPermissions` (invariant 8) |
| D8  | **Per-role model + effort overrides** for **both** models via CLI flags (`--model role=val`, `--effort role=val`, `--models-file`); an override **pins** the role (disables its ladder unless a comma-list is given) | tune cost/quality per run without touching code; comma-list preserves escalation ladders |
| D9  | `--auto` permission block = **pause + escalate** (`status:'paused'`) | never self-grant |
| D10 | Reviewer: Bash + Playwright, **no Edit/Write**, **detached review worktree**, `PreToolUse` denylist, snapshot before/after → `diffTracked(sandbox)` ⇒ review-invalid; cap = **1** | sandbox is the real guarantee; still leaking after 1 retry ⇒ config error, fail fast |
| D11 | `merge` integrates to `feature.base` only; **never pushes `main`** | PM decides further; standalone user merges base→main |
| D12 | Verify = **two tiers**; completion runs a **full-scope** `typecheck→lint→unit` sweep *before* `e2e→build` | catch deps missed by affected-only per-commit |
| D13 | Reverse-dependents in per-commit affected = **on** (pnpm/single; turbo/nx self-compute) | safety over speed |
| D14 | Task stuck after `MAX_TASK_ATTEMPTS` ⇒ **FAIL** (no auto re-plan) | honest failure |
| D15 | Remediation tasks = **Sonnet**; **verify is the sole arbiter** of "done" | single source of truth |
| D16 | Split `acceptance.json` (frozen + hash) from `acceptance-state.json` (verdict, controller-only) | agent cannot tamper the spec |
| D17 | `AcceptanceTamperError` (hash mismatch) ⇒ **FAILED hard** | tampered ⇒ verdict untrustworthy |
| D18 | Resume always `discardWorking` (drop uncommitted crash work) | only green commits are trusted |
| D19 | `integrate` diverged ⇒ **auto-rebase + rerun completion**, bounded by `MAX_REBASE_ATTEMPTS`; exhausted ⇒ `paused` | PM is automatic; only the tip's greenness is invariant |
| D20 | `integrate` base-checked-out ⇒ treat as **merged**, keep `harness/<id>` branch, remove worktree | standalone case; user ff's manually |
| D21 | Commit identity = **fixed bot id** | predictable history attribution |
| D22 | Plan **coverage** rule = on (every acceptance carried by ≥1 task) | forces complete plans; verification is D26 |
| D23 | OpenSpec bridge = **filesystem** `openspec/changes/<id>/` in v1, no CLI shell-out until verified | isolated behind `OpenSpecBridge` |
| D24 | Integration = **sequential build-up** (ticket N builds on integrated N-1), **best-effort** under park-then-continue | a parked N is skipped, so integration order may differ from ticket order; only the integration tip is gate-checked |
| D25 | Reporter JSONL in `harness-home/runs/<runId>/`, retention **50** | survives teardown for post-hoc debug |
| D26 | Every acceptance binds a **machine-checkable verify handle**: `{e2e,tag} \| {unit,filter} \| {cmd,run} \| {manual}`. `validatePlan` **rejects** handle-less acceptance; completion sets each verdict + `verdictSource`; `manual` ⇒ reviewer attestation; `merge` requires every non-manual = pass | closes the coverage≠verification gap; the acceptance apparatus actually gates merge for the full criterion set |
| D27 | Watchdog = **idle-event timer + hard per-tool/phase ceiling**; every gate subprocess gets an explicit `timeout`; breach ⇒ kill ⇒ `paused` with reason | a hung tool must not pause the watchdog forever |
| D28 | **Abort** (`AbortError`) and **budget exhaustion** ⇒ `paused` (resumable; reason carries used/ceiling), **not** `failed` | Ctrl-C to inspect must be resumable; budget = bump-and-resume, not lose N commits |
| D29 | Repo-supplied (project-scope) MCP servers require **first-sight confirm/allowlist**; not auto-trusted | a cloned untrusted repo can ship `.mcp.json` → attacker tool descriptions in context |
| D30 | `reconcileAcceptance` = **full recompute** over handles present in the run (pass **and** fail) | catches regressions of previously-green acceptance |
| D31 | **Orphan worktree GC** on startup (`prune` + remove crashed `harness/<id>` and `.harness/review`) | crash-left dirs make `prune` a no-op and re-add conflict |
| D32 | PM emits a **project-level event stream**; all termination bounds live in `core/config` (env-overridable) | dashboard needs a project timeline; one place for every cost/termination knob |
| D33 | Executor `Bash` = **scrubbed env + restricted `PATH`** (defense-in-depth); full OS sandbox (container/FS-view + network allowlist) is **roadmap**, residual risk documented | worktree boundary protects the *checkout*, not the *filesystem/credentials*; a blocklist alone is leaky |
| D34 | Only **`agentic-engineer` ships as a skill**; PM + harness-CLI are **bins**; phase methodologies (brainstorm/plan) are **embedded inline** in phase prompt builders | one shippable skill; CLI runs self-contained under any `CLAUDE_CONFIG_DIR` (no hidden dependency on external skills existing there) |
| D35 | `harness install.sh --target <dir>` (default `~/.claude`) installs the **skill** into `<dir>/skills/` (**symlink** default, `--copy` opt) **+** the `agentic-engineer` **bin** globally; `pm install.sh` installs the `agentic-pm` **bin** only; idempotent manifest | skill is per-config-dir; bin is a global CLI; symlink = live editability |
| D36 | **CLI mode** selects the account via `CLAUDE_CONFIG_DIR` (direnv `.envrc`); the bin **validates** it and **refuses** to run otherwise (no silent fallback); **skill mode** uses the ambient session dir; forked children inherit it | isolate heavy autonomous CLI spend/rate-limits/auth to a dedicated account; make account selection explicit |

---

## 5. Distribution & account model

Two independent knobs — *where the skill installs* (`--target`) and *which account CLI runs use* (`CLAUDE_CONFIG_DIR`) — usually aligned.

### 5.1 Two ways to run the harness

| Mode | Entry point | Account (config dir) | Selection |
| --- | --- | --- | --- |
| **Skill** | `agentic-engineer` skill inside a Claude Code session | the **ambient** session dir (default `~/.claude`) | `install.sh --target <dir>` places `SKILL.md` in `<dir>/skills/agentic-engineer/` |
| **CLI** | `agentic-engineer` / `agentic-pm` **bin**, from a terminal | a **dedicated** dir (e.g. `~/.claude-personal`) | direnv `.envrc` exports `CLAUDE_CONFIG_DIR`; the bin validates it |

`project-management` has no skill — CLI-only, so it always runs under the CLI account. When PM forks a harness child, the child inherits `CLAUDE_CONFIG_DIR`, so a PM-driven run is uniformly on the personal account.

### 5.2 Install (D35)

```bash
# harness-engineering/install.sh
./install.sh                               # skill → ~/.claude/skills/agentic-engineer (symlink) + bin → PATH
./install.sh --target ~/.claude-personal   # skill → ~/.claude-personal/skills/... + bin → PATH
./install.sh --copy                        # copy the skill instead of symlinking

# project-management/install.sh
./install.sh                               # bin only: agentic-pm → PATH
```

- Skill → `<target>/skills/agentic-engineer/SKILL.md` (default `~/.claude`, symlink default, `--copy` to freeze).
- Bin → symlink into the first writable PATH bin (`~/.local/bin`, else npm global bin) — **not** target-scoped.
- Idempotent `Manifest { skill?, bin, mcpServers[] }`; `uninstall.sh` removes only listed entries. Both installers warn if the Playwright MCP is missing (the e2e gate needs it).

### 5.3 Account selection at runtime (D36)

```bash
# .envrc  (then: `direnv allow`)
export CLAUDE_CONFIG_DIR="$HOME/.claude-personal"
```

One-time setup of the personal account (establishes credentials in that dir):

```bash
CLAUDE_CONFIG_DIR="$HOME/.claude-personal" claude login   # or the SDK auth flow
```

Every bin runs `ensureAccount()` before any SDK call:

```typescript
function ensureAccount(): string {
  const dir = process.env.CLAUDE_CONFIG_DIR;
  if (!dir) fail(
    "CLAUDE_CONFIG_DIR is not set. CLI runs must use a dedicated account.\n" +
    "Add `export CLAUDE_CONFIG_DIR=\"$HOME/.claude-personal\"` to .envrc, then `direnv allow`."
  );                                       // NO silent fallback to ~/.claude
  if (!isAuthenticated(dir)) fail(
    `No Claude credentials under ${dir}. Run once: CLAUDE_CONFIG_DIR="${dir}" claude login`
  );
  return dir;                              // SDK inherits via process.env
}
```

The SDK inherits `CLAUDE_CONFIG_DIR`; `settingSources:['user','project']` resolves *user* settings/rules/credentials from that dir and *project* from `cwd`. **SPIKE (§17): confirm the SDK honors `CLAUDE_CONFIG_DIR` for settings and auth; if not, pass the equivalent option in `makeOpenSession` and update `isAuthenticated`.**

### 5.4 Model & effort overrides (D8) — both models

```
--model  <role>=<model>[,<model>…]   # repeatable; comma-list = escalation ladder for that role
--effort <role>=<low|medium|high>    # repeatable
--models-file <path>                 # JSON: { "<role>": { "model": "...", "effort": "..." }, ... }
```

- Precedence: CLI flags **>** `--models-file` **>** built-in defaults (§8).
- Validation: `role ∈` known roles (§8), `model ∈ {haiku,sonnet,opus}` or a full model id, `effort ∈ {low,medium,high}`; unknown values error with the valid set.
- Overriding a role's model **pins** it (ladder off) unless a comma-list is supplied.
- PM parses `--model/--effort` (which may target harness roles) and **forwards** them to the forked harness child via argv, so the child's own parser applies them uniformly.

---

## 6. Monorepo layout

```
agentic-workflow/
├── CLAUDE.md                    # project-wide context only (NOT model-specific)
├── pnpm-workspace.yaml · turbo.json · package.json · tsconfig.base.json
└── packages/
    ├── core/                    # @agentic/core — SDK/git/verify/observability/install/mcp/config/types
    ├── harness-engineering/     # @agentic/harness-engineering (skill + bin/agentic-engineer + *.sh)
    └── project-management/      # @agentic/project-management (bin/agentic-pm only + *.sh)
```

---

## 7. Public API (the only surface PM + CLIs depend on)

```typescript
// @agentic/core — public
export interface RunFeatureInput {
  spec: SpecRef;                 // { file } | { jira } | { text }
  design?: DesignRef;            // Figma | Claude Design | image refs
  cwd: string;                   // target project; relative paths resolve here
  base?: string;                 // worktree base; default = current branch of cwd (D4)
  auto?: boolean;                // blocked permission/abort/budget ⇒ paused
  budgetTokens?: number;         // per-feature ceiling; exhaustion ⇒ paused (D28)
  models?: ModelOverrides;       // per-role model/effort (D8)
  onEvent?: (e: HarnessEvent) => void;
  signal?: AbortSignal;
}
export interface RunFeatureResult {
  featureId: string;             // for resume()
  status: "merged" | "paused" | "failed";
  worktree: string;
  acceptance: AcceptanceReport;  // per-item verdict + verdictSource (D26)
  commits: string[];
  reason?: string;               // paused: permission/abort/budget; failed: why
}
export interface ResumeOptions {
  cwd: string; auto?: boolean; budgetTokens?: number;
  models?: ModelOverrides; onEvent?: (e: HarnessEvent) => void; signal?: AbortSignal;
}

export function runFeature(input: RunFeatureInput): Promise<RunFeatureResult>;
export function resume(featureId: string, opts: ResumeOptions): Promise<RunFeatureResult>;
```

**Cross-process transport (D1).** PM forks `invoke/harness-child.ts`, which imports `runFeature` and forwards every `HarnessEvent` via `process.send()`. The parent maps `child.on('message')` → `reporter.onChild(ticketId, e)`, sends `{cancel:true}` on `signal`, and reads a final `{result}` message. A crashed child (non-zero exit, no `{result}`) ⇒ ticket `failed`/`paused`; the batch continues.

```typescript
export type HarnessEvent = {
  runId: string; featureId: string; seq: number; phase: Phase; ts: number; sessionId?: string;
} & (
  | { type: "phase"; status: "enter" | "exit"; outcome?: PhaseOutcome["kind"] }
  | { type: "thinking"; text: string }
  | { type: "tool"; name: string; state: "use" | "result"; parentToolUseId?: string }
  | { type: "subagent"; state: "start"|"progress"|"running"|"completed"|"failed"|"killed"|"paused";
      taskId: string; subagentType?: string; lastTool?: string; usage?: SubagentUsage } // SDKTask* (§16)
  | { type: "gate"; tier: "per-commit" | "completion"; name: string; pass: boolean }
  | { type: "acceptance"; id: string; verdict: "pass"|"fail"; source: "code"|"review" }  // D26/D30
  | { type: "permission"; tool: string; agentId?: string; reason: string; resolved?: boolean }
  | { type: "mcp"; server: string; state: "discovered"|"trusted"|"blocked" }             // D29
  | { type: "budget"; usedTokens: number; ceiling?: number }                             // D28/D32
  | { type: "task"; id: string; status: "start" | "done" | "blocked" }
  | { type: "context"; event: "compacted" }
  | { type: "model"; role: string; model: string; effort: string; reason: "route" | "escalate" }
);

// PM-level project stream (D32) — distinct from fanned child events
export type ProjectEvent = { runId: string; ts: number } & (
  | { type: "ba"; state: "start"|"tickets-written"|"skipped" }
  | { type: "ticket"; number: number; status: "start"|"merged"|"parked"|"failed"; featureId?: string; reason?: string }
  | { type: "integration"; branch: string; tip: string }
);
```

---

## 8. Model & permission routing

Roles, default model/effort, and permission posture (D7). Auto posture = SDK `permissionMode:'acceptEdits'` **and** the broker auto-grants the safe allowlist without an interactive prompt. Auto posture is **distinct** from the harness `--auto` flag (which governs out-of-allowlist escalation).

| role | model (default) | effort | posture | note |
| --- | --- | --- | --- | --- |
| `worktree` | haiku | low | mechanical (non-interactive) | dedicated subagent; base controller-computed + validated (D3/D4) |
| `ingest` | haiku | low | mechanical (non-interactive) | jira/url fetch; `WebFetch` allowlist only |
| `brainstorm` | opus | high | interactive-capable | may `clarify` the user (under `--auto`: assume or pause) |
| `planner` | opus | high | interactive-capable | tool submission + validation loop |
| `executor-lead` | sonnet | medium | **auto** | `acceptEdits`; multi-file; may spawn leaves (depth 1) |
| `executor-leaf` | `haiku,sonnet,opus` | low | **auto** | `acceptEdits`; escalation ladder over `attempt` |
| `reviewer` | opus | high | **auto** | read/Bash/Playwright, **no Edit/Write**; detached sandbox |
| `verify` | — (code gates) | — | **auto (by construction)** | `child_process`; inherently non-interactive |
| `ba` (PM) | opus | high | interactive-capable | `submit_tickets` tool; prompt inline |

```typescript
type Effort = "low" | "medium" | "high";
type RoleDefault = { model: ModelChoice | ModelChoice[]; effort: Effort };
type ModelOverrides = Partial<Record<Role, { model?: ModelChoice | ModelChoice[]; effort?: Effort }>>;

class ModelRouter {                                  // D8
  constructor(private overrides: ModelOverrides = {}) {}
  modelFor(role: Role, attempt = 0): { model: ModelChoice; effort: Effort } {
    const base = DEFAULTS[role], o = this.overrides[role] ?? {};
    const model = o.model ?? base.model;             // override pins the role unless it's an array
    const effort = o.effort ?? base.effort;
    const picked = Array.isArray(model) ? model[Math.min(attempt, model.length - 1)] : model;
    return { model: picked, effort };
  }
  costCapRules(): string[] { return ["Agent(model:opus)"]; }  // deny opus subagents from leaves
}
```

Auto-posture roles never gain `bypassPermissions`; out-of-allowlist actions still go to the broker → ask (interactive) / `PermissionBlocked` → pause (`--auto`), and the hard `PreToolUse` hooks (§14) always apply.

---

## 9. Harness controller — state machine

```typescript
type Phase = "worktree"|"brainstorm"|"plan"|"execute"|"verify"|"review"|"merge";
type ControllerState = Phase | "init" | "done" | "paused" | "failed";
const PHASE_ORDER: Phase[] = ["worktree","brainstorm","plan","execute","verify","review","merge"];

export type PhaseOutcome =
  | { kind: "advance"; note?: string }
  | { kind: "repeat"; escalate?: boolean; reason?: string }
  | { kind: "back"; to: Phase; escalate?: boolean; reason?: string }
  | { kind: "pause"; reason: string }        // permission | abort | budget | watchdog (D28)
  | { kind: "fail"; reason: string };

interface PhaseContext {
  feature: FeatureRef;                       // { id, cwd, worktree, base, spec, design, signal }
  memory: MemoryStore; git: GitOps; verify: VerifyRunner;
  models: ModelRouter; permissions: PermissionBroker; input: InputProvider;
  openSession: (role: Role, model: ModelChoice, opts?: SessionOpts) => SdkSession; // NEW query()
  emit: (e: PartialEvent) => void; attempt: number; signal: AbortSignal;
  budget: BudgetMeter;                       // running token total + ceiling (D28/D32)
}
type PhaseFn = (ctx: PhaseContext) => Promise<PhaseOutcome>;
```

All bounds come from `core/config` (D32), env-overridable:

```typescript
export const CONFIG = {
  MAX_ATTEMPTS:        num("AGENTIC_MAX_ATTEMPTS", 3),        // phase model ladder
  MAX_TASK_ATTEMPTS:   num("AGENTIC_TASK_ATTEMPTS", 3),       // leaf ladder before task FAIL (D14)
  PLAN_MAX_TRIES:      num("AGENTIC_PLAN_TRIES", 3),          // plan validation retry (phase-internal)
  MAX_REBASE_ATTEMPTS: num("AGENTIC_REBASE_ATTEMPTS", 3),     // integrate diverged (D19)
  REVIEW_INVALID_CAP:  num("AGENTIC_REVIEW_INVALID_CAP", 1),  // reviewer mutated tree (D10)
  WATCHDOG_IDLE_MS:    num("AGENTIC_WATCHDOG_IDLE_MS", 120_000),
  TOOL_MAX_MS:         num("AGENTIC_TOOL_MAX_MS", 900_000),   // single tool/gate hard ceiling (D27)
  PHASE_MAX_MS:        num("AGENTIC_PHASE_MAX_MS", 3_600_000),
  DEFAULT_BUDGET_TOK:  numOpt("AGENTIC_BUDGET_TOKENS"),       // undefined ⇒ no ceiling
} as const;
```

**Driver loop (`drive()`):** persist state after *every* phase; classify thrown errors precisely.

```typescript
state = await reconcile(ctx0);                          // 'worktree' (new) or saved phase
while (running(state)) {
  const phase = state as Phase;
  emit("phase", "enter");
  let outcome: PhaseOutcome;
  try {
    outcome = await withWatchdog(ctx0, () =>            // D27: idle + ceiling; kill → throws
      PHASES[phase]({ ...ctx0, attempt: attempts[phase] ?? 0 }));
  } catch (e) { outcome = classify(e); }               // ↓ D28
  emit("phase", "exit", outcome.kind);
  if ((outcome.kind === "repeat" || outcome.kind === "back") && outcome.escalate)
    attempts[targetOf(phase, outcome)]++;
  state = transition(phase, outcome, attempts);
  await memory.writeState({ phase, attempts, rebaseAttempts,
    cleanCommit: await git.headHash(worktree), usedTokens: ctx0.budget.used });
}
return finalize(state, ctx0);                           // done→merged · paused→paused · failed→failed

function transition(phase, o, attempts): ControllerState {
  switch (o.kind) {
    case "pause":   return "paused";
    case "fail":    return "failed";
    case "repeat":  return attempts[phase] >= CONFIG.MAX_ATTEMPTS ? "failed" : phase;
    case "back":    return attempts[o.to] >= CONFIG.MAX_ATTEMPTS ? "failed" : o.to;
    case "advance": return nextPhase(phase);            // merge → 'done'
  }
}

function classify(e: unknown): PhaseOutcome {           // D28
  if (e instanceof PermissionBlocked) return { kind: "pause", reason: e.detail };
  if (e instanceof AbortError)        return { kind: "pause", reason: "aborted by user (resumable)" };
  if (e instanceof BudgetExceeded)    return { kind: "pause", reason: `token budget ${e.used}/${e.ceiling}` };
  if (e instanceof WatchdogKill)      return { kind: "pause", reason: `watchdog: ${e.detail}` };
  return { kind: "fail", reason: String(e) };
}
```

**`reconcile()`** (entry for new and `resume`): step 0 `discardWorking` (D18); **GC orphan worktrees** (D31); if `HEAD === saved.cleanCommit` trust the cursor; else rerun the per-commit gate over `base..HEAD` — fail ⇒ write `last-verify.json` + return `'execute'`; pass but HEAD moved ⇒ adopt HEAD as `cleanCommit`, keep phase. Per-item acceptance flipping happens at **verify completion**, not here.

---

## 10. Harness phases

**P0 `worktree`** (Haiku subagent, D3/D4). The controller first resolves the base deterministically:

```typescript
function resolveBase(cwd: string, override?: string): string {   // D4
  if (override) return override;                                  // explicit --base wins
  const branch = git.currentBranch(cwd);                         // symbolic-ref --short HEAD
  if (!branch) throw new DetachedHeadError("detached HEAD; checkout a branch or pass --base");
  return branch;                                                  // NEVER main/master/staging by default
}
```

It then opens a **Haiku session** (`cwd: input.cwd` — the only phase whose cwd is the project root) whose sole tool is the controller-implemented `worktree({ op })`; the subagent decides create-vs-enter and reports status, but the git mutation is controller code:

```typescript
// custom in-proc tool given to the worktree subagent
tool("worktree", "create or enter the feature worktree", { op: z.enum(["create","enter"]) },
  async ({ op }) => {
    const wt = await git.addFeatureWorktree({ id, base: resolvedBase }); // idempotent; branch harness/<id> from base
    return { worktree: wt, branch: `harness/${id}`, base: resolvedBase };
  });
```

After the subagent returns, the controller **validates** the outcome: worktree exists, is on `harness/<id>`, tracks `resolvedBase`, and `info/exclude` lists `.harness/`; any mismatch ⇒ `fail`. Then materialize the spec: `text`/`file` read directly (0 tokens); `jira`/`url` via a Haiku `ingest` session (may throw `PermissionBlocked`). Ingested content is wrapped `<untrusted-source>…</untrusted-source>` in downstream prompts and labelled *data, not instructions*. Persist `spec.raw.md` + `design.json` (store design **handles**, not fetched frames).

**P1 `brainstorm`** (Opus high, methodology inline). `clarify` tool: interactive → ask user; `--auto` + non-blocking → record as assumption; `--auto` + `blocking:true` → `pause`. Submit via `submit_spec` (`{ specMarkdown, assumptions }`); controller writes `spec.md`.

**P2 `plan`** (Opus high, methodology inline). Planner submits `submit_plan` `{ planMarkdown, acceptance[], tasks[] }` (zod). Controller validates + writes (atomic; freeze+hash acceptance). Validation retry is a **phase-internal loop** (`PLAN_MAX_TRIES`), not driver `repeat`. `validatePlan`: unique ids, deps exist, acceptance refs exist, unique `e2e` tags, **no dependency cycle**, **coverage** (D22), and **every acceptance carries a verify handle** (D26; `manual` must be explicit). Write order: `plan.md` → `writeAcceptanceOnce` (freeze+hash) → `tasks`. Recovery `planTasksOnly` rebuilds tasks against already-frozen acceptance.

```typescript
const VerifyHandle = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("e2e"),    tag: z.string().regex(/^@[a-z0-9-]+$/) }),
  z.object({ kind: z.literal("unit"),   filter: z.string().min(1) }),  // test-name/path filter
  z.object({ kind: z.literal("cmd"),    run: z.string().min(1) }),     // exit-0 ⇒ pass (sandboxed)
  z.object({ kind: z.literal("manual"), note: z.string().min(4) }),    // reviewer attests
]);
const AcceptanceInput = z.object({
  id: z.string().regex(/^A-\d{3}$/), statement: z.string().min(8), verify: VerifyHandle, // REQUIRED
});
const TaskInput = z.object({
  id: z.string().regex(/^T-\d{3}$/), title: z.string().min(4), planRef: z.string().optional(),
  acceptanceIds: z.array(z.string()).default([]), dependsOn: z.array(z.string()).default([]),
  complex: z.boolean().default(false),
});
```

**P3 `execute`** (auto posture, D7). Controller owns the task loop (not an LLM orchestrator). Outer loop walks `tasks.json`. Remediation mode: re-entered with `attempt>0` + a clean ledger ⇒ read `last-verify.json`, append one remediation task (Sonnet, D15), continue. Inner `workTask`:

```typescript
while (true) {
  const role = task.complex ? "executor-lead" : "executor-leaf";
  const { model } = models.modelFor(role, task.attempts);
  await openSession(role, model).run(buildTaskPrompt(plan, task, lastFailure)); // acceptEdits; PermissionBlocked bubbles
  const gate = await verify.run("per-commit", feature, { diff: "working" });     // affected on working tree
  if (gate.allPass) return { ok: true, commit: await git.commit(worktree, commitMsg(task)) };
  task.attempts++; lastFailure = gate;
  if (task.attempts >= CONFIG.MAX_TASK_ATTEMPTS) return { ok: false, gate };      // ⇒ blocked ⇒ FAIL (D14)
}
```

On block: `task.status='blocked'`, `discardWorking`, `fail`. On `PermissionBlocked`/`AbortError`: task→`pending`, `discardWorking`, rethrow ⇒ driver `pause`. Execute runs **per-commit only** (no e2e/build).

**P4 `verify`** (completion, auto/code). `verify.run('completion')` = full-scope `typecheck→lint→unit` sweep (D12) then `e2e→build`. Then **`reconcileAcceptance()` (D26/D30)**: for **every** acceptance handle, run/read its result and set the verdict — `e2e`→Playwright tag, `unit`→test filter, `cmd`→exit code (sandboxed), `manual`→carried to review — a **full recompute** (pass **and** fail), recording `verdictSource`. `advance` iff gates green **and** every non-manual acceptance = pass. Fail ⇒ write `last-verify.json` (**localized**: failing package + step + first error line) + `back:'execute'` (escalate).

**P5 `review`** (auto posture, D7/D10). Detached sandbox + detective; the reviewer additionally **attests each `manual` acceptance**:

```typescript
const sandbox = await git.addDetachedWorktree(feature);         // .harness/review @ HEAD
const before  = await git.snapshot(sandbox);
try {
  const report = await runReviewer(ctx, sandbox);               // Opus; read/Bash/Playwright; NO Edit/Write
  if (await git.diffTracked(sandbox, before, ctx.generatedPaths)) // ignore known generated files
    return { kind: "repeat", reason: "reviewer mutated tree → invalid" };  // cap = REVIEW_INVALID_CAP (D10)
  memory.setManualVerdicts(report.manualAttestations);          // D26
  return report.approved ? { kind: "advance" } : { kind: "back", to: "execute", escalate: true };
} finally { await git.removeDetachedWorktree(sandbox); }
```

**P6 `merge`.** **Precondition (D26): every non-manual verdict = pass and every manual = reviewer-approved**, else `back:'execute'`. Then `integrate`:

- `fast-forward` ⇒ remove worktree, `advance` (→ merged).
- `base-checked-out` ⇒ remove worktree, keep `harness/<id>` branch, `advance` with note (D20).
- `diverged` ⇒ bump `rebaseAttempts`; exhausted ⇒ `pause`. Else `rebaseOnto(base)`: conflict ⇒ `rebaseAbort` + `pause` (no LLM conflict resolution in v1); clean ⇒ rerun completion; pass ⇒ `repeat` (re-integrate, now ff); fail ⇒ `back:'execute'` (D19).

---

## 11. `@agentic/core` file map & contracts

```
core/src/
├── config/     index.ts                       (D32 bounds; env-overridable)
├── sdk/        session.ts · stream.ts · permissions.ts · models.ts · watchdog.ts
├── git/        worktree.ts · snapshot.ts · gc.ts        (implements GitOps)
├── verify/     resolver.ts · classify.ts · graph.ts · run.ts · handles.ts
├── mcp/        discover.ts · register.ts · trust.ts
├── observability/ reporter.ts
├── install/    paths.ts · manifest.ts · cli.ts · account.ts
└── types/      spec.ts · design.ts · events.ts · reports.ts · acceptance.ts
```

- **`sdk/session.ts`** — `makeOpenSession`: each call = new `query()`. Options: `model`, thinking budget from effort, `allowedTools`, `mcpServers` (discovered **and trusted**, D29), `agents`, `settingSources:['user','project']` (**user scope from `CLAUDE_CONFIG_DIR`**), `cwd`, **`permissionMode` from role posture** (D7: executor/reviewer ⇒ `acceptEdits`), `canUseTool: broker.canUseTool(role)`, `hooks: safety.hooksFor(role)`, **`env: scrubEnv(role)`** (D33), `resume`, abort, `forwardSubagentText` (default false), `includePartialMessages` (default false). `tool(name, desc, zodShape, handler)` wraps SDK `tool`.
- **`sdk/stream.ts`** — `EventSink` assigns `runId/seq/ts/sessionId`. `ingest(msg, role)` handles `system/init`, `task_started|progress|updated|notification`, `permission_denied`, `compact_boundary`, plus assistant/user → `HarnessEvent`; feeds `budget` from subagent `usage.total_tokens`.
- **`sdk/permissions.ts`** — `PermissionBroker.canUseTool(role)`: auto-grant the safe allowlist (read-only; `Edit`/`Write` within worktree; `Bash` only discovered gate cmds; `WebFetch` allowlisted domains). Otherwise interactive ⇒ ask; `--auto` ⇒ throw `PermissionBlocked`. Run repo-committed settings through `filterEscalatingDefaultMode` (project can't self-escalate `defaultMode`).
- **`sdk/watchdog.ts`** — `withWatchdog(ctx, fn)` (D27): resets an **idle timer** on every `emit`; enforces a **hard ceiling** per in-flight tool/subagent and per phase; on breach aborts `fn` and throws `WatchdogKill`. `task_progress` is liveness *input*, never suspends the ceiling.
- **`sdk/models.ts`** — `ModelRouter` (§8) with `ModelOverrides` (D8) + `costCapRules()`.

**`git/` — `GitOps`** (all commands use `git -C <wt>`; never touch the user's main checkout):

```typescript
interface GitOps {
  currentBranch(cwd): string | null;         // symbolic-ref --short HEAD; null if detached (D4)
  headHash(wt): Promise<string>;
  addFeatureWorktree(f): Promise<string>;     // idempotent; branch harness/<id> from f.base; prune; info/exclude '.harness/'
  removeFeatureWorktree(f): Promise<void>;
  gcOrphans(): Promise<void>;                 // D31: prune + remove crashed harness/<id> & .harness/review
  discardWorking(wt): Promise<void>;          // reset --hard HEAD && clean -fd  (NO -x → keeps .harness)
  commit(wt, msg): Promise<CommitResult>;     // add -A; nothing staged ⇒ {created:false}; fixed bot id (D21)
  diffNames(wt, spec): Promise<string[]>;     // { working } | { range:'base...HEAD' }
  snapshot(wt): Promise<Snapshot>;            // review detective: snapshot the SANDBOX
  diffTracked(wt, before, ignore?): Promise<boolean>; // HEAD moved OR tracked changes; ignores untracked + `ignore` globs
  addDetachedWorktree(f): Promise<string>;    // .harness/review @ HEAD
  removeDetachedWorktree(path): Promise<void>;
  rebaseOnto(f, base): Promise<"clean" | "conflict">;
  rebaseAbort(f): Promise<void>;
  integrate(f): Promise<IntegrateResult>;     // ff to base; 'fast-forward'|'diverged'|'base-checked-out'; never pushes main
  ensureBranch(name, from): Promise<void>;
  tipOf(branch): Promise<string>;
}
```

> Subtle invariants: `.harness/` survives `clean -fd` **only because** `info/exclude` lists it; `diffTracked` uses `status --porcelain --untracked-files=no` plus `ignore` globs (Playwright emits `test-results/`, some repos commit `dist/`); `integrate` cannot ff a branch checked out elsewhere (hence `base-checked-out`).

**`verify/`** — `resolver.ensurePlan` caches `verify.json` keyed by `configHash` (package.json + lockfile + monorepo config). `classify` orders name-regex (`e2e` before `unit`); placeholder bodies ⇒ `disabled` (excluded, not pass-faked). `graph.affectedPackages` (pnpm/single; turbo/nx self-compute) with `withReverseDependents` (D13). `run.VerifyRunner.run(tier, feature, {diff})`: `PER_COMMIT=['typecheck','lint','unit']` (affected); `COMPLETION` = full-scope sweep (D12) then `['e2e','build']`; **every subprocess gets an explicit `timeout`** (D27); parse Playwright JSON → `failedTests`; `last-verify.json` localized. `handles.runHandle(h)` maps each acceptance handle to `pass|fail`; `reconcileAcceptance()` recomputes **all** verdicts (D30).

**`mcp/`** — `discover` by scope (harness=user `$CLAUDE_CONFIG_DIR/.claude.json`; PM=project `.mcp.json` + `.claude/settings.json`), dedupe by name. **`trust.ts` (D29):** user-scope servers trusted; **project-scope servers require first-sight confirmation** (or a persisted allowlist in `harnessHome`), surfaced as `{type:'mcp', state:'discovered'}` → confirm → `'trusted'`, else `'blocked'`; `--auto` without a prior allowlist ⇒ blocked + feature `paused` if needed.

**`observability/reporter.ts`** — terminal + JSONL at `harnessHome()/runs/<runId>/` (D25). Dual-watchdog rendering; **prominent** permission/mcp-trust notices; running **token budget** bar. PM adds a **project timeline** sink for `ProjectEvent` (D32).

**`install/`** — `paths.resolveInstallDir(model,{target,cwd})` (`--target` overrides skill dir; bin global; `harnessHome()=$CLAUDE_CONFIG_DIR/agentic-harness`); `account.ensureAccount()` (§5.3); `manifest` idempotent (`{skill?,bin,mcpServers[]}`); `cli` shared `install|update|uninstall`.

---

## 12. `@agentic/harness-engineering`

```
harness-engineering/
├── bin/agentic-engineer.ts      # ensureAccount() → --spec|--jira|--design|--target|--auto|--budget|--model|--effort|--help → runFeature; exit 0/1/2
├── src/controller.ts            # §9
├── src/phases/                  # worktree·brainstorm·plan·execute·verify·review·merge (§10); prompts inline (D34)
├── src/memory/                  # store.ts · reconcile.ts · schema.ts
├── src/safety/                  # hooks.ts · reviewer-guard.ts · scrub-env.ts
├── src/recovery/retry.ts        # git revert + model/effort escalation
├── src/skill/agentic-engineer/SKILL.md   # the ONLY shipped skill (D34)
└── install.sh · update.sh · uninstall.sh # skill → --target + bin → PATH (D35)
```

**`memory/` — `.harness/` ownership:**

| file | writer | nature |
| --- | --- | --- |
| `spec.md`, `plan.md` | brainstorm / plan | write-once, raw |
| `tasks.json` | plan → execute | mutable ledger (resumable) |
| `acceptance.json` | plan | **frozen + hash** (D16); each item has a `verify` handle (D26) |
| `acceptance-state.json` | controller only | verdict + `verdictSource` (D16/D26) |
| `verify.json` | resolver | cache (configHash invalidation) |
| `state.json` | driver, after each phase | cursor — may be stale; carries `usedTokens` |
| `last-verify.json` | verify on `back` | transient, localized bridge to execute |
| `progress.md` | every phase | append-only |

- **`store.ts`** — atomic writes (tmp + fsync + rename); zod-validate on read (`MemoryCorruptError`); `readAcceptance` recomputes hash ⇒ `AcceptanceTamperError` (D17); `setAcceptanceVerdict`/`setManualVerdicts` controller-only.
- **`reconcile.ts`** — §9 + `reconcileAcceptance()` full recompute (D30).
- **`schema.ts`** — single source of zod types: `HarnessState` (incl. `rebaseAttempts`, `usedTokens`), `TaskLedger`, `AcceptanceDoc` (hash + `verify`), `AcceptanceState` (verdict + source), `GateResult`, `VerifyPlan`.

**`safety/`:**

- **`hooks.ts`** — `PreToolUse` for all roles: `boundary` (block `Edit`/`Write` outside worktree), `safeBash` (block `rm -rf` on `/`/`~`/`$HOME`, `git push`, `sudo`, `curl|sh`, fork bombs, `find … -delete`, encoded `… | sh`). Defense-in-depth only.
- **`scrub-env.ts` (D33)** — `scrubEnv(role)`: for executor/leaf, strip credential vars (`AWS_*`, `GITHUB_TOKEN`, `*_API_KEY` except the SDK's own, `SSH_*`, cloud creds) and pin a restricted `PATH`; keep `CLAUDE_CONFIG_DIR`.
- **`reviewer-guard.ts`** — reviewer-only `PreToolUse` denylist (D10): block repo-mutating git / `sed -i` / `perl -i` / `tee` to real files; everything else passes (debug freely).

**`bin/agentic-engineer.ts`** — `ensureAccount()` first. Flags `--spec ./path | --jira KEY`, `--design`, `--target` (skill install only; runtime no-op), `--auto`, `--budget`, `--model role=val` (repeatable), `--effort role=val` (repeatable), `--models-file`, `--base`, `--help`. Requires `spec|jira`. Exit: `0` merged · `1` failed · `2` paused (needs human).

---

## 13. `@agentic/project-management` (CLI only)

```
project-management/
├── bin/agentic-pm.ts            # ensureAccount() → --target|--ticket|--auto|--model|--effort|--in-process|--help; exit 0/1/2
├── src/controller.ts            # runProject (§13.1)
├── src/ba/                      # read-sources.ts · tickets.ts · openspec.ts  (prompts inline, no skill — D34)
├── src/memory/pm-state.ts       # progress.json (durable, cross-ticket)
├── src/invoke/run-feature.ts    # fork harness-child; paused → park (D1)
├── src/invoke/harness-child.ts  # forked entry: imports runFeature, forwards HarnessEvent via process.send()
└── install.sh · update.sh · uninstall.sh   # bin only (D35)
```

- **`invoke/run-feature.ts` (D1)** — `child = fork(harnessChildPath, argv)` where `argv` forwards the operator's `--model/--effort` overrides; always `auto:true`; `child.on('message', e => reporter.onChild(ticketId, e))`; `signal` → `child.send({cancel:true})`; final `{result}` resolves; non-zero exit without result ⇒ `failed`/`paused`. `--in-process` dev flag calls `runFeature` directly (breakpoints; no isolation). Ticket spec = ticket body; OpenSpec change attached as design ref. Child inherits `CLAUDE_CONFIG_DIR`.
- **`memory/pm-state.ts`** — `progress.json`: `{ integrationBranch, sourceHash, tickets{ number, featureName, changeId, statement, dependsOn, status, featureId, reason, commit } }`. `nextRunnable` = `pending` with all `dependsOn` `done`; `parked`/`failed` block dependents within the run.
- **`ba/read-sources.ts`** — `sourcesChanged(prev)`: content-hash of `docs/**`, `README*`, `design/**`, `.agentic/sources/**`. BA re-runs only when changed.
- **`ba/tickets.ts`** — `runBA` (Opus, `submit_tickets`, prompt inline); controller writes `tickets/ticket-{n}-{feature}.md` + `tickets/.history/` — agent never writes files directly.
- **`ba/openspec.ts`** — `OpenSpecBridge` (D23): v1 filesystem `openspec/changes/<id>/`, no CLI shell-out pending the spike.

### 13.1 `controller.ts` — `runProject`

1. `ensureAccount()`. Emit `ProjectEvent` throughout (D32).
2. **BA refresh** if `sourcesChanged`: `runBA` → `writeTickets` → `ensureChange` per ticket (1:1) → save `sourceHash`.
3. Ensure integration branch `agentic/pm` from `HEAD` (must not be checked out anywhere → `integrate` can ff).
4. Sequential loop, park-then-continue: for each `nextRunnable`, `base = tipOf(integrationBranch)` (re-read each iteration → D24 build-up); **fork** `resumeFeature(featureId)` if parked-with-featureId else `runTicket`. Dispatch: `merged` ⇒ done, archive change, merge acceptance verdict into ticket history; `paused` ⇒ `parked`, keep `featureId`, warn (resume next run); `failed` ⇒ `failed`, warn. Save `pmState` after **every** ticket (crash-safe).

> **D24 honesty:** a parked ticket is skipped, so a later-run independent ticket may integrate before it; "sequential build-up" is best-effort and only the integration **tip** is gate-checked. Parallel execution of dependency-independent tickets (separate worktrees) is future work — the fork model (D1) is the enabler.

---

## 14. Security hardening & sandboxing

The system intentionally ingests untrusted content (Jira/Figma/web/repo-supplied MCP). Layers, weakest-assumption-last:

1. **Untrusted-source framing** — ingested spec/design content is delimited and labelled *data, not instructions* (§10 P0).
2. **No self-grant** — allowlist (policy) + `PreToolUse` hard hooks + `filterEscalatingDefaultMode` + `--auto` never bypasses (D9); auto posture is `acceptEdits`, not `bypassPermissions` (invariant 8).
3. **MCP provenance (D29)** — repo-supplied servers blocked until confirmed/allowlisted; `--auto` without a prior entry ⇒ blocked + `paused`.
4. **Credential-free agent shell (D33)** — `scrubEnv` strips cloud/SSH/token vars and restricts `PATH`; `safeBash` denylist is defense-in-depth, not the primary control.
5. **Tamper-proof spec** — `acceptance.json` frozen+hashed (D16/D17); verdicts controller-only.
6. **Reviewer containment** — detached sandbox + denylist + `diffTracked` (D10).

> **Documented residual risk (roadmap):** the executor's `Bash` still runs on the host filesystem (scoped to the worktree by `cwd`, not chrooted); a fully-compromised agent could read non-credential files or write outside the worktree via absolute paths the boundary hook misses. The correct end-state is **OS-level sandboxing** (container / restricted FS view + network allowlist). This is the top security item for v2.x; v1 ships layers 1–6 and treats the blocklist as belt-and-suspenders.

---

## 15. Observability & liveness

- **Absolute ordering** — `EventSink` assigns `seq`; the JSONL is replayable; the subagent tree reconstructs from `taskId`/`parentToolUseId`.
- **Dual watchdog (D27)** — idle-event timer (`WATCHDOG_IDLE_MS`) catches a stuck model; hard per-tool/phase ceilings (`TOOL_MAX_MS`/`PHASE_MAX_MS`) catch a hung tool; every gate subprocess has its own `timeout`. Breach ⇒ kill ⇒ `paused` with reason. `task_progress` is liveness input, never a ceiling suspend.
- **Token budget (D28/D32)** — running total from subagent `usage`; ceiling (`--budget` or `CONFIG.DEFAULT_BUDGET_TOK`) exhaustion ⇒ `BudgetExceeded` ⇒ `paused` (reason carries `used/ceiling`). Rendered as a bar.
- **Prominent blocks** — permission and MCP-trust prompts render unmistakably; nothing stalls silently (invariant 6).
- **Project timeline (D32)** — PM's `ProjectEvent` stream gives a per-ticket view (start/merged/parked/failed) independent of fanned per-feature events; feeds any dashboard.

---

## 16. SDK spike findings & required adaptations

Verified against `@anthropic-ai/claude-agent-sdk@0.3.186`. Adaptations confined to `stream.ts`/`session.ts`/`permissions.ts`/`watchdog.ts`.

1. **`query()` is top-level** (no depth/parent param) ⇒ depth reset holds in any process ⇒ D1 fork is free of depth cost.
2. **Subagent messages flow through the iterable, by default only `tool_use`/`tool_result`.** `forwardSubagentText:true` forwards full text+thinking; `SDKAssistantMessage` carries `subagent_type` + `task_description`.
3. **Prefer the `SDKTask*` lifecycle** (available without `forwardSubagentText`): `task_started|task_progress|task_updated|task_notification`, each with `task_id`, `subagent_type`, `status`, `last_tool_name`, and **`usage { total_tokens, tool_uses, duration_ms }`**. Build the tree + budget from these; enable `forwardSubagentText` only for deep-trace debugging.
4. **`SDKPermissionDeniedMessage`** (`type:'system', subtype:'permission_denied'`) carries `tool_name`, `agent_id`, `decision_reason_type`, `message` — bind for `--auto` pause reasons. `PreToolUse` denies do NOT surface here (we author those).

Uplifts adopted: budget gate from `usage.total_tokens` (§15); auto-mode trust filter via `filterEscalatingDefaultMode` + `resolveSettings`. `stream.ts ingest()` handles `system/init`, `system/task_*`, `system/permission_denied`, `system/compact_boundary`, plus assistant/user.

---

## 17. Open spikes & runtime checks (do BEFORE the dependent step)

- **`CLAUDE_CONFIG_DIR` honoring** *(before §12/§13 bins, D36)* — confirm the SDK reads user-scope settings **and credentials** from `CLAUDE_CONFIG_DIR`. If it uses another mechanism, pass the equivalent option in `makeOpenSession` and update `ensureAccount`/`isAuthenticated`. **Blocking for CLI mode.**
- **`task_progress` cadence** *(before relying on it for liveness, D27)* — measure the real emit interval for a long "thinking" Opus subagent with no tool use; if it can exceed `WATCHDOG_IDLE_MS`, raise the idle threshold or add a keep-alive so the watchdog doesn't false-kill.
- **`permissionMode` semantics** *(before §10 P3/P5, D7)* — confirm `acceptEdits` auto-accepts edits without suppressing the `canUseTool` broker (we still need broker escalation for out-of-allowlist actions). If they conflict, express the auto posture purely through the broker instead.
- **OpenSpec spike** *(before §13 PM build, D23)* — confirm real `openspec/changes/<id>/` layout + CLI flags before replacing the filesystem `OpenSpecBridge`; keep filesystem impl behind the interface until then.
- **Runtime integration checks** *(build step 3, needs a real API key)* — (a) message ordering when multiple subagents run; (b) whether `forwardSubagentText` floods the terminal in execute with many leaves — if so keep it off and rely on `SDKTask*`.

---

## 18. Testing strategy

The state machine and reconcile logic hide the most bugs and are the most testable without an API key. Highest-ROI first:

1. **Table-driven `transition()` tests** — every `(phase, outcome, attempts)` → expected `ControllerState`, incl. both escalation ladders and the `MAX_*` boundaries. Pure function; no mocks.
2. **Crash-injection matrix for `reconcile()`** — with a fake `PhaseContext` (mock `SdkSession`/`GitOps`/`VerifyRunner`), kill at each write boundary: after commit / before `state.json`; after `state.json` / before next phase; mid-gate; between `plan.md` and `tasks.json` (assert `planTasksOnly`); between `acceptance.json` and verdict. Assert convergence to a correct resumable state and that the reconciliation order (git > gate > acceptance > state) holds. This makes "resumable" a fact.
3. **Base resolution (D4)** — `resolveBase` returns the current branch, honors `--base`, and throws `DetachedHeadError`; a regression test asserts it **never** substitutes `main`/`master`/`staging`.
4. **Worktree subagent (D3)** — the `worktree` tool is idempotent (create then enter); controller validation rejects a wrong-branch/wrong-base outcome.
5. **Acceptance verification (D26/D30)** — `validatePlan` rejects handle-less acceptance; each handle kind maps to the right verdict; `reconcileAcceptance` flips **fail** on a regressed handle; `merge` precondition blocks on an unverified non-manual item.
6. **Model/effort overrides (D8)** — flag parsing (`role=val`, comma-list ladder), precedence (flags > file > default), validation errors; PM forwards overrides to the child.
7. **Permission posture (D7)** — executor/reviewer sessions run non-interactively for the allowlist; out-of-allowlist still escalates (ask / pause); hard hooks fire regardless of posture.
8. **Safety** — `boundary`/`safeBash` block the known-bad set; `scrubEnv` removes credential vars; reviewer denylist + `diffTracked` (with `ignore` globs) flags a mutating reviewer and tolerates generated files; repo-supplied MCP blocked until allowlisted.
9. **Watchdog (D27)** — a hung fake tool trips the ceiling (not the idle timer); an idle stream trips the idle timer; both ⇒ `WatchdogKill` ⇒ `paused`.
10. **Fork transport (D1)** — child event forwarding, `{cancel:true}` → `paused`, non-zero exit without `{result}` → `failed`; child inherits `CLAUDE_CONFIG_DIR` and override argv.
11. **E2E happy path (real key)** — one feature to `merged` on pnpm/turbo/nx; one PM run driving 2–3 tickets with a deliberate permission block (asserts park-then-continue and resume).

---

## 19. Build order

1. `core/{config, types, git(+gc), sdk/(session+stream+permissions+models+watchdog)}` — foundation; test with a fake feature (§18.1–§18.2, §18.9).
2. `core/verify/*` (+`handles`, subprocess timeouts) + `harness/memory/*` — gates run + `.harness` read/write on a real repo (§18.5).
3. `harness/phases/* + controller` — assemble `agentic-engineer` end-to-end on one feature. *(Runtime integration checks; `task_progress` + `permissionMode` spikes.)*
4. `core/{observability, install(+account), mcp(+trust)}` + harness **skill + bin + install.sh** — packageable + installable; **`CLAUDE_CONFIG_DIR` spike** before shipping the bin.
5. PM package + PM **bin** (fork transport, project events, override forwarding) — PM is the caller; build after harness is stable. *(OpenSpec spike before this.)*

---

## 20. Definition of done (v1)

- `agentic-engineer --spec ./specs/x.md` (CLI, under a validated `CLAUDE_CONFIG_DIR` account) drives one feature to `merged` (or `paused`/`failed` with a clear reason) on a real pnpm/turbo/nx monorepo: worktree created via a Haiku subagent **off the current branch** (never a default trunk); per-commit + completion gates enforced by the controller; **every acceptance verified against its handle** (`verdictSource` recorded; `merge` blocked on any unverified non-manual item); Playwright e2e verified; reviewer in a detached sandbox; executor/verify/review in **auto** posture; executor `Bash` on a scrubbed env; all artifacts torn down on merge.
- The `agentic-engineer` **skill** drives the same flow inside a Claude Code session on the ambient account; the **bin** refuses to run without a validated `CLAUDE_CONFIG_DIR`.
- `agentic-pm` (CLI, no skill) produces/updates `/tickets` + OpenSpec (filesystem v1), then drives tickets sequentially on `agentic/pm` by **forking a child per feature**, parking on permission/abort/budget blocks and resuming later; a crashed feature does not kill the batch.
- Both CLIs accept `--model role=val` / `--effort role=val` / `--models-file` and apply them per role (PM forwards to the child).
- `install.sh|update.sh|uninstall.sh` install the harness **skill** to `--target` (default `~/.claude`, symlink) + the **bin** globally, and the PM **bin** only; discover + (on confirmation) register scoped MCP servers; uninstall cleanly via manifest.
- Streaming shows thinking/tools/subagent tree + token budget; permission/MCP-trust blocks are surfaced prominently; the **dual watchdog** guarantees nothing stalls silently; PM exposes a project-level timeline.
- Test suite green without an API key: table-driven `transition`, crash-injection `reconcile`, base-resolution, worktree-subagent, acceptance-verification, override-parsing, posture, safety, watchdog, and fork-transport; one real-key E2E per model.
