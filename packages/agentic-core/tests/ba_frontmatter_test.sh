#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$DIR/../lib/frontmatter.sh"
. "$DIR/../lib/frontmatter.sh"   # parser oracle from Plan 02
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{ ba_frontmatter 20 alpha beta; echo "# title"; } > "$T/p.md"
assert_eq "20" "$(fm_priority "$T/p.md")" "emitted priority round-trips"
assert_eq "alpha beta" "$(fm_depends "$T/p.md")" "emitted depends_on round-trips"
{ ba_frontmatter 100; echo "# t"; } > "$T/q.md"
assert_eq "100" "$(fm_priority "$T/q.md")" "no-deps block still carries priority"
assert_eq "" "$(fm_depends "$T/q.md")" "no-deps block has empty depends"
assert_summary
