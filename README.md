# agentic-workflow

A **Claude Code plugin suite** (no Agent SDK) that hand-builds a long-running agent harness out of
Claude Code primitives — hooks, files, subagents, and the CLI — glued with deterministic shell. It
implements one software feature _correctly and safely_, then wraps that in a deterministic outer loop
that builds _many_ features back-to-back with a **flat context footprint**.

It ships as five packages. **Dependencies resolve automatically** — installing any package pulls in
what it needs, so `--package pm` installs core, engineer, and pm:

| Package                | Role                                                                              | Depends on      |
| ---------------------- | --------------------------------------------------------------------------------- | --------------- |
| `agentic-core`         | Shared kernel: safety guard, verification gate, event emitter, state/checkpoint libs, BA↔PM frontmatter contract | — |
| `agentic-engineer`     | Single-feature pipeline **P0→P5** (worktree → plan → execute → verify → review → lifecycle) | core   |
| `agentic-init`         | Bootstrap a target project: OpenSpec CLI + `openspec init` + `docs/` scaffold      | core            |
| `agentic-ba`           | Reads `docs/**/*.md` → OpenSpec changes with testable acceptance criteria          | core            |
| `agentic-pm`           | The deterministic outer loop over the OpenSpec backlog                            | core + engineer |

> **Source of truth:** [specs/plan.md](specs/plan.md) (architecture, decisions `D-*`, invariants
> `I-*`) and [specs/execution-plan.md](specs/execution-plan.md) (task-level build plan). Working
> summaries live under [.claude/rules/](.claude/rules/).

> **Maturity:** the kernel, engineer pipeline, and PM loop are built and **fixture-tested**. Live
> end-to-end against a real `claude -p` engineer and the real `openspec` CLI is **deferred** (see the
> "Deferred" notes in the `agentic-pm` / `agentic-ba` skills). Always **dry-run the PM loop first**.

---

## Prerequisites

Required on your `PATH` before installing:

