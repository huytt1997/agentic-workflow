#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$DIR/fixtures/fixture-lib.sh"
WORK="$(pm_fixture_setup "$DIR")"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$DIR/fixtures/bin:$PATH"
. "$DIR/../bin/pm-runner.sh"

assert_eq "alpha beta" "$(os_list_active | tr '\n' ' ' | xargs)" "lists active changes sorted, excludes archive"
os_validate alpha; assert_exit 0 "$?" "wrapper validate ok"
os_archive alpha; assert_exit 0 "$?" "wrapper archive ok"
assert_eq "beta" "$(os_list_active | tr '\n' ' ' | xargs)" "archived change no longer active"
assert_summary
