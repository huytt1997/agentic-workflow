# agentic-management test fixtures

Deterministic, offline fixture harness shared by every test in this plugin (`02-pm-runner`,
`03-agentic-ba`, `05-integration`). Nothing here calls a real `openspec` binary or a real
`claude -p` engineer — see decisions D-A/D-B in `.agentic/plans/00-overview.md`. Live-CLI
acceptance is explicitly deferred.

## Contents

- `bin/openspec` — TEST-ONLY stub of the OpenSpec CLI. Supports:
  - `openspec validate <id> --strict` — exit 0 iff
    `$AGENTIC_PROJECT_ROOT/openspec/changes/<id>/proposal.md` exists, else exit 1.
  - `openspec archive <id> --yes` — moves
    `$AGENTIC_PROJECT_ROOT/openspec/changes/<id>/` to
    `$AGENTIC_PROJECT_ROOT/openspec/changes/archive/<id>/` and exits 0; exits non-zero
    (and leaves the change dir alone) if `<id>` doesn't exist under `changes/`. This is what
    later drives F10's archive-failure-routing test.
  - Any other subcommand exits 2 with an "unsupported" message.
- `bin/claude` — TEST-ONLY stub engineer emulating one `claude -p /agentic-engineer:engineer
  --change <id> --mode auto` invocation. Regardless of its arguments it:
  1. Writes a well-formed `pm-outcome/1` record to `$AGENTIC_PM_OUTCOME_FILE`.
  2. Prints one JSON line `{"total_cost_usd":<STUB_COST_USD>}` to stdout (pm-runner parses
     this to accumulate spend for the budget-cap feature, F7).
  3. Exits `$STUB_EXIT_CODE` (default 0).

  Drive its behaviour with env vars (the convention every later plan's tests should use to
  parameterize outcomes — do not invent a second mechanism):
  | var | default | effect |
  | --- | --- | --- |
  | `STUB_OUTCOME_STATUS` | `success` | written as `.status` in the outcome record (`success`\|`needs_human`\|`failed`) |
  | `STUB_COST_USD` | `0.01` | value in the printed `total_cost_usd` stdout line |
  | `STUB_LARGE_PASSED` | (unset) | set to `false` to force `.verification.large_passed=false` even when `STUB_OUTCOME_STATUS=success` — drives the contract-violation routing path (success but large tests didn't pass) |
  | `STUB_EXIT_CODE` | `0` | the stub's own process exit code |

  See the header comment in `bin/claude` for the authoritative contract.
- `target/` — a fixture target project shaped like a real repo that ran `openspec init`:
  - `openspec/changes/alpha/proposal.md` — no `depends_on`, `priority: 10`.
  - `openspec/changes/beta/proposal.md` — `depends_on: [alpha]`, `priority: 20`. Exercises
    dependency-ordered selection (F19's topological-order test consumes this shape).
  - `openspec/specs/` — empty (holds `.gitkeep`).
- `fixture-lib.sh` — shared `pm_fixture_setup` helper (see its header comment for the full
  usage pattern and the subshell/export caveat below). Source it once per test file.

## How to use these fixtures in a new test

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$DIR/fixtures/fixture-lib.sh"

WORK="$(pm_fixture_setup "$DIR")"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$DIR/fixtures/bin:$PATH"

# ... exercise pm-runner.sh / BA helpers against $AGENTIC_PROJECT_ROOT here ...

assert_summary
```

`pm_fixture_setup` copies `fixtures/target/` into a fresh temp dir per test (never mutates the
checked-in fixture) and echoes that dir's path. **Always export `AGENTIC_PROJECT_ROOT` and
prepend `PATH` yourself, in the caller, after capturing `$WORK`** — `pm_fixture_setup` cannot
export into the calling shell because `WORK="$(pm_fixture_setup "$DIR")"` runs the function in
a command-substitution subshell; any `export` inside it is discarded when the subshell exits.
This is documented again in `fixture-lib.sh`'s header comment; don't move the exports back
inside the function.

To exercise the stub engineer directly, set `AGENTIC_PM_OUTCOME_FILE` to a path under
`$WORK/openspec/.pm/outcomes/<id>.json` before invoking `claude -p ...`.

## What later plans should NOT do

- Don't add a second stub-engineer parameterization mechanism (env var or config file) — reuse
  `STUB_OUTCOME_STATUS` / `STUB_COST_USD` / `STUB_LARGE_PASSED` / `STUB_EXIT_CODE`.
- Don't invoke the real `openspec` or `claude` binaries from these tests; add another fixture
  change under `target/openspec/changes/` if a scenario needs different frontmatter instead of
  reaching outside the fixture tree.
- Don't touch `target/openspec/changes/archive/` in the checked-in fixture — archives only ever
  happen inside the per-test `$WORK` copy.
