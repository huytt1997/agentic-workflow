#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/packages/lib/install-common.sh"

# helper: a temp cfg with agentic-core placed
mkcfg() { local c; c="$(mktemp -d)"; ic_install_package core "$c" copy >/dev/null; printf '%s' "$c"; }

# --- merge (feature: hooks-merge) ---
cfg="$(mkcfg)"; s="$cfg/settings.json"
ic_hooks_merge "$cfg"
core="$cfg/agentic/agentic-core"
for ev in SessionStart PreToolUse PostToolUse Stop SubagentStop; do
  assert_exit 0 "$(jq -e --arg e "$ev" '(.hooks[$e] // []) | length >= 1' "$s" >/dev/null 2>&1 && echo 0 || echo 1)" "event $ev registered"
done
assert_contains "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s")" "$core/hooks/safety-guard.sh" "PreToolUse command resolved to install path"
assert_exit 1 "$(grep -q 'CLAUDE_PLUGIN_ROOT' "$s" && echo 0 || echo 1)" "no CLAUDE_PLUGIN_ROOT token left in settings.json"
mf="$(ic_manifest_path "$cfg" core)"
assert_eq "5" "$(jq '.hooks_added | length' "$mf")" "manifest records 5 hooks added"

# idempotent: two more merges must not duplicate groups
ic_hooks_merge "$cfg"; ic_hooks_merge "$cfg"
assert_eq "1" "$(jq '.hooks.PreToolUse | length' "$s")" "PreToolUse not duplicated after repeated merges"
assert_eq "5" "$(jq '.hooks_added | length' "$mf")" "hooks_added still 5 after repeated merges"

# refuses when core not installed
empty="$(mktemp -d)"; ic_hooks_merge "$empty" >/dev/null 2>&1
assert_exit 1 "$?" "merge fails when agentic-core not installed"

# --- merge preserves unrelated settings (feature: hooks-merge) ---
cfg2="$(mkcfg)"; s2="$cfg2/settings.json"
jq -n '{hooks:{PreToolUse:[{hooks:[{type:"command",command:"USER-KEEP"}]}],
               UserPromptSubmit:[{hooks:[{type:"command",command:"UP-KEEP"}]}]},
        permissions:{allow:["Bash"]}}' > "$s2"
ic_hooks_merge "$cfg2"
assert_contains "$(cat "$s2")" "USER-KEEP" "user PreToolUse hook preserved on merge"
assert_contains "$(cat "$s2")" "UP-KEEP"   "user-only event preserved on merge"
assert_contains "$(cat "$s2")" "Bash"      "unrelated settings (permissions) preserved"
assert_eq "2" "$(jq '.hooks.PreToolUse | length' "$s2")" "PreToolUse has user group + ours"

# --- unmerge strips only our hooks (feature: hooks-unmerge) ---
cfg3="$(mkcfg)"; s3="$cfg3/settings.json"
jq -n '{hooks:{PreToolUse:[{hooks:[{type:"command",command:"USER-KEEP"}]}]}}' > "$s3"
ic_hooks_merge "$cfg3"
assert_eq "2" "$(jq '.hooks.PreToolUse | length' "$s3")" "before unmerge: user + ours"
core3="$cfg3/agentic/agentic-core"
ic_hooks_unmerge "$cfg3"
assert_exit 1 "$(grep -q "$core3/hooks/safety-guard.sh" "$s3" && echo 0 || echo 1)" "our safety-guard hook removed"
assert_exit 1 "$(grep -q "$core3/hooks/verify-gate.sh" "$s3" && echo 0 || echo 1)" "our verify-gate hooks removed"
assert_contains "$(cat "$s3")" "USER-KEEP" "user hook preserved after unmerge"
assert_eq "1" "$(jq '.hooks.PreToolUse | length' "$s3")" "only the user group remains in PreToolUse"
# events that were ours-only get pruned to empty/removed
assert_exit 0 "$(jq -e '(.hooks.Stop // []) | length == 0' "$s3" >/dev/null 2>&1 && echo 0 || echo 1)" "ours-only Stop event pruned"
# no-op safety on an untouched target
empty3="$(mktemp -d)"; ic_hooks_unmerge "$empty3"; assert_exit 0 "$?" "unmerge on untouched target is a no-op"

# --- merge is safe under sed-metachar install paths (feature: hooks-merge, M1 regression) ---
metabase="$(mktemp -d)"
metacfg="$metabase/a&b"
mkdir -p "$metacfg"
ic_install_package core "$metacfg" copy >/dev/null
ic_hooks_merge "$metacfg"
smeta="$metacfg/settings.json"
coremeta="$metacfg/agentic/agentic-core"
resolved_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$smeta")"
assert_eq "bash \"$coremeta/hooks/safety-guard.sh\"" "$resolved_cmd" "PreToolUse command resolved correctly under sed-metachar target path"
resolved_path="$(jq -r '.hooks.PreToolUse[0].hooks[0].command | capture("\"(?<p>[^\"]+)\"").p' "$smeta")"
assert_exit 0 "$([ -f "$resolved_path" ] && echo 0 || echo 1)" "resolved command under sed-metachar path is a real, existing file"
assert_exit 1 "$(grep -q 'CLAUDE_PLUGIN_ROOT' "$smeta" && echo 0 || echo 1)" "no CLAUDE_PLUGIN_ROOT token left under sed-metachar target path"

assert_summary
