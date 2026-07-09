# shellcheck shell=bash
# Zero-dependency bash assert helper for the agentic-workflow test harness.
# Source this file, call assert_* functions, then assert_summary at the end
# (assert_summary's exit status reflects overall pass/fail).
ASSERT_FAILS=0; ASSERT_TOTAL=0
_a_ok(){ ASSERT_TOTAL=$((ASSERT_TOTAL+1)); }
_a_fail(){ ASSERT_TOTAL=$((ASSERT_TOTAL+1)); ASSERT_FAILS=$((ASSERT_FAILS+1)); echo "  FAIL: $1"; }
assert_eq(){ _a_ok; [ "$1" = "$2" ] || { ASSERT_FAILS=$((ASSERT_FAILS+1)); echo "  FAIL: ${3:-} (want '$1' got '$2')"; }; }
assert_contains(){ _a_ok; case "$1" in *"$2"*) ;; *) ASSERT_FAILS=$((ASSERT_FAILS+1)); echo "  FAIL: ${3:-} ('$2' not in '$1')";; esac; }
assert_exit(){ _a_ok; [ "$1" = "$2" ] || { ASSERT_FAILS=$((ASSERT_FAILS+1)); echo "  FAIL: ${3:-} (want exit $1 got $2)"; }; }
assert_summary(){ echo "PASS $((ASSERT_TOTAL-ASSERT_FAILS)) / FAIL $ASSERT_FAILS"; [ "$ASSERT_FAILS" -eq 0 ]; }
