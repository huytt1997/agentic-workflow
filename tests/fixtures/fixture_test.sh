#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
pj="$ROOT/tests/fixtures/npm-sample/package.json"
assert_exit 0 "$( [ -f "$pj" ] && echo 0 || echo 1)" "fixture package.json exists"
for s in lint typecheck test; do
  assert_exit 0 "$(jq -e --arg s "$s" '.scripts[$s]' "$pj" >/dev/null 2>&1 && echo 0 || echo 1)" "has $s script"
done
assert_summary
