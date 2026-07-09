#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$DIR/fixtures/fixture-lib.sh"
WORK="$(pm_fixture_setup "$DIR")"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$DIR/fixtures/bin:$PATH"
. "$DIR/../bin/pm-runner.sh"; pg_init
export PM_DRY_RUN=1
out="$(dispatch alpha)"
assert_contains "$out" "DRY-RUN" "dry-run is labelled"
assert_contains "$out" "--change alpha --mode auto" "prints substituted engineer command"
assert_exit 1 "$([ -f "$WORK/openspec/.pm/outcomes/alpha.json" ]; echo $?)" "dry-run writes no outcome file"
assert_summary
