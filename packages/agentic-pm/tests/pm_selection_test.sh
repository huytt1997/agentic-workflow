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

# alpha (prio 10, no deps) is eligible; beta depends on alpha (not done) -> alpha first
assert_eq "alpha" "$(next_change)" "alpha selected first (lower prio, deps met)"
pg_push done alpha
assert_eq "beta" "$(next_change)" "beta becomes eligible once alpha is done"
pg_push done beta
assert_eq "" "$(next_change)" "nothing left when all done"
assert_summary
