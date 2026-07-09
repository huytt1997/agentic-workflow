#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
M="$DIR/../.claude-plugin/plugin.json"
assert_exit 0 "$([ -f "$M" ]; echo $?)" "plugin.json exists"
assert_eq "agentic-management" "$(jq -r .name "$M" 2>/dev/null)" "name is agentic-management"
assert_eq "agentic-core agentic-engineer" \
  "$(jq -r '.dependencies | join(" ")' "$M" 2>/dev/null)" "declares core+engineer deps"
assert_exit 0 "$(jq -e 'has("version") and has("description")' "$M" >/dev/null 2>&1; echo $?)" "has version+description"

MP="$DIR/../../../.claude-plugin/marketplace.json"
assert_eq "./packages/agentic-management" \
  "$(jq -r '.plugins[] | select(.name=="agentic-management") | .source' "$MP" 2>/dev/null)" \
  "management registered in marketplace"

assert_summary
