#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/packages/lib/install-common.sh"

# --- direct deps (feature: dep-map) ---
assert_eq ""                 "$(ic_pkg_deps core)"     "core has no deps"
assert_eq "agentic-core"     "$(ic_pkg_deps engineer)" "engineer -> core"
assert_eq "agentic-core"     "$(ic_pkg_deps init)"     "init -> core"
assert_eq "agentic-core"     "$(ic_pkg_deps ba)"       "ba -> core"
assert_eq "agentic-core
agentic-engineer"            "$(ic_pkg_deps pm)"       "pm -> core + engineer"
ic_pkg_deps bogus >/dev/null 2>&1; assert_exit 1 "$?" "unknown package rejected"

# --- transitive closure, dependency order (feature: dep-resolve) ---
assert_eq "agentic-core"     "$(ic_with_deps agentic-core)" "core alone stays core"
assert_eq "agentic-core
agentic-engineer"            "$(ic_with_deps agentic-engineer)" "engineer pulls core, core first"
assert_eq "agentic-core
agentic-ba"                  "$(ic_with_deps agentic-ba)" "ba pulls core"
assert_eq "agentic-core
agentic-engineer
agentic-pm"                  "$(ic_with_deps agentic-pm)" "pm pulls core + engineer, in order"

# dedupe: an explicit dep already in the selection is not repeated
assert_eq "agentic-core
agentic-engineer"            "$(ic_with_deps agentic-core agentic-engineer)" "explicit core not duplicated"
assert_eq "agentic-core
agentic-engineer
agentic-pm"                  "$(ic_with_deps agentic-pm agentic-engineer)" "dep listed twice appears once"

# a full selection is already ordered and must pass through unchanged
assert_eq "$(ic_expand_selection all)" "$(ic_with_deps $(ic_expand_selection all))" "all is already dependency-ordered"

assert_summary
