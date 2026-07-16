#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$ROOT/tests/fixtures/openspec/fixture-lib.sh"
WORK="$(pm_fixture_setup)"; trap 'rm -rf "$WORK"' EXIT
# Deviation from plan's literal snippet: the plan omitted these two exports, but
# fixture-lib.sh/README.md's documented contract requires the caller to export
# AGENTIC_PROJECT_ROOT + prepend PATH after the command-substitution subshell
# returns (pm_fixture_setup cannot export into the caller). Without this, the
# stub openspec/claude never shadow the real (absent) binaries and every test
# below fails for the wrong reason.
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$(pm_fixture_bin):$PATH"
. "$DIR/../bin/pm-runner.sh"   # sourceable: must NOT run main

preflight; assert_exit 0 "$?" "preflight passes with stubs + openspec dir"
( rm -rf "$WORK/openspec"; preflight ); assert_exit 1 "$?" "preflight fails when target not initialized"
assert_summary
