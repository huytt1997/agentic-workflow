#!/usr/bin/env bash
# json_gate_test.sh — proves feature `json-gate`:
# tests/validate-json.sh runs `jq .` over every hooks.json under packages/*/hooks/,
# passing on a clean tree and failing non-zero on malformed JSON.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/tests/lib/assert.sh"

bash "$ROOT/tests/validate-json.sh"
assert_exit 0 $? "valid tree passes json gate"

tmp="$ROOT/packages/agentic-core/hooks/bad.json"
echo '{bad' > "$tmp"
bash "$ROOT/tests/validate-json.sh" >/dev/null 2>&1
assert_exit 1 $? "malformed json fails gate"
rm -f "$tmp"

assert_summary
