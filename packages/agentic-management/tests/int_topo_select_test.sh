#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$DIR/fixtures/fixture-lib.sh"
. "$DIR/../lib/ba-changeid.sh"; . "$DIR/../lib/ba-frontmatter.sh"
WORK="$(pm_fixture_setup "$DIR")"; trap 'rm -rf "$WORK"' EXIT
export AGENTIC_PROJECT_ROOT="$WORK"
export PATH="$DIR/fixtures/bin:$PATH"
# start from a clean changes dir so only BA-authored changes exist
rm -rf "$WORK/openspec/changes"/*
. "$DIR/../bin/pm-runner.sh"; pg_init

base="$(ba_changeid 'Create Schema')"          # -> create-schema
dep="$(ba_changeid 'Seed Data')"               # -> seed-data, depends on base
mkdir -p "$WORK/openspec/changes/$base" "$WORK/openspec/changes/$dep"
{ ba_frontmatter 10;        echo "# Create Schema"; } > "$WORK/openspec/changes/$base/proposal.md"
{ ba_frontmatter 20 "$base"; echo "# Seed Data"; }   > "$WORK/openspec/changes/$dep/proposal.md"

assert_eq "create-schema" "$(next_change)" "dependency-free change selected first"
pg_push done "$base"
assert_eq "seed-data" "$(next_change)" "dependent change selected after its dep is done"
assert_summary
