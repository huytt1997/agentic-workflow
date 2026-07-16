#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
PKG="$DIR/.."

# --- command: named to avoid the built-in /init collision ---
C="$PKG/commands/agentic-init.md"
assert_exit 0 "$([ -f "$C" ]; echo $?)" "commands/agentic-init.md exists"
assert_exit 1 "$([ -f "$PKG/commands/init.md" ]; echo $?)" "commands/init.md must NOT exist (collides with built-in /init)"
cbody="$(cat "$C" 2>/dev/null)"
assert_contains "$cbody" "name: agentic-init" "command has name frontmatter"

# --- skill ---
S="$PKG/skills/agentic-init/SKILL.md"
assert_exit 0 "$([ -f "$S" ]; echo $?)" "skills/agentic-init/SKILL.md exists"
sbody="$(cat "$S" 2>/dev/null)"
assert_contains "$sbody" "name: agentic-init" "skill has name frontmatter"
assert_contains "$sbody" "@fission-ai/openspec" "documents the openspec install command"
assert_contains "$sbody" "openspec init" "documents openspec init"
assert_contains "$sbody" "docs/" "creates the docs/ folder BA reads"
assert_contains "$sbody" "idempotent" "states the idempotence rule"

assert_summary
