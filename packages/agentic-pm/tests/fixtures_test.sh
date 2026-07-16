#!/usr/bin/env bash
# Exercises the shared fixture harness directly (stub `openspec`, stub `claude`,
# fixture target project). See tests/fixtures/openspec/README.md for how
# agentic-ba and agentic-pm tests should reuse this fixture harness.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$ROOT/tests/fixtures/openspec/fixture-lib.sh"
WORK="$(pm_fixture_setup)"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$(pm_fixture_bin):$PATH"

openspec validate alpha --strict; assert_exit 0 "$?" "validate existing change passes"
openspec validate ghost --strict; assert_exit 1 "$?" "validate missing change fails"
openspec archive alpha --yes; assert_exit 0 "$?" "archive existing change passes"
assert_exit 0 "$([ -d "$WORK/openspec/changes/archive/alpha" ]; echo $?)" "archived dir moved"
assert_exit 1 "$([ -d "$WORK/openspec/changes/alpha" ]; echo $?)" "active dir removed after archive"

OUT="$WORK/openspec/.pm/outcomes/gamma.json"; mkdir -p "$(dirname "$OUT")"
export AGENTIC_PM_OUTCOME_FILE="$OUT"; export STUB_OUTCOME_STATUS="success"; export STUB_COST_USD="0.02"
line="$(claude -p "/agentic-engineer:engineer --change gamma --mode auto")"
assert_contains "$line" "total_cost_usd" "stub claude prints cost line"
assert_eq "success" "$(jq -r .status "$OUT" 2>/dev/null)" "outcome status written"
assert_eq "true" "$(jq -r .verification.large_passed "$OUT" 2>/dev/null)" "large_passed derived true on success"

assert_summary
