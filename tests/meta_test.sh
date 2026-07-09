#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
assert_exit 0 "$( [ -x "$ROOT/tests/run-all.sh" ] && echo 0 || echo 1 )" "run-all.sh is executable"
assert_summary
