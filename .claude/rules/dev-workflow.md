# Dev workflow & conventions

_Applicability: read when running, testing, installing, or packaging the plugins, or writing any code or
docs in this repo._
_Authoritative source: [specs/plan.md](../../specs/plan.md) §12 and [specs/execution-plan.md](../../specs/execution-plan.md) §6._

> **Note:** the dev loop below assumes `packages/` is built and installable (see
> [roadmap.md](roadmap.md) for what remains — live end-to-end runs against a real engineer).

## Dev loop (plugins)

- **Test a plugin without installing:** `claude --plugin-dir packages/<name>`
- **After editing agent/hook files on disk:** run `/reload-plugins` (changes are not hot-reloaded).
- **Validate hook JSON before anything else:** `jq . packages/*/hooks/*.json` (no
  `.claude-plugin/plugin.json` manifests exist — the installer discovers components by directory scan).
- **Install:** `packages/install.sh --target <dir> --package <name>` — **copy-only** (D-13 as
  amended; symlink mode was removed, so there is no live-editable install). Dependencies resolve
  automatically: installing `engineer`/`init`/`ba`/`pm` pulls in `agentic-core`, and `pm` also pulls
  `agentic-engineer`.
- **Iterating on an installed target:** edits to `packages/` do **not** propagate — re-run
  `packages/install.sh` after each change, then `/reload-plugins`. Prefer `claude --plugin-dir
  packages/<name>` while developing to skip the install round-trip entirely.
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
