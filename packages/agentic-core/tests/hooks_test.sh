#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"; . "$ROOT/tests/lib/assert.sh"

# --- emit-ndjson (feature: emit-ndjson) ---
export AGENTIC_HOME="$(mktemp -d)"
E="$ROOT/packages/agentic-core/hooks/emit-event.sh"
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$E"; assert_exit 0 $? "emit exits 0"
line="$(tail -1 "$AGENTIC_HOME/events.ndjson")"
assert_exit 0 "$(printf '%s' "$line" | jq -e . >/dev/null 2>&1 && echo 0 || echo 1)" "one valid NDJSON line"
assert_contains "$line" "Bash" "records tool name"
# unreachable SSE URL must not stall / must still exit 0
export AGENTIC_SSE_URL="http://127.0.0.1:9"; t0=$(date +%s)
printf '{"tool_name":"Edit"}' | bash "$E"; assert_exit 0 $? "exit 0 with bad SSE URL"
t1=$(date +%s); assert_exit 0 "$([ $((t1-t0)) -lt 5 ] && echo 0 || echo 1)" "does not stall on bad URL"
unset AGENTIC_SSE_URL

# unsetting AGENTIC_SSE_URL changes nothing about ndjson behaviour
before_count="$(wc -l < "$AGENTIC_HOME/events.ndjson" | tr -d ' ')"
printf '{"tool_name":"Read"}' | bash "$E"; assert_exit 0 $? "emit exits 0 without SSE URL"
after_count="$(wc -l < "$AGENTIC_HOME/events.ndjson" | tr -d ' ')"
assert_eq "$((before_count+1))" "$after_count" "one more NDJSON line appended without SSE URL"
last_line="$(tail -1 "$AGENTIC_HOME/events.ndjson")"
assert_exit 0 "$(printf '%s' "$last_line" | jq -e . >/dev/null 2>&1 && echo 0 || echo 1)" "still valid JSON without SSE URL"

# missing/malformed input still exits 0 and does not crash
printf '' | bash "$E"; assert_exit 0 $? "empty stdin still exits 0"
printf 'not json at all {{{' | bash "$E"; assert_exit 0 $? "malformed stdin still exits 0"

# --- session-bearings (feature: session-bearings) ---
S="$ROOT/packages/agentic-core/lib/state.sh"
B="$ROOT/packages/agentic-core/hooks/session-bearings.sh"

# Case 1: repo with a long history + an initialized state file -> bounded git log,
# cwd printed, I-10 reminder printed, state summary reflects the initialized feature.
G="$(mktemp -d)"; (
  cd "$G" || exit 1
  git init -q
  git config user.email t@t
  git config user.name t
  for i in 1 2 3 4 5 6 7; do git commit -q --allow-empty -m "c$i"; done
  export AGENTIC_STATE="$G/.agentic/state.json"
  bash "$S" init demo >/dev/null 2>&1
)
out="$(cd "$G" && AGENTIC_STATE="$G/.agentic/state.json" bash "$B" 2>&1)"
assert_contains "$out" "$G" "bearings prints cwd"
assert_contains "$out" "target project" "bearings notes target rules win (I-10)"
loglines="$(printf '%s\n' "$out" | grep -c 'c[0-9]')"
assert_exit 0 "$([ "$loglines" -le 5 ] && echo 0 || echo 1)" "git log bounded to <=5 even with 7 commits"
assert_contains "$out" "demo" "bearings state summary shows feature"

# Case 2: no .agentic/state.json present at all -> must not error, must still print bearings.
G2="$(mktemp -d)"; (
  cd "$G2" || exit 1
  git init -q
  git config user.email t@t
  git config user.name t
  git commit -q --allow-empty -m "only commit"
)
out2="$(cd "$G2" && AGENTIC_STATE="$G2/.agentic/state.json" bash "$B" 2>&1)"
rc2=$?
assert_exit 0 "$rc2" "bearings exits 0 with no state file"
assert_contains "$out2" "$G2" "bearings prints cwd (no state)"

# --- profile-detect (feature: profile-detect) ---
P="$ROOT/packages/agentic-core/lib/profile.sh"
assert_eq "/custom/cfg" "$(CLAUDE_CONFIG_DIR=/custom/cfg bash "$P" config-dir)" "honors CLAUDE_CONFIG_DIR"
def="$(unset CLAUDE_CONFIG_DIR; bash "$P" config-dir)"
assert_contains "$def" ".claude" "defaults to ~/.claude when unset"
W2="$ROOT/packages/agentic-core/bin/agentic-profile"
assert_exit 0 "$( [ -x "$W2" ] && echo 0 || echo 1 )" "agentic-profile wrapper executable"

# --- hooks-registered (feature: hooks-registered) ---
HJ="$ROOT/packages/agentic-core/hooks/hooks.json"
assert_exit 0 "$(jq -e . "$HJ" >/dev/null 2>&1 && echo 0 || echo 1)" "hooks.json valid"
for ev in SessionStart PreToolUse PostToolUse Stop SubagentStop; do
  assert_exit 0 "$(jq -e --arg e "$ev" 'has($e)' "$HJ" >/dev/null 2>&1 && echo 0 || echo 1)" "registers $ev"
done
assert_contains "$(cat "$HJ")" "CLAUDE_PLUGIN_ROOT" "uses \${CLAUDE_PLUGIN_ROOT}"

assert_summary
