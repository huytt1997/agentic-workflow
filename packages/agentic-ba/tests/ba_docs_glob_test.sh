#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

S="$DIR/../skills/agentic-ba/SKILL.md"
sbody="$(cat "$S" 2>/dev/null)"
assert_contains "$sbody" 'docs/**/*.md' "SKILL documents the default docs glob"
assert_contains "$sbody" "agentic-init" "SKILL points at agentic-init for the docs/ scaffold"

A="$DIR/../agents/ba-analyst.md"
abody="$(cat "$A" 2>/dev/null)"
assert_contains "$abody" 'docs/**/*.md' "ba-analyst documents the default docs glob"

# docs/ must not be confused with openspec/specs/ (I-11)
assert_contains "$sbody" "openspec/specs/" "SKILL distinguishes docs/ from openspec/specs/"

assert_summary
