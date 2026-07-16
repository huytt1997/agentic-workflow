#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
S="$DIR/../skills/agentic-pm/SKILL.md"
assert_exit 0 "$([ -f "$S" ]; echo $?)" "SKILL.md exists"
body="$(cat "$S" 2>/dev/null)"
assert_contains "$body" "name: agentic-pm" "has skill name frontmatter"
assert_contains "$body" "openspec init" "documents the openspec-init prerequisite"
assert_contains "$body" "PM_DRY_RUN" "documents dry-run first"
assert_contains "$body" "openspec/.pm/" "documents where state lives"
assert_contains "$body" "PM_COST_CAP_USD" "documents budget knobs"
assert_contains "$body" "blocked" "documents summary interpretation"
assert_summary