- **Claude Code** — with plugin + hooks support.
- **`bash`**, **`jq`**, **`git`** — the installer and every hook/script depend on these.
- **[`obra/superpowers`](https://github.com/obra/superpowers)** — the subagents invoke its skills
  (`brainstorming`, `writing-plans`, `test-driven-development`, …); don't reimplement them.

Additionally required to run the **PM outer loop** (`agentic-pm`):

- **`claude`** CLI on `PATH` (the loop spawns a fresh `claude -p` engineer per change).
- **[`Fission-AI/OpenSpec`](https://github.com/Fission-AI/OpenSpec)** (`openspec`) — the durable
  spec/ticket substrate. Run `openspec init` **in your target project**, not in this repo.

Verify:

```bash
jq --version && git --version && command -v claude && command -v openspec
```

---

## Installation

Installation is done with the scripts in [`packages/`](packages/) — **not** via a marketplace
`/plugin install`. Each script takes a `--target` config directory and installs packages into
`<target>/agentic/<package>`, symlinks their commands/agents/skills into discovery, and (for
`agentic-core`) merges its hooks into `<target>/settings.json`.

### `--target` resolution

`--target` is **required**. How it is interpreted:

| You pass `--target …`                     | Installs into            | Use for                       |
| ----------------------------------------- | ------------------------ | ----------------------------- |
| a Claude config dir (e.g. `~/.claude`)    | that dir directly        | global install for your user  |
| a directory that contains `.git`          | `<dir>/.claude`          | project-local install         |

If you run Claude Code with a custom `CLAUDE_CONFIG_DIR` (this repo's `.envrc` sets
`~/.claude-personal`), pass **that** directory as `--target`.

### Install

Dependencies resolve automatically, so installing any package is enough — `agentic-core` is
pulled in and installed (with its hooks merged) first regardless of what you ask for.

```bash
# Everything, into your global Claude config:
packages/install.sh --target ~/.claude --package all

# …or a single package — deps resolve automatically (e.g. "pm" also installs core + engineer):
packages/install.sh --target ~/.claude --package core
packages/install.sh --target ~/.claude --package engineer
packages/install.sh --target ~/.claude --package init
packages/install.sh --target ~/.claude --package ba
packages/install.sh --target ~/.claude --package pm

# Omit --package for an interactive 1-6 menu:
packages/install.sh --target ~/.claude
```

**Flags**

- `--target <dir>` _(required)_ — see resolution table above.
- `--package core|engineer|init|ba|pm|all` — which package(s); dependencies resolve automatically;
  omit for the interactive menu.
- Installs are **copy-only** (D-13 as amended) — there is no live-editable `--mode`; `--mode symlink`
  errors. For a live-editable dev loop see [Development](#development) below.

**PATH.** Packages that ship executables (`agentic-core`, `agentic-pm`) print an
`export PATH="…"` line on install — add it to your shell profile so `agentic-profile`, `pm-run.sh`,
and `pm-runner.sh` are callable.

**Reload.** After installing (or after re-installing to pick up an edit — installs are copy-only,
so edits to `packages/` don't propagate on their own), run
`/reload-plugins` inside Claude Code — plugin changes are not hot-reloaded.

### Update

Re-sync already-installed packages (same mode they were installed with):

```bash
packages/update.sh --target ~/.claude --package all
```

### Uninstall

Removes packages in reverse dependency order, un-merges `agentic-core`'s hooks from `settings.json`,
and drops the discovery symlinks — **user data is preserved** (your project's `openspec/` and any
worktree state are never touched):

```bash
packages/uninstall.sh --target ~/.claude --package all
```

---

## Usage

### 1. Build one feature — `agentic-engineer`

Drives the P0→P5 pipeline for exactly one feature or OpenSpec change, dispatching the scoped subagents
(`worktree`, `planner`, `executor`, `qa`, `reviewer`) with model/effort pinned per phase.

```
/engineer --mode {interactive|auto} [--change <id>]
```

- **`--mode interactive`** (default) — human-in-the-loop. Socratic brainstorm at P1, then **stops for
  your approval** before executing.
- **`--mode auto`** — headless. Reads `openspec/changes/<id>/{proposal,design,specs,tasks}.md`, writes
  an `assumptions.md` for any gap, and never pauses. **Requires `--change <id>`.**

All work happens inside a fresh **git worktree** created at P0. The kernel hooks enforce the
guarantees identically in both modes: `safety-guard.sh` denies destructive ops (fail-closed, before
permissions), and `verify-gate.sh` blocks stopping while a phase gate is red — verification runs your
project's _real_ lint/typecheck/test commands, auto-detected at P1.

### 1.5. Bootstrap the target project — `/agentic-init`

Run once per target project, from inside it:

```
/agentic-init
```

It verifies the OpenSpec CLI (installing `@fission-ai/openspec` if needed), runs `openspec init`, and
scaffolds `docs/` with an example spec. Write your real specs under `docs/**/*.md` — that is what
`agentic-ba` reads. `docs/` is **not** `openspec/specs/`, which is OpenSpec's own source of truth.

### 2. Build a backlog — `agentic-pm` (PM outer loop)

The PM loop (`pm-runner.sh`) is **deterministic shell**: it selects the next ready OpenSpec change,
spawns a fresh ephemeral `claude -p` engineer for it, gates on the engineer→PM **outcome contract**
(not the process exit code), archives on success, and moves on — with a flat context footprint.

**Prerequisites in the target project:** `openspec init` has been run, and `agentic-ba` (or you) have
produced changes with acceptance criteria + `depends_on`/`priority` frontmatter.

**Always dry-run first** — dry-run is the default, so a mis-run spends nothing:

```bash
# Prints the selection order + the engineer command it WOULD run; launches nothing.
AGENTIC_PROJECT_ROOT=/path/to/target PM_DRY_RUN=1 \
  bash ~/.claude/agentic/agentic-pm/bin/pm-run.sh
```

Or from inside Claude Code: `/run`.

When the selection order looks right, run for real by dropping the dry-run flag:

```bash
AGENTIC_PROJECT_ROOT=/path/to/target PM_DRY_RUN=0 \
  bash ~/.claude/agentic/agentic-pm/bin/pm-run.sh
```

The loop ends with `pm-runner summary: done=N blocked=M failed=K spent_usd=…`.

**Key knobs** (env vars; full table in the `agentic-pm` skill):

| Var                                   | Purpose                                                           |
| ------------------------------------- | ---------------------------------------------------------------- |
| `AGENTIC_PROJECT_ROOT`                | Target project dir _(required)_.                                 |
| `PM_DRY_RUN`                          | `1` = plan only (default via `pm-run.sh`); `0` = launch engineers. |
| `PM_ENGINEER_CMD`                     | Engineer invocation template (default: `/agentic-engineer:engineer --change {id} --mode auto`). |
| `PM_PERMISSION_MODE`                  | `acceptEdits` (default) — **never** `bypassPermissions`.          |
| `PM_MAX_RETRIES` / `PM_BACKOFF_SEC`   | Retry policy on a failed run.                                     |
| `PM_ON_FAIL` / `PM_ON_BLOCK`          | What to do on failure / `needs_human` (`continue` vs `stop`).     |
| `PM_COST_CAP_USD` / `PM_TIME_CAP_MIN` | Budget caps that halt the loop.                                   |
| `PM_COMPACT_EVERY`                    | Periodic bounded compaction interval.                            |

All PM state lives under the target's `openspec/.pm/` (`progress.json`, `outcomes/<id>.json`,
`logs/…`) — nothing persists in a long-lived session; that is the point (`I-1`/`D-14`).

### 3. Docs → OpenSpec changes — `agentic-ba`

Turns a project's docs/design into idempotent OpenSpec changes with testable acceptance criteria and
`depends_on`/`priority` frontmatter. Invoked headlessly by the PM loop, or directly:

```bash
claude -p "Use the agentic-ba skill to sync OpenSpec changes from the project docs under: <glob> — \
one feature-level change each, with testable acceptance criteria and depends_on/priority frontmatter." \
  --allowedTools "Task,Read,Write,Bash,Grep,Glob"
```

---

## Development

Installs are copy-only, so there is no live-editable install. Test a package straight from this repo
without installing it:

```bash
claude --plugin-dir packages/<name>
# then in Claude Code, after any agent/hook edit:
/reload-plugins
```

To exercise the real install path (e.g. testing `pm-run.sh` against a target project), re-run
`packages/install.sh` after each change instead.

Validate the hook JSON and run the shell test suites (each `*_test.sh` is self-contained):

```bash
jq . packages/agentic-core/hooks/hooks.json

# run one suite:
bash packages/agentic-core/tests/safety_guard_test.sh

# run all suites:
find packages -name '*_test.sh' -not -path '*/fixtures/*' -exec bash {} \;
```

Conventions: English for all code/docs, kebab-case naming, hooks stay fast and observers are
fire-and-forget (always exit 0). Full dev loop and conventions:
[.claude/rules/dev-workflow.md](.claude/rules/dev-workflow.md).

---

## How it fits together

```
agentic-pm (PM loop, deterministic shell)
        │  spawns a fresh, ephemeral engineer per OpenSpec change
        ▼
agentic-engineer  (P0 worktree → P1 plan → P2 execute → P3 verify → P4 review → P5 lifecycle)
        │  every action passes through the kernel hooks
        ▼
agentic-core      SessionStart · PreToolUse (safety-guard) · PostToolUse (emit-event) · Stop/SubagentStop (verify-gate)
```

- The **monorepo is the tooling**; **your repo is the state** — `openspec/` (durable memory) and
  per-feature `.agentic/` (ephemeral worktree state) live there, never here.
- Deeper reading: [.claude/rules/architecture.md](.claude/rules/architecture.md),
  [.claude/rules/invariants.md](.claude/rules/invariants.md),
  [.claude/rules/decisions.md](.claude/rules/decisions.md).
