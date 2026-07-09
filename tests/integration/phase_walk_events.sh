#!/usr/bin/env bash
# tests/integration/phase_walk_events.sh — NDJSON events scenario (feature:
# phasewalk-events, plan 07). Proves, in a hermetic scratch context with a
# scratch $AGENTIC_HOME, that feeding representative PostToolUse events
# through the REAL shipped packages/agentic-core/hooks/emit-event.sh produces
# well-formed NDJSON in $AGENTIC_HOME/events.ndjson (one JSON object per line,
# each parseable via jq) — proving D-11/T-C14's acceptance at the integration
# level (WS-B §4.3 item 5: "events land in NDJSON"). Also proves the same
# behaviour holds with $AGENTIC_SSE_URL unset (no difference vs. the baseline
# case): the SSE POST is a best-effort side channel, never a behaviour gate.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; . "$ROOT/tests/lib/assert.sh"
E="$ROOT/packages/agentic-core/hooks/emit-event.sh"

# --- hermetic scratch context: scratch cwd + scratch $AGENTIC_HOME ---
G="$(mktemp -d)"
cd "$G"
export AGENTIC_HOME="$(mktemp -d)"
unset AGENTIC_SSE_URL

# --- two representative PostToolUse events, fed on stdin exactly as Claude
# Code invokes the hook ---
event(){ printf '{"hook_event_name":"PostToolUse","tool_name":%s,"tool_input":{"command":%s}}' \
  "$(jq -Rn --arg t "$1" '$t')" "$(jq -Rn --arg c "$2" '$c')"; }

printf '%s' "$(event Bash 'npm test')" | bash "$E"
assert_exit 0 $? "emit-event exits 0 for a Bash PostToolUse event (AGENTIC_SSE_URL unset)"

printf '%s' "$(event Edit 'src/index.js')" | bash "$E"
assert_exit 0 $? "emit-event exits 0 for an Edit PostToolUse event (AGENTIC_SSE_URL unset)"

# --- file exists with exactly two lines, each a parseable JSON object ---
NDJSON="$AGENTIC_HOME/events.ndjson"
assert_exit 0 "$( [ -f "$NDJSON" ] && echo 0 || echo 1 )" "events.ndjson created"
lines="$(wc -l < "$NDJSON" | tr -d ' ')"
assert_eq "2" "$lines" "one NDJSON line per event fed"

while IFS= read -r line; do
  assert_exit 0 "$(printf '%s' "$line" | jq -e . >/dev/null 2>&1 && echo 0 || echo 1)" "line is well-formed, parseable JSON"
  assert_exit 0 "$(printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1 && echo 0 || echo 1)" "line is a JSON object"
done < "$NDJSON"

first_line="$(sed -n '1p' "$NDJSON")"
assert_contains "$first_line" "Bash" "first line records the Bash tool name"
second_line="$(sed -n '2p' "$NDJSON")"
assert_contains "$second_line" "Edit" "second line records the Edit tool name"

# --- confirm $AGENTIC_SSE_URL unset is identical behaviour to the baseline:
# re-run the same event pair into a fresh scratch AGENTIC_HOME with
# AGENTIC_SSE_URL explicitly unset (already the case above) and diff the
# structural shape (keys) against the same pair run with SSE URL set to an
# unreachable endpoint -- the ndjson lines' key sets must match. ---
baseline_keys="$(printf '%s' "$first_line" | jq -S 'keys')"

G2="$(mktemp -d)"; export AGENTIC_HOME="$G2"
export AGENTIC_SSE_URL="http://127.0.0.1:9"
printf '%s' "$(event Bash 'npm test')" | bash "$E"
assert_exit 0 $? "emit-event exits 0 with AGENTIC_SSE_URL set (unreachable)"
sse_line="$(sed -n '1p' "$AGENTIC_HOME/events.ndjson")"
sse_keys="$(printf '%s' "$sse_line" | jq -S 'keys')"
assert_eq "$baseline_keys" "$sse_keys" "NDJSON line shape identical whether AGENTIC_SSE_URL is set or unset"
unset AGENTIC_SSE_URL

assert_summary
