# shellcheck shell=bash
# Shared setup for management fixture tests. Source it, then call pm_fixture_setup.
# Full usage guide: packages/agentic-management/tests/fixtures/README.md.
#
# Usage (from any *_test.sh under packages/agentic-management/tests/):
#   DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$DIR/fixtures/fixture-lib.sh"
#   WORK="$(pm_fixture_setup "$DIR")"; trap 'rm -rf "$WORK"' EXIT
#   export AGENTIC_PROJECT_ROOT="$WORK"
#   export PATH="$DIR/fixtures/bin:$PATH"
#
# IMPORTANT — do NOT move the two `export` lines into pm_fixture_setup itself:
# `WORK="$(pm_fixture_setup "$DIR")"` runs the function in a command-substitution
# SUBSHELL to capture its stdout; any `export` done inside that subshell is
# discarded the instant the subshell exits and never reaches the calling test
# script. pm_fixture_setup therefore only creates the temp dir, copies the
# fixture target into it, and prints its path — exporting the env vars is the
# caller's job, done in the *parent* shell after the substitution returns.
#
# pm_fixture_setup <test-dir>:
#   - copies fixtures/target/ into a fresh temp dir
#   - echoes the temp dir's path so the caller can capture it as "$WORK" and
#     export AGENTIC_PROJECT_ROOT="$WORK" + prepend fixtures/bin/ onto PATH
#     (stub `openspec` + stub `claude`, shadowing any real binaries of the
#     same name)
#
# To drive stub-engineer outcomes, export STUB_OUTCOME_STATUS / STUB_COST_USD /
# STUB_LARGE_PASSED / STUB_EXIT_CODE before invoking the stub `claude` (see
# fixtures/bin/claude's header comment for the full contract).
pm_fixture_setup() {
  local here="$1" work
  work="$(mktemp -d)"
  cp -R "$here/fixtures/target/." "$work/"
  printf '%s' "$work"
}
