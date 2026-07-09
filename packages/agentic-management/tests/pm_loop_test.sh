#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$DIR/fixtures/fixture-lib.sh"
WORK="$(pm_fixture_setup "$DIR")"; trap 'rm -rf "$WORK"' EXIT

# End-to-end mechanism via the executable (stub engineer succeeds on every change).
out="$(cd "$WORK" && STUB_OUTCOME_STATUS=success PM_DRY_RUN=0 PM_ON_BLOCK=continue \
      AGENTIC_PROJECT_ROOT="$WORK" PATH="$DIR/fixtures/bin:$PATH" bash "$DIR/../bin/pm-runner.sh")"
assert_contains "$out" "done=2" "both changes completed"
assert_exit 0 "$([ -d "$WORK/openspec/changes/archive/alpha" ] && [ -d "$WORK/openspec/changes/archive/beta" ]; echo $?)" "both archived"
assert_exit 1 "$([ -d "$WORK/openspec/changes/alpha" ]; echo $?)" "active changes dir shrank"

# compaction trigger: sourced, K=1 -> emits COMPACT after a done
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$DIR/fixtures/bin:$PATH"
. "$DIR/../bin/pm-runner.sh"; PM_COMPACT_EVERY=1
c="$(maybe_compact 2)"
assert_contains "$c" "COMPACT" "compaction fires at multiple of K"
d="$(PM_COMPACT_EVERY=0 maybe_compact 2)"
assert_eq "" "$d" "compaction off when K=0"
assert_summary
