# Invariants (`I-*`) — the hard constraints

_Applicability: **always in force.** These are load-bearing. If any is violated the system is unsafe or
unsound, not merely suboptimal. Decisions (`D-*`) can be revisited; invariants cannot — breaking one is a
bug, not a trade-off._
_Authoritative source: [specs/plan.md](../../specs/plan.md) §4._

`I-1`…`I-7` are what an engineer run must never break; `I-8`…`I-11` are system-wide.

| ID       | Invariant                                                                                                                                                                                                                                                            |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **I-1**  | The PM control loop **MUST be deterministic shell**. LLM work happens only in ephemeral sub-steps with fresh context; **every per-iteration read MUST be bounded** — never load the full `progress.json`, full `openspec/specs/`, or an unbounded `git log`. Pending slice + compact rollup only. |
| **I-2**  | **Every destructive operation passes through `safety-guard.sh` (PreToolUse).** A matched dangerous pattern fails **closed** and cannot be loosened by any permission "allow".                                                                                        |
| **I-3**  | **No agent stops before the current phase's gate is green** (`verify-gate.sh`). Stopping red is not an option the model can take.                                                                                                                                    |
| **I-4**  | **Engineer state is ephemeral.** It lives in the worktree (`.agentic/`) and is deleted with the worktree at P5. Nothing engineer-scoped persists outside the worktree.                                                                                               |
| **I-5**  | **The only rollback is `git reset --hard` to the last green checkpoint.** No hand-rolled partial reverts.                                                                                                                                                            |
| **I-6**  | **While a feature worktree is active, all writes stay inside it.** The single exception is durable OpenSpec artifacts under `openspec/` (mode=auto).                                                                                                                  |
| **I-7**  | **Verification is real.** Gates run the project's _actual_ fast (lint/typecheck) and large (test/e2e) commands. An agent never self-asserts "tests pass" instead of running them.                                                                                    |
| **I-8**  | **Hooks are fast and observers are fire-and-forget.** Target < ~100 ms; PostToolUse always exits 0 and never blocks the agent.                                                                                                                                       |
| **I-9**  | **Plugin components resolve paths via `${CLAUDE_PLUGIN_ROOT}`.** No hard-coded install locations. A `CLAUDE.md` _inside_ a plugin is ignored by Claude Code and must not be relied on.                                                                               |
| **I-10** | **The target project's own guidelines win.** Its `CLAUDE.md` / rules (injected at SessionStart) take precedence over the plugins' defaults.                                                                                                                          |
| **I-11** | **Durable, cross-feature state is OpenSpec's responsibility** (`openspec/specs/` as source of truth + `changes/archive/` as history). The engine never invents a parallel long-term store. Pairs with `I-4`.                                                          |
