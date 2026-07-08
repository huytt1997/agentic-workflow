# Dev workflow & conventions

_Applicability: read when running, testing, installing, or packaging the plugins, or writing any code or
docs in this repo._
_Authoritative source: [specs/plan.md](../../specs/plan.md) §12 and [specs/execution-plan.md](../../specs/execution-plan.md) §6._

> **Note:** most commands below operate on `packages/` and `bin/`, which **do not exist yet** — this repo
> is currently spec-only (see [roadmap.md](roadmap.md)). They describe the dev loop once the scaffold is
> built.

## Dev loop (plugins)

- **Test a plugin without installing:** `claude --plugin-dir packages/<name>`
- **After editing agent/hook files on disk:** run `/reload-plugins` (changes are not hot-reloaded).
- **Validate plugin JSON before anything else:**
  `jq . packages/*/.claude-plugin/plugin.json packages/*/hooks/*.json`
- **Install for development (live-editable):** `bin/install.sh --mode symlink`, then run the
  `/plugin install …` + `/reload-plugins` commands the installer prints.
- Expect subagent-driven runs to cost **meaningfully more tokens** than a single-agent session; each
  engineer run also dispatches `qa` per task and again for the large suite.

## Verification is real (`I-7`)

Gates run the project's _actual_ commands, auto-detected in P1: **FAST** = lint + typecheck (+ the
component/unit test when the project configures one); **LARGE** = the full suite (lint + typecheck +
component + integration + e2e). Never self-assert "tests pass" — run them.

## Conventions

- **Language:** English for all code, scripts, skills, agent prompts, and docs. (Maintainer conversation
  may be Vietnamese; artifacts stay English.)
- **Shell:** POSIX-ish bash; `jq` and `git` are required. Hooks stay fast; observer hooks are
  fire-and-forget and always exit 0 (`I-8`).
- **Paths in hooks/plugins:** always `${CLAUDE_PLUGIN_ROOT}`; never hard-code install locations. A
  plugin's own `CLAUDE.md` is ignored (`I-9`).
- **Naming:** kebab-case for files, directories, plugins, skills, agents.
- **Don't reimplement** what superpowers (`D-3`) or OpenSpec (`D-4`) already provide — wrap them.
- **Profiles:** `.envrc` sets `CLAUDE_CONFIG_DIR` (here → `~/.claude-personal`) via direnv for
  CLI-account isolation; `.envrc` is gitignored.

## Dependencies

Claude Code (Node.js) with plugin + hooks support · `obra/superpowers` · `Fission-AI/OpenSpec` (mostly
M2) · `jq` + `git` (required) · `direnv` (optional) · a Claude subscription/API for `claude -p` runs.
