#!/usr/bin/env bash
# tests/integration/checklist_test.sh — structural check that the manual live
# smoke-test checklist (docs/smoke-test-checklist.md) exists and covers the
# WS-B acceptance items (§4.3) that only a live claude -p run can prove. This
# is NOT a live-run test (no LLM/network) — it just proves the doc exists and
# names the right things, per plan 07 task 4.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

DOC="$ROOT/docs/smoke-test-checklist.md"
assert_exit 0 "$( [ -f "$DOC" ] && echo 0 || echo 1 )" "checklist exists"

b="$(cat "$DOC" 2>/dev/null || true)"
assert_contains "$b" "interactive" "covers interactive mode"
assert_contains "$b" "auto" "covers auto mode"
assert_contains "$b" "reload-plugins" "install/reload step"
assert_contains "$b" "outcomes/" "verifies auto outcome file written"

assert_summary
