#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/packages/lib/install-common.sh"
INSTALL="$ROOT/packages/install.sh"
UPDATE="$ROOT/packages/update.sh"
UNINSTALL="$ROOT/packages/uninstall.sh"

# --- selection helpers (feature: install-cli) ---
assert_eq "agentic-core
agentic-engineer
agentic-management" "$(ic_expand_selection all)" "all expands in dependency order"
assert_eq "agentic-engineer" "$(ic_expand_selection engineer)" "single token expands"
ic_expand_selection bogus >/dev/null 2>&1; assert_exit 1 "$?" "invalid selection rejected"

ic_parse_common --target /tmp/x --package core --mode symlink
assert_eq "/tmp/x" "$IC_TARGET" "parse target"
assert_eq "core" "$IC_PACKAGE" "parse package"
assert_eq "symlink" "$IC_MODE" "parse mode"
ic_parse_common --package core >/dev/null 2>&1; assert_exit 2 "$?" "missing --target rejected"
assert_eq "all" "$(printf '4\n' | ic_menu 2>/dev/null)" "menu choice 4 -> all"

# --- install.sh (features: install-cli, dependency-precondition) ---
cfgA="$(mktemp -d)"
out="$(bash "$INSTALL" --target "$cfgA" --package all --mode copy 2>&1)"; rc=$?
assert_exit 0 "$rc" "install all exits 0"
for p in agentic-core agentic-engineer agentic-management; do
  assert_exit 0 "$(ic_manifest_installed "$cfgA" "$p"; echo $?)" "$p installed by 'all'"
done
s="$cfgA/settings.json"
assert_exit 0 "$(jq -e '.hooks.PreToolUse | length >= 1' "$s" >/dev/null 2>&1 && echo 0 || echo 1)" "core hooks registered by install all"
assert_exit 0 "$([ -e "$cfgA/commands/engineer.md" ] && echo 0 || echo 1)" "engineer command discoverable after install all"
assert_contains "$out" "agentic-core/bin" "install prints a PATH hint for core bin"

# dependency precondition: engineer alone without core -> fail fast, nothing placed
cfgB="$(mktemp -d)"
out2="$(bash "$INSTALL" --target "$cfgB" --package engineer 2>&1)"; rc2=$?
assert_exit 1 "$rc2" "engineer-without-core exits non-zero"
assert_contains "$out2" "agentic-core first" "clear precondition error message"
assert_exit 1 "$([ -d "$cfgB/agentic/agentic-engineer" ] && echo 0 || echo 1)" "no engineer files placed on precondition failure"

# dependency precondition: management alone without core -> fail fast, nothing placed
cfgB2="$(mktemp -d)"
out2m="$(bash "$INSTALL" --target "$cfgB2" --package management 2>&1)"; rc2m=$?
assert_exit 1 "$rc2m" "management-without-core exits non-zero"
assert_contains "$out2m" "agentic-core first" "clear precondition error message (management)"
assert_exit 1 "$([ -d "$cfgB2/agentic/agentic-management" ] && echo 0 || echo 1)" "no management files placed on precondition failure"

# menu path (no --package): piping '1' installs core
cfgC="$(mktemp -d)"
printf '1\n' | bash "$INSTALL" --target "$cfgC" --mode copy >/dev/null 2>&1
assert_exit 0 "$(ic_manifest_installed "$cfgC" core; echo $?)" "menu choice 1 installs core"

# --- update.sh (feature: update-cli) ---
cfgU="$(mktemp -d)"
bash "$INSTALL" --target "$cfgU" --package core --mode copy >/dev/null 2>&1
# tamper with a placed file, then update should re-sync it back
echo "TAMPERED" > "$cfgU/agentic/agentic-core/lib/state.sh"
bash "$UPDATE" --target "$cfgU" --package core >/dev/null 2>&1; rcU=$?
assert_exit 0 "$rcU" "update core exits 0"
assert_exit 1 "$(grep -q '^TAMPERED$' "$cfgU/agentic/agentic-core/lib/state.sh" && echo 0 || echo 1)" "update re-synced the tampered file"
assert_eq "5" "$(jq '.hooks_added | length' "$(ic_manifest_path "$cfgU" core)")" "update re-reconciles hooks idempotently"

# refuse a package that was never installed
cfgU2="$(mktemp -d)"
out="$(bash "$UPDATE" --target "$cfgU2" --package core 2>&1)"; rcU2=$?
assert_exit 1 "$rcU2" "update of never-installed target exits non-zero"
assert_contains "$out" "not installed" "update prints a not-installed error"
assert_exit 1 "$([ -e "$cfgU2/agentic" ] && echo 0 || echo 1)" "update refusal touches nothing at the target"

# update re-syncs a symlink-mode install by re-verifying the link (no --mode required)
cfgU3="$(mktemp -d)"
bash "$INSTALL" --target "$cfgU3" --package core --mode symlink >/dev/null 2>&1
rm -f "$cfgU3/agentic/agentic-core"
bash "$UPDATE" --target "$cfgU3" --package core >/dev/null 2>&1; rcU3=$?
assert_exit 0 "$rcU3" "update relinks a symlink-mode install without --mode"
assert_exit 0 "$([ -L "$cfgU3/agentic/agentic-core" ] && echo 0 || echo 1)" "update restored the symlink"

# --- uninstall.sh (feature: uninstall-cli) ---
cfgX="$(mktemp -d)"
bash "$INSTALL" --target "$cfgX" --package all --mode copy >/dev/null 2>&1
# a user-owned artifact that must survive uninstall
echo "user-data" > "$cfgX/events.ndjson"
core_cmd="$cfgX/agentic/agentic-core/hooks/safety-guard.sh"
bash "$UNINSTALL" --target "$cfgX" --package core >/dev/null 2>&1; rcX=$?
assert_exit 0 "$rcX" "uninstall core exits 0"
assert_exit 1 "$([ -d "$cfgX/agentic/agentic-core" ] && echo 0 || echo 1)" "core package dir removed"
assert_exit 1 "$(ic_manifest_installed "$cfgX" core; echo $?)" "core manifest removed"
assert_exit 1 "$(grep -q "$core_cmd" "$cfgX/settings.json" && echo 0 || echo 1)" "core hooks stripped from settings.json"
assert_exit 0 "$([ -e "$cfgX/commands/engineer.md" ] && echo 0 || echo 1)" "engineer (not uninstalled) still present"
assert_contains "$(cat "$cfgX/events.ndjson")" "user-data" "user data preserved on uninstall"

# uninstalling an already-removed package is a no-op
bash "$UNINSTALL" --target "$cfgX" --package core >/dev/null 2>&1
assert_exit 0 "$?" "uninstall of absent package is a no-op"

# uninstall all -> agentic/ tree fully gone
bash "$UNINSTALL" --target "$cfgX" --package all >/dev/null 2>&1
for p in agentic-core agentic-engineer agentic-management; do
  assert_exit 1 "$([ -d "$cfgX/agentic/$p" ] && echo 0 || echo 1)" "$p removed by uninstall all"
done
assert_exit 1 "$([ -e "$cfgX/commands/engineer.md" ] && echo 0 || echo 1)" "engineer discovery link removed by uninstall all"

assert_summary
