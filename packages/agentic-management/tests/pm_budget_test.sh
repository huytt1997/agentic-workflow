#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$DIR/fixtures/fixture-lib.sh"
WORK="$(pm_fixture_setup "$DIR")"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$DIR/fixtures/bin:$PATH"
. "$DIR/../bin/pm-runner.sh"; pg_init

unset PM_COST_CAP_USD
budget_exceeded; assert_exit 1 "$?" "no cap -> never exceeded"
export PM_COST_CAP_USD=0.10
pg_budget_add 0.05; budget_exceeded; assert_exit 1 "$?" "under cap -> not exceeded"
pg_budget_add 0.06; budget_exceeded; assert_exit 0 "$?" "over cap -> exceeded"
pg_push done alpha; pg_push blocked beta
out="$(summary)"
assert_contains "$out" "done=1" "summary reports done count"
assert_contains "$out" "blocked=1" "summary reports blocked count"
assert_summary
