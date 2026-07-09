#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$DIR/../lib/frontmatter.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf -- '---\npriority: 10\n---\n# a\n' > "$T/a.md"
printf -- '---\ndepends_on: [alpha, beta]\npriority: 20\n---\n# b\n' > "$T/b.md"
printf -- '# no frontmatter\n' > "$T/c.md"
assert_eq "10" "$(fm_priority "$T/a.md")" "reads priority"
assert_eq "100" "$(fm_priority "$T/c.md")" "default priority 100"
assert_eq "alpha beta" "$(fm_depends "$T/b.md")" "reads depends_on list"
assert_eq "" "$(fm_depends "$T/a.md")" "no depends_on -> empty"
assert_summary
