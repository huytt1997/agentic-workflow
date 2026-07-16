#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
S="$DIR/../skills/agentic-ba/SKILL.md"
assert_exit 0 "$([ -f "$S" ]; echo $?)" "SKILL.md exists"
body="$(cat "$S" 2>/dev/null)"
assert_contains "$body" "name: agentic-ba" "has skill name frontmatter"
assert_contains "$body" "Use the agentic-ba skill to sync OpenSpec changes" "documents headless invocation"
assert_contains "$body" "Task,Read,Write,Bash,Grep,Glob" "documents allowed tools"
assert_contains "$body" "idempoten" "states idempotence rule"
assert_contains "$body" "archive" "states never-touch-archive rule"
assert_summary
