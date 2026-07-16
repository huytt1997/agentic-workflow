# shellcheck shell=bash
# Shared OpenSpec-target fixture harness. Source it, then call pm_fixture_setup.
# Full usage guide: tests/fixtures/openspec/README.md.
#
# Shared on purpose: both agentic-ba and agentic-pm tests use this harness, and
# neither package may depend on the other -- so it lives at the repo root next
# to tests/lib/assert.sh rather than inside either package.
#
# Usage (from any *_test.sh):
#   ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
#   . "$ROOT/tests/fixtures/openspec/fixture-lib.sh"
#   WORK="$(pm_fixture_setup)"; trap 'rm -rf "$WORK"' EXIT
#   export AGENTIC_PROJECT_ROOT="$WORK"
#   export PATH="$(pm_fixture_bin):$PATH"
#
# IMPORTANT — do NOT move the two `export` lines into pm_fixture_setup itself:
# `WORK="$(pm_fixture_setup)"` runs the function in a command-substitution
# SUBSHELL to capture its stdout; any `export` done inside that subshell is
# discarded the instant the subshell exits and never reaches the calling test
# script. pm_fixture_setup therefore only creates the temp dir, copies the
# fixture target into it, and prints its path — exporting the env vars is the
# caller's job, done in the *parent* shell after the substitution returns.
#
# To drive stub-engineer outcomes, export STUB_OUTCOME_STATUS / STUB_COST_USD /
# STUB_LARGE_PASSED / STUB_EXIT_CODE before invoking the stub `claude` (see
# bin/claude's header comment for the full contract).

# _fx_dir — this fixtures directory, resolved from THIS file's location rather
# than the caller's, so callers may live in any package.
_fx_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

# pm_fixture_setup — copies target/ into a fresh temp dir; prints its path.
pm_fixture_setup() {
  local work
  work="$(mktemp -d)"
  cp -R "$(_fx_dir)/target/." "$work/"
  printf '%s' "$work"
}

# pm_fixture_bin — the stub-binary dir (stub `openspec` + stub `claude`),
# to be prepended onto PATH by the caller so it shadows any real binaries.
pm_fixture_bin() { printf '%s' "$(_fx_dir)/bin"; }
