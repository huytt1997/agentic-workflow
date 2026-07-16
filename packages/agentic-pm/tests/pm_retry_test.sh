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
export PM_DRY_RUN=0 PM_BACKOFF_SEC=0 PM_MAX_RETRIES=2 PM_ON_FAIL=stop PM_HALT=0
export STUB_OUTCOME_STATUS=failed

# Deviation from plan's literal snippet: `$(handle_change alpha)` runs
# handle_change in a command-substitution subshell, so its PM_HALT=1 side
# effect never reaches this (parent) shell. Redirect stdout to a temp file
# instead so the call runs in the current shell and PM_HALT survives.
_retry_out="$(mktemp)"
handle_change alpha > "$_retry_out"
assert_eq "failed" "$(cat "$_retry_out")" "persistent failure -> failed"
rm -f "$_retry_out"
assert_eq "alpha" "$(pg_bucket failed)" "alpha pushed to failed"
# attempts == 1 initial + PM_MAX_RETRIES(2) = 3
assert_eq "3" "$(jq -r '.meta.alpha.attempts' "$(pg_file)")" "attempts counted (1 + retries)"
assert_eq "1" "$PM_HALT" "PM_ON_FAIL=stop sets halt"
assert_summary
