#!/usr/bin/env bash
# plugin_json_valid_test.sh — proves feature `plugin-json-valid`:
# agentic-core's plugin.json + the root marketplace.json exist, are valid JSON,
# and the marketplace registers the agentic-core plugin.
#
# Self-contained (no dependency on the not-yet-built tests/lib/assert.sh, which
# belongs to a different feature): plain bash + jq only.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail=0

pj="$ROOT/packages/agentic-core/.claude-plugin/plugin.json"
mj="$ROOT/.claude-plugin/marketplace.json"

if [ ! -f "$pj" ]; then
  echo "FAIL: plugin.json missing at $pj"; fail=1
elif ! jq -e . "$pj" >/dev/null 2>&1; then
  echo "FAIL: plugin.json is not valid JSON"; fail=1
elif [ "$(jq -r '.name' "$pj")" != "agentic-core" ]; then
  echo "FAIL: plugin.json .name != agentic-core"; fail=1
else
  echo "PASS: plugin.json exists, is valid JSON, and is named agentic-core"
fi

if [ ! -f "$mj" ]; then
  echo "FAIL: marketplace.json missing at $mj"; fail=1
elif ! jq -e . "$mj" >/dev/null 2>&1; then
  echo "FAIL: marketplace.json is not valid JSON"; fail=1
elif ! jq -e '.plugins[] | select(.name=="agentic-core")' "$mj" >/dev/null 2>&1; then
  echo "FAIL: marketplace.json does not register the agentic-core plugin"; fail=1
else
  echo "PASS: marketplace.json exists, is valid JSON, and registers agentic-core"
fi

exit $fail
