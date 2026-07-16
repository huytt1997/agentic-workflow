#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$ROOT/tests/fixtures/openspec/fixture-lib.sh"
WORK="$(pm_fixture_setup)"; BARE="$(mktemp -d)"
trap 'rm -rf "$WORK" "$BARE"' EXIT

# default: dry-run (no engineer launched, no outcome files created); use the
# fixture's stub openspec/claude on PATH so preflight succeeds and the run
# actually reaches the dry-run dispatch path.
out="$(AGENTIC_PROJECT_ROOT="$WORK" PATH="$(pm_fixture_bin):$PATH" bash "$DIR/../bin/pm-run.sh")"
rc=$?
assert_contains "$out" "DRY-RUN" "command defaults to dry-run"
assert_exit 0 "$rc" "successful dry-run exits 0"
assert_contains "$out" "next steps" "successful dry-run prints next-steps hint"
assert_exit 1 "$([ -e "$WORK/openspec/.pm/outcomes" ] && [ -n "$(ls -A "$WORK/openspec/.pm/outcomes" 2>/dev/null)" ]; echo $?)" "no outcomes written on dry-run"

# M3/N1 regression: a preflight failure (target not openspec-initialized, e.g.
# missing "openspec" dir) must propagate pm-runner's non-zero exit code, and
# must NOT print the misleading "re-run with PM_DRY_RUN=0" next-steps hint --
# before the fix, pm-run.sh always exited 0 and always printed the hint.
out2="$(AGENTIC_PROJECT_ROOT="$BARE" PATH="$(pm_fixture_bin):$PATH" bash "$DIR/../bin/pm-run.sh" 2>/dev/null)"
rc2=$?
assert_exit 1 "$([ "$rc2" -ne 0 ] && echo 1 || echo 0)" "preflight failure propagates non-zero exit (got rc=$rc2)"
assert_exit 1 "$(printf '%s' "$out2" | grep -qi "next steps" && echo 0 || echo 1)" "no misleading next-steps hint on failure"

C="$DIR/../commands/run.md"
assert_exit 0 "$([ -f "$C" ]; echo $?)" "command doc exists"
assert_contains "$(cat "$C")" "name: run" "command doc has name frontmatter"
assert_summary
