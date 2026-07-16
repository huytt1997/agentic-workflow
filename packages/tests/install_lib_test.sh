#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/packages/lib/install-common.sh"

# --- target auto-detect (feature: target-autodetect) ---
proj="$(mktemp -d)"; mkdir -p "$proj/.git"
assert_eq "$proj/.claude" "$(ic_resolve_target "$proj")" "project (.git) -> <dir>/.claude"
cfg="$(mktemp -d)"
assert_eq "$cfg" "$(ic_resolve_target "$cfg")" "config dir -> <dir> itself"
# a .git FILE (worktree) also counts as a project
proj2="$(mktemp -d)"; printf 'gitdir: /x\n' > "$proj2/.git"
assert_eq "$proj2/.claude" "$(ic_resolve_target "$proj2")" "project (.git file) -> <dir>/.claude"
ic_resolve_target "" >/dev/null 2>&1; assert_exit 1 "$?" "empty target rejected"

# --- package name normalization (feature: package-file-map) ---
assert_eq "agentic-core"       "$(ic_pkg_fullname core)"       "core -> agentic-core"
assert_eq "agentic-engineer"   "$(ic_pkg_fullname engineer)"   "engineer -> agentic-engineer"
assert_eq "agentic-init"     "$(ic_pkg_fullname init)"     "init -> agentic-init"
assert_eq "agentic-ba"       "$(ic_pkg_fullname ba)"       "ba -> agentic-ba"
assert_eq "agentic-pm"       "$(ic_pkg_fullname pm)"       "pm -> agentic-pm"
ic_pkg_fullname management >/dev/null 2>&1; assert_exit 1 "$?" "management is no longer a package"
assert_eq "agentic-core"       "$(ic_pkg_fullname agentic-core)" "accepts full name"
ic_pkg_fullname bogus >/dev/null 2>&1; assert_exit 1 "$?" "unknown package rejected"

# --- placement is always a copy (feature: copy-only) ---
psrc="$(mktemp -d)"; echo hi > "$psrc/a.txt"; mkdir "$psrc/sub"; echo x > "$psrc/sub/b.txt"
pd="$(mktemp -d)"
ic_place "$psrc" "$pd/out"
assert_eq "hi" "$(cat "$pd/out/a.txt")" "place copies file content"
assert_eq "x"  "$(cat "$pd/out/sub/b.txt")" "place copies nested content"
assert_exit 1 "$([ -L "$pd/out" ] && echo 0 || echo 1)" "dest is NOT a symlink"
ic_place "$psrc" "$pd/out"   # re-place over existing
assert_eq "hi" "$(cat "$pd/out/a.txt")" "re-place over existing is clean/idempotent"
# a pre-existing symlink at dest is replaced by a real copy (migration path)
ln -sfn "$psrc" "$pd/lnk"
ic_place "$psrc" "$pd/lnk"
assert_exit 1 "$([ -L "$pd/lnk" ] && echo 0 || echo 1)" "existing symlink is replaced by a copy"
assert_eq "hi" "$(cat "$pd/lnk/a.txt")" "replaced symlink has real content"

# --- install_package placement + discovery links (feature: file-placement) ---
tcfg="$(mktemp -d)"
ic_install_package core "$tcfg"
assert_exit 0 "$([ -f "$tcfg/agentic/agentic-core/hooks/verify-gate.sh" ] && echo 0 || echo 1)" "core hooks placed"
assert_exit 0 "$([ -f "$tcfg/agentic/agentic-core/lib/state.sh" ] && echo 0 || echo 1)" "core lib placed"
# core has NO discovery components -> no stray command links
assert_exit 1 "$([ -d "$tcfg/commands" ] && [ -n "$(ls -A "$tcfg/commands" 2>/dev/null)" ] && echo 0 || echo 1)" "core creates no command links"

ic_install_package engineer "$tcfg"
assert_exit 0 "$([ -L "$tcfg/commands/engineer.md" ] && echo 0 || echo 1)" "engineer command is a discovery symlink"
assert_exit 0 "$([ -e "$tcfg/commands/engineer.md" ] && echo 0 || echo 1)" "engineer command link resolves"
assert_exit 0 "$([ -L "$tcfg/agents/executor.md" ] && echo 0 || echo 1)" "engineer executor agent linked"
assert_exit 0 "$([ -e "$tcfg/skills/agentic-engineer/SKILL.md" ] && echo 0 || echo 1)" "engineer skill linked + resolves"

# copy mode: the package tree is a real directory, never a symlink
tcfg2="$(mktemp -d)"
ic_install_package engineer "$tcfg2"
assert_exit 1 "$([ -L "$tcfg2/agentic/agentic-engineer" ] && echo 0 || echo 1)" "package tree is not a symlink"
# discovery links remain symlinks (internal to the target; --mode never governed them)
assert_exit 0 "$([ -L "$tcfg2/commands/engineer.md" ] && echo 0 || echo 1)" "discovery link is still a symlink"
assert_exit 0 "$([ -e "$tcfg2/commands/engineer.md" ] && echo 0 || echo 1)" "discovery link resolves"

# re-install is idempotent (re-run doesn't error, links still resolve)
ic_install_package engineer "$tcfg"
assert_exit 0 "$([ -e "$tcfg/commands/engineer.md" ] && echo 0 || echo 1)" "re-install: discovery link still resolves"

# --- install manifest (feature: install-manifest) ---
mf="$(ic_manifest_path "$tcfg" agentic-core)"
assert_eq "$tcfg/agentic/.agentic-installed/agentic-core.json" "$mf" "manifest path"
assert_exit 0 "$(jq -e . "$mf" >/dev/null 2>&1 && echo 0 || echo 1)" "manifest is valid json"
assert_eq "agentic-install/1" "$(jq -r .schema "$mf")" "manifest schema"
assert_eq "agentic-core" "$(jq -r .package "$mf")" "manifest package"
assert_eq "copy" "$(jq -r .mode "$mf")" "manifest mode"
assert_eq "[]" "$(jq -c .hooks_added "$mf")" "manifest hooks_added starts empty"
assert_exit 0 "$(jq -e '.links | type=="array"' "$mf" >/dev/null 2>&1 && echo 0 || echo 1)" "manifest links is an array"
assert_exit 0 "$(jq -e '.version and .installed_at' "$mf" >/dev/null 2>&1 && echo 0 || echo 1)" "manifest has version + installed_at"

mfe="$(ic_manifest_path "$tcfg" engineer)"
assert_exit 0 "$(jq -e '.links | length > 0' "$mfe" >/dev/null 2>&1 && echo 0 || echo 1)" "engineer manifest records discovery links"
assert_exit 0 "$(jq -e '.links | any(. == "commands/engineer.md")' "$mfe" >/dev/null 2>&1 && echo 0 || echo 1)" "engineer manifest links include command link"

assert_exit 0 "$(ic_manifest_installed "$tcfg" core; echo $?)" "core reported installed"
assert_exit 1 "$(ic_manifest_installed "$tcfg" management; echo $?)" "management reported not installed"

# re-install updates the manifest (single object, not duplicated/appended)
before_links="$(jq -c '.links | sort' "$mfe")"
ic_install_package engineer "$tcfg"
assert_exit 0 "$(jq -e 'type=="object"' "$mfe" >/dev/null 2>&1 && echo 0 || echo 1)" "re-install manifest stays a single object"
assert_eq "$before_links" "$(jq -c '.links | sort' "$mfe")" "re-install: links not duplicated"

assert_summary
