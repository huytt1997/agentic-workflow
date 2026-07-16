#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
A="$DIR/../agents/ba-analyst.md"
assert_exit 0 "$([ -f "$A" ]; echo $?)" "ba-analyst.md exists"
body="$(cat "$A" 2>/dev/null)"
assert_contains "$body" "name: ba-analyst" "has agent name frontmatter"
assert_contains "$body" "opus" "pins opus model"
assert_contains "$body" "high" "pins high effort"
assert_contains "$body" "acceptance criteria" "mandates testable acceptance criteria"
assert_contains "$body" "openspec validate" "instructs validation of output"
assert_summary
