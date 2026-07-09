#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
[ -f "$ROOT/tests/validate-json.sh" ] && { bash "$ROOT/tests/validate-json.sh" || fail=1; }
while IFS= read -r t; do
  echo "== $t =="; bash "$t" || fail=1
done < <(find "$ROOT/packages" "$ROOT/tests" -name '*_test.sh' 2>/dev/null | sort)
exit $fail
