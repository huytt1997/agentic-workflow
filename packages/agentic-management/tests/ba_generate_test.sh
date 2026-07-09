#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$DIR/fixtures/fixture-lib.sh"
. "$DIR/../lib/ba-changeid.sh"; . "$DIR/../lib/ba-frontmatter.sh"; . "$DIR/../lib/frontmatter.sh"
WORK="$(pm_fixture_setup "$DIR")"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$DIR/fixtures/bin:$PATH"

id="$(ba_changeid 'Export CSV')"
cdir="$WORK/openspec/changes/$id"; mkdir -p "$cdir"
{ ba_frontmatter 30 alpha; echo "# Export CSV"; echo; echo "## Acceptance"; echo "- Given a report, clicking Export downloads a .csv with a header row."; } > "$cdir/proposal.md"

assert_eq "export-csv" "$id" "id derived"
openspec validate "$id" --strict; assert_exit 0 "$?" "generated change validates (stub)"
assert_eq "30" "$(fm_priority "$cdir/proposal.md")" "priority parses"
assert_eq "alpha" "$(fm_depends "$cdir/proposal.md")" "depends parses"
assert_summary
