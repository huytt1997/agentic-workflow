#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
. "$DIR/../../../tests/lib/assert.sh"
. "$ROOT/tests/fixtures/openspec/fixture-lib.sh"
. "$DIR/../../agentic-ba/lib/ba-changeid.sh"; . "$DIR/../../agentic-core/lib/frontmatter.sh"
WORK="$(pm_fixture_setup)"; trap 'rm -rf "$WORK"' EXIT
rm -rf "$WORK/openspec/changes"/*

# BA authors a 3-change backlog with a dependency chain.
# (Single-colon delimiter used deliberately: `IFS='::' read` collapses
# consecutive delimiters to a single split point in bash, so a literal
# "::" separator does not produce the intended 3-field split -- verified
# empirically. "prio:title:dep" with a single colon splits correctly.)
for spec in "10:One:" "20:Two:one" "30:Three:two"; do
  IFS=':' read -r prio title dep <<<"$spec"
  id="$(ba_changeid "$title")"; mkdir -p "$WORK/openspec/changes/$id"
  if [ -n "$dep" ]; then
    dep_id="$(ba_changeid "$dep")"
    { ba_frontmatter "$prio" "$dep_id"; echo "# $title"; } > "$WORK/openspec/changes/$id/proposal.md"
  else
    { ba_frontmatter "$prio"; echo "# $title"; } > "$WORK/openspec/changes/$id/proposal.md"
  fi
done
before="$(find "$WORK/openspec/changes" -mindepth 1 -maxdepth 1 -type d ! -name archive | wc -l | tr -d ' ')"
assert_eq "3" "$before" "three active changes authored"

out="$(cd "$WORK" && STUB_OUTCOME_STATUS=success PM_DRY_RUN=0 PM_ON_BLOCK=continue \
      AGENTIC_PROJECT_ROOT="$WORK" PATH="$(pm_fixture_bin):$PATH" bash "$DIR/../bin/pm-runner.sh")"
assert_contains "$out" "done=3" "all three changes completed"
after="$(find "$WORK/openspec/changes" -mindepth 1 -maxdepth 1 -type d ! -name archive | wc -l | tr -d ' ')"
assert_eq "0" "$after" "active changes dir emptied (flat footprint: archive grew)"
archived="$(find "$WORK/openspec/changes/archive" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
assert_eq "3" "$archived" "all three archived"
assert_summary
