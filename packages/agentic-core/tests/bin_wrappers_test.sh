#!/usr/bin/env bash
# bin_wrappers_test.sh — the CLI names the orchestrator SOP + subagents actually invoke
# (`agentic-state`, `agentic-checkpoint`, `agentic-profile`) MUST ship as executable bin/
# wrappers over lib/*.sh. Without them, every `agentic-state ...` call in the SOP is a
# command-not-found and no `.agentic/state.json` is ever created — the harness silently
# degrades to a plain edit session. This guards that packaging seam (which the direct-lib
# tests do not cover, since they call lib/state.sh by path).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"; . "$ROOT/tests/lib/assert.sh"
BIN="$ROOT/packages/agentic-core/bin"

# every command the SOP calls by bare name exists and is executable
for w in agentic-state agentic-checkpoint agentic-profile; do
  assert_exit 0 "$( [ -f "$BIN/$w" ] && echo 0 || echo 1 )" "bin/$w exists"
  assert_exit 0 "$( [ -x "$BIN/$w" ] && echo 0 || echo 1 )" "bin/$w is executable"
done

# the wrapper actually reaches lib/state.sh — invoked as a program (no CLAUDE_PLUGIN_ROOT,
# exercising the $0-relative fallback, which is how a target-repo subagent hits it)
export AGENTIC_STATE="$(mktemp -d)/state.json"
unset CLAUDE_PLUGIN_ROOT
"$BIN/agentic-state" init demo --mode auto --change c-9
assert_eq "demo" "$("$BIN/agentic-state" get feature)" "agentic-state wrapper dispatches to state.sh"
assert_eq "c-9" "$("$BIN/agentic-state" get change_id)" "agentic-state wrapper passes args through"

# checkpoint wrapper dispatches to checkpoint.sh's main (unknown cmd -> usage, exit 1)
"$BIN/agentic-checkpoint" __nope__ >/dev/null 2>&1; rc=$?
assert_exit 1 "$rc" "agentic-checkpoint wrapper dispatches to checkpoint.sh (usage on bad cmd)"

assert_summary
