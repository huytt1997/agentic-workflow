#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/../../../tests/lib/assert.sh"
assert_eq "a" "a" "eq matches"
assert_contains "hello world" "world" "contains substring"
assert_exit 0 0 "exit code equal"
assert_summary
