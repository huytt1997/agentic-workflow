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
export PM_DRY_RUN=0 PM_MAX_RETRIES=1 PM_ON_BLOCK=stop

# Deviation from plan's literal snippet: bare `STUB_OUTCOME_STATUS=...` (not a
# command prefix) is a local shell variable, never exported to the `claude`
# stub subprocess `dispatch` launches, so it silently falls back to the stub's
# own "success" default. Export it so the child process actually sees it.
export STUB_OUTCOME_STATUS=success
assert_eq "done" "$(handle_change alpha)" "success -> done"
assert_eq "alpha" "$(pg_bucket done)" "alpha pushed to done"
assert_exit 0 "$([ -d "$WORK/openspec/changes/archive/alpha" ]; echo $?)" "alpha archived"

PM_HALT=0
export STUB_OUTCOME_STATUS=needs_human
# Deviation from plan's literal snippet: `verdict="$(handle_change beta)"` runs
# handle_change in a command-substitution SUBSHELL, so its `PM_HALT=1` side
# effect is discarded the instant the subshell exits and never reaches this
# (parent) shell -- the assertion below would fail no matter how handle_change
# is implemented. Redirect stdout to a temp file instead (no subshell fork for
# a plain redirected call), so the PM_HALT global mutation survives.
_handle_out="$(mktemp)"
handle_change beta > "$_handle_out"
assert_eq "blocked" "$(cat "$_handle_out")" "needs_human -> blocked"
rm -f "$_handle_out"
assert_eq "beta" "$(pg_bucket blocked)" "beta pushed to blocked"
assert_eq "1" "$PM_HALT" "PM_ON_BLOCK=stop sets halt flag"
assert_summary
