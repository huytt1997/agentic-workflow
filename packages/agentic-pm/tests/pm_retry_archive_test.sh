#!/usr/bin/env bash
# M2 regression: a retry attempt that classifies as `archive` but whose
# os_archive call fails must route to `blocked` (archive_failed, honoring
# PM_ON_BLOCK) -- the same contract the first-attempt `archive)` branch
# already honors. Before the fix, the retry loop's `if os_archive; then ...;
# fi` had no `else`, so this fell through and was misclassified as `failed`.
#
# dispatch/os_archive are overridden here (not the fixture claude/openspec
# stubs) so the first attempt deterministically yields `fail` and the retry
# attempt deterministically yields `archive` + a failing archive -- the
# fixture stub's STUB_OUTCOME_STATUS is static for a whole handle_change
# call and can't vary attempt-to-attempt on its own.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$ROOT/tests/fixtures/openspec/fixture-lib.sh"
WORK="$(pm_fixture_setup)"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$(pm_fixture_bin):$PATH"
. "$DIR/../bin/pm-runner.sh"; pg_init
export PM_DRY_RUN=0 PM_BACKOFF_SEC=0 PM_MAX_RETRIES=1 PM_ON_BLOCK=stop PM_HALT=0

_attempt=0
dispatch() {
  _attempt=$((_attempt+1))
  local id="$1" outcome="$AGENTIC_PROJECT_ROOT/openspec/.pm/outcomes/$id.json"
  mkdir -p "$(dirname "$outcome")"
  if [ "$_attempt" -eq 1 ]; then
    jq -n --arg c "$id" '{schema:"pm-outcome/1",change_id:$c,status:"failed",reason:"boom",
      checkpoints:0,pr:null,ts:(now|todate),verification:{large_passed:false,tests_written:0,levels:[]}}' > "$outcome"
  else
    jq -n --arg c "$id" '{schema:"pm-outcome/1",change_id:$c,status:"success",reason:null,
      checkpoints:1,pr:null,ts:(now|todate),verification:{large_passed:true,tests_written:1,levels:["component"]}}' > "$outcome"
  fi
  PM_LAST_COST=0.01
}
os_archive() { return 1; }  # force the retry-time archive failure

_ra_out="$(mktemp)"
handle_change ghost > "$_ra_out"
assert_eq "blocked" "$(cat "$_ra_out")" "retry archive-failure -> blocked (not failed)"
rm -f "$_ra_out"
assert_eq "ghost" "$(pg_bucket blocked)" "ghost pushed to blocked bucket"
assert_eq "" "$(pg_bucket failed)" "ghost NOT pushed to failed bucket"
assert_eq "archive_failed" "$(jq -r '.meta.ghost.last_status' "$(pg_file)")" "meta records archive_failed"
assert_eq "1" "$PM_HALT" "PM_ON_BLOCK=stop sets halt flag"
assert_summary
