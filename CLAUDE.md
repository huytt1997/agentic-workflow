# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> This is a **router**, not an encyclopedia (see the [why-one-giant-file lecture](https://walkinglabs.github.io/learn-harness-engineering/en/lectures/lecture-04-why-one-giant-instruction-file-fails/)).
> Keep it short; put detail in the topic docs under [.claude/rules/](.claude/rules/) and link to it.

## Project overview

`agentic-workflow` is a **Claude Code plugin marketplace** (no Agent SDK) that hand-builds a long-running
agent harness from Claude Code primitives — hooks, files, subagents, CLI — to implement one software
feature _correctly and safely_, then wraps it in a deterministic outer loop that builds _many_ features
back-to-back with a **flat context footprint**.

## ⚠️ Current state — read before assuming files exist

This repo is currently **spec-only**: it contains `specs/plan.md`, `specs/execution-plan.md`, `README.md`,
`.claude/`, and `.envrc`. The `packages/`, `bin/`, and `.claude-plugin/` scaffold the specs describe **does
not exist on disk yet** — building it is the work. Full state + next steps: [.claude/rules/roadmap.md](.claude/rules/roadmap.md).

## Source of truth

Two documents govern everything; code is downstream of them. When code and a spec disagree, one is a bug —
reconcile deliberately, don't paper over it.

- **[specs/plan.md](specs/plan.md)** — architecture, locked decisions (`D-*`), invariants (`I-*`), milestones.
- **[specs/execution-plan.md](specs/execution-plan.md)** — the task-level build plan (`T-*`) and current-state audit.

## Hard constraints (non-negotiable)

The load-bearing invariants; the full set with rationale is in [.claude/rules/invariants.md](.claude/rules/invariants.md).

1. **No Agent SDK.** Build only on Claude Code primitives (hooks/subagents/CLI) + superpowers + OpenSpec. Don't reimplement what they provide — wrap them. (`D-1`/`D-3`/`D-4`)
2. **PM outer loop is deterministic shell.** LLM work only in ephemeral fresh-context sub-steps; every per-iteration read is bounded (never the whole `progress.json` / `specs/` / `git log`). (`I-1`/`D-14`)
3. **Safety is fail-closed.** Every destructive op passes `safety-guard.sh` (PreToolUse); a matched danger cannot be loosened by any permission "allow". (`I-2`)
4. **No stop before green.** `verify-gate.sh` blocks ending a turn while a phase gate is red. (`I-3`)
5. **Verification is real.** Run the project's _actual_ lint/typecheck/test commands; never self-assert "tests pass." (`I-7`)
6. **Engineer state is ephemeral** — `.agentic/` in the worktree, deleted at P5; nothing engineer-scoped persists outside it. (`I-4`)
7. **All feature writes stay inside the active worktree** (except durable `openspec/` artifacts). (`I-6`)
8. **Only rollback is `git reset --hard` to the last green checkpoint.** (`I-5`)
9. **Plugins resolve paths via `${CLAUDE_PLUGIN_ROOT}`;** a plugin's own `CLAUDE.md` is ignored. (`I-9`)
10. **The target project's guidelines win** over plugin defaults. (`I-10`)
11. **Durable cross-feature state is OpenSpec's job;** never invent a parallel store. (`I-11`)
12. **Hooks are fast; observers fire-and-forget** and always exit 0. (`I-8`)
13. **English artifacts, kebab-case naming.**

## Quick start (dev loop — once the scaffold exists)

```bash
jq . packages/*/.claude-plugin/plugin.json packages/*/hooks/*.json  # validate plugin JSON first
claude --plugin-dir packages/<name>        # test a plugin without installing
bin/install.sh --mode symlink              # install live-editable for dev
/reload-plugins                            # after editing agent/hook files on disk
```

Details, the verification model, and conventions: [.claude/rules/dev-workflow.md](.claude/rules/dev-workflow.md).

## Topic docs (`.claude/rules/` — load on demand)

| Doc                                                     | Read when                                                                                                     |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| [architecture.md](.claude/rules/architecture.md)       | Understanding how the pieces fit: the two loops, the nine harness components, the tooling-vs-target boundary. |
| [invariants.md](.claude/rules/invariants.md)           | Any change — these are the safety/soundness rules that must never break (`I-*`).                              |
| [decisions.md](.claude/rules/decisions.md)             | Tempted to do something a different way, or touching an area a `D-*` covers.                                  |
| [dev-workflow.md](.claude/rules/dev-workflow.md)       | Running, testing, installing, or packaging; language/shell/naming conventions.                               |
| [roadmap.md](.claude/rules/roadmap.md)                 | Deciding what to build next; the current honest state, milestones, and first sprint.                         |
