#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$DIR/fixtures/fixture-lib.sh"
WORK="$(pm_fixture_setup "$DIR")"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$DIR/fixtures/bin:$PATH"
. "$DIR/../bin/pm-runner.sh"; pg_init
export PM_DRY_RUN=0

STUB_OUTCOME_STATUS=success dispatch alpha
assert_eq "success" "$(read_outcome_status alpha)" "outcome status read back"
assert_eq "archive" "$(classify alpha)" "success+large -> archive"

STUB_OUTCOME_STATUS=needs_human dispatch beta
assert_eq "block" "$(classify beta)" "needs_human -> block"

# contract violation: status success but large_passed false
STUB_OUTCOME_STATUS=success STUB_LARGE_PASSED=false dispatch alpha
assert_eq "block" "$(classify alpha)" "success but large_passed false -> block"

rm -f "$WORK/openspec/.pm/outcomes/beta.json"
assert_eq "fail" "$(classify beta)" "missing outcome file -> fail"
assert_summary
