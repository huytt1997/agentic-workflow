# Architecture

_Applicability: read before touching any component, or when reasoning about how the pieces fit together._
_Authoritative source: [specs/plan.md](../../specs/plan.md) §2, §5, §8 and [specs/execution-plan.md](../../specs/execution-plan.md) §1. This is the distilled working version._

## The one idea

`agentic-workflow` is a **Claude Code plugin marketplace** (no Agent SDK) that hand-builds the nine
components of a long-running agent harness out of Claude Code primitives — **hooks, files, subagents,
CLI** — glued with deterministic shell. The goal: implement one feature _correctly and safely_, then
wrap it in an outer loop that runs _thousands_ of features back-to-back with a **flat context footprint**
(change #1 costs the same context as change #100,000).

## Two nested loops

- **Inner loop — `agentic-engineer`**: builds ONE feature. An orchestrator SOP dispatches subagents
  through phases **P0 worktree → P1 plan → P2 execute → P3 verify → P4 review → P5 lifecycle**. Runs
  interactively (human) or headless (`--mode auto`).
- **Outer loop — `agentic-pm`**: **deterministic shell** (`pm-runner.sh`) that spawns a _fresh,
  ephemeral_ `claude -p` engineer per OpenSpec change and throws its context away on exit. Adaptivity
  comes from _periodic bounded compaction_, never a persistent session. This is the whole point
  (`I-1`/`D-14`): the shell holds ~0 context; durable state lives in files.

## Enforcement layer (agentic-core hooks — identical in both loops)

| Hook event          | Script               | Job                                                                            |
| ------------------- | -------------------- | ------------------------------------------------------------------------------ |
| SessionStart        | `session-bearings.sh`| get-bearings: cwd, profile, project rules, state, bounded `git log` (`I-10`)   |
| PreToolUse          | `safety-guard.sh`    | deny destructive ops; fail-closed; runs _before_ permissions (`I-2`, `D-9`)    |
| PostToolUse         | `emit-event.sh`      | NDJSON event stream; fire-and-forget; always exit 0 (`D-11`, `I-8`)            |
| Stop / SubagentStop | `verify-gate.sh`     | block "stop before green"; runaway guard → `needs_human` (`I-3`, `D-8`)        |

## Five plugins (dependency order)

| Plugin                 | Role                                                                            | Depends on       |
| ---------------------- | ------------------------------------------------------------------------------- | ---------------- |
| `agentic-core`         | Shared kernel: safety, verification, observability, state/checkpoint/profile libs, BA↔PM frontmatter contract | — |
| `agentic-engineer`     | Single-feature pipeline (P0–P5), interactive or headless                        | core             |
| `agentic-init`         | Bootstrap a target: OpenSpec CLI + `openspec init` + `docs/` scaffold           | core             |
| `agentic-ba`           | Reads `docs/**/*.md` → OpenSpec changes with testable acceptance criteria       | core             |
| `agentic-pm`           | Deterministic outer loop over the OpenSpec backlog                              | core + engineer  |

`install.sh` resolves these automatically: `--package pm` installs core + engineer + pm.

## The hard boundary: tooling vs. target

- **This monorepo is the TOOLING**, installed into `~/.claude` (or `--target`).
- **The user's repo is the STATE**: `openspec/` (durable management memory, `I-11`) lives _there_, created
  by `openspec init` in the target — never in this monorepo. Per-feature ephemeral state
  (`<worktree>/.agentic/state.json`, `I-4`) also lives in the target's worktree.

## The nine harness components → mechanism

Orchestration = engineer SKILL + `pm-runner.sh`. Tools = subagents via the `Task` tool + `agentic-core/bin/`
PATH wrappers + superpowers skills. Memory = `.agentic/state.json` (within-feature) + OpenSpec
(cross-feature). Context management = ephemeral `claude -p` + bounded reads + get-bearings. Verification =
`verify-gate.sh` + a dedicated `qa` subagent running the _real_ commands. Persistence = `state.sh` +
`checkpoint.sh`. Recovery = revert-last-green + runaway guard → `needs_human`. Safety = `safety-guard.sh` +
headless allow-list. Lifecycle = P5 worktree cleanup. (Full table: plan.md §5.)

## Repository layout

See [roadmap.md](roadmap.md) for what remains (**the five packages are built and fixture-tested**). The
layout is `packages/{install,update,uninstall}.sh` + `packages/{agentic-core,agentic-engineer,
agentic-init,agentic-ba,agentic-pm}/`. No `.claude-plugin/plugin.json` manifests exist — the installer
discovers components by directory scan. Component dirs (`commands/`, `agents/`, `skills/<name>/SKILL.md`,
`hooks/hooks.json`, `bin/`) live at each package root; each package's `bin/` is auto-added to the Bash
PATH. Full tree: plan.md §8.
