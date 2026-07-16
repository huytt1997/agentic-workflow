#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$ROOT/tests/fixtures/openspec/fixture-lib.sh"
WORK="$(pm_fixture_setup)"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$(pm_fixture_bin):$PATH"
. "$DIR/../bin/pm-runner.sh"

pg_init
assert_eq "pm-progress/1" "$(jq -r .schema "$(pg_file)")" "progress schema written"
pg_push done alpha; pg_push done alpha    # idempotent
assert_eq "alpha" "$(pg_bucket done)" "push adds id once"
pg_in_bucket alpha; assert_exit 0 "$?" "pg_in_bucket finds pushed id"
pg_in_bucket zeta; assert_exit 1 "$?" "pg_in_bucket misses absent id"
pg_meta_set alpha success "" 0.05
assert_eq "success" "$(jq -r '.meta.alpha.last_status' "$(pg_file)")" "meta status recorded"
pg_budget_add 0.05; pg_budget_add 0.10
assert_eq "0.15" "$(jq -r '.budget.spent_usd' "$(pg_file)")" "budget accrues"
assert_summary
