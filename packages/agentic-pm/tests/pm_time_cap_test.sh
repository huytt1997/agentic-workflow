#!/usr/bin/env bash
# C1 regression: PM_TIME_CAP_MIN must actually trip budget_exceeded. Real wall-clock
# sleeping in a unit test is awkward/flaky, so this drives the real elapsed-time
# code path deterministically by writing a stale start_epoch marker directly into
# progress.json and asserting pg_elapsed_update recomputes elapsed_min from it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$ROOT/tests/fixtures/openspec/fixture-lib.sh"
WORK="$(pm_fixture_setup)"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$(pm_fixture_bin):$PATH"
. "$DIR/../bin/pm-runner.sh"; pg_init

# First call establishes the start_epoch marker (loop start) and elapsed_min=0.
pg_elapsed_update
assert_eq "0" "$(jq -r '.budget.elapsed_min' "$(pg_file)")" "fresh start -> elapsed_min 0"
started="$(jq -r '.budget.start_epoch' "$(pg_file)")"
assert_exit 0 "$([ "$started" = "null" ] && echo 1 || echo 0)" "start_epoch persisted (not null)"

unset PM_TIME_CAP_MIN
budget_exceeded; assert_exit 1 "$?" "no time cap -> never exceeded"

# Simulate 61 minutes of real elapsed time by rewriting the stored start marker
# to 61 minutes in the past, then recomputing (this is the real code path a long
# running main() loop would exercise on its next iteration).
f="$(pg_file)"; tmp="$(mktemp)"
jq --argjson back 3660 '.budget.start_epoch = (.budget.start_epoch - $back)' "$f" > "$tmp" && mv "$tmp" "$f"
pg_elapsed_update
elapsed="$(jq -r '.budget.elapsed_min' "$(pg_file)")"
assert_exit 0 "$([ "$elapsed" -ge 60 ] && echo 0 || echo 1)" "elapsed_min recomputed from stale start (>=60, got $elapsed)"

export PM_TIME_CAP_MIN=60
budget_exceeded; assert_exit 0 "$?" "elapsed over time cap -> exceeded"

export PM_TIME_CAP_MIN=120
budget_exceeded; assert_exit 1 "$?" "elapsed under higher time cap -> not exceeded"

assert_summary
