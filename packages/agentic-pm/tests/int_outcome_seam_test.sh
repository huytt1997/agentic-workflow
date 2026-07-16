#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$ROOT/tests/fixtures/openspec/fixture-lib.sh"
WORK="$(pm_fixture_setup)"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$(pm_fixture_bin):$PATH"
. "$DIR/../bin/pm-runner.sh"; pg_init
WO="$DIR/../../agentic-engineer/lib/write-outcome.sh"

# Real engineer writer -> PM classifier: success
bash "$WO" "$WORK" alpha success 3 5
assert_eq "true" "$(read_outcome_large alpha)" "success record has large_passed true"
assert_eq "archive" "$(classify alpha)" "engineer success record -> archive"

# Real engineer writer -> PM classifier: needs_human
bash "$WO" "$WORK" beta needs_human 1 0 "waiting on API key"
assert_eq "false" "$(read_outcome_large beta)" "needs_human record has large_passed false"
assert_eq "block" "$(classify beta)" "engineer needs_human record -> block"
assert_summary
