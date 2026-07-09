#!/usr/bin/env bash
# tests/integration/phase_walk_rollback.sh — rollback scenario (feature:
# phasewalk-rollback, plan 07). Proves, in the SAME hermetic scratch-repo
# context the other phase-walk scenarios establish, T-C12's acceptance at
# the integration level against the REAL shipped kernel: create a green
# checkpoint via the real packages/agentic-core/lib/checkpoint.sh, deliberately
# break the tree (a dirty edit committed as a non-green checkpoint), then run
# `checkpoint.sh revert-last-green` and assert HEAD is back at the last green
# SHA and the tree is clean (git status --porcelain empty) — the ONLY
# rollback path (I-5).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; . "$ROOT/tests/lib/assert.sh"
S="$ROOT/packages/agentic-core/lib/state.sh"
C="$ROOT/packages/agentic-core/lib/checkpoint.sh"

# --- build the same hermetic throwaway repo the other phase-walk scenarios use ---
G="$(mktemp -d)"
cp -R "$ROOT/tests/fixtures/npm-sample/." "$G/"
rm -rf "$G/node_modules" "$G/package-lock.json"
printf 'node_modules/\npackage-lock.json\n' > "$G/.gitignore"
cd "$G"
git init -q; git config user.email t@t; git config user.name t
git add -A; git commit -q -m base

export AGENTIC_STATE="$G/.agentic/state.json"

bash "$S" init demo --mode auto --change c-1 >/dev/null

# --- create a green checkpoint (the "last known good" state) ---
echo "good" > feature.txt
bash "$C" checkpoint P2 t1 --green >/dev/null
green_sha="$(git rev-parse HEAD)"
assert_eq "$green_sha" "$(bash "$C" last-green)" "last-green points at the checkpoint just recorded"

# --- deliberately break the tree: a further (non-green) checkpoint, then an
# uncommitted dirty edit on top, simulating a broken in-flight change ---
echo "attempt" >> feature.txt
bash "$C" checkpoint P2 t2-attempt >/dev/null
echo "BROKEN" >> feature.txt
assert_contains "$(git status --porcelain)" "feature.txt" "tree is dirty before revert (sanity)"

# --- revert-last-green: the ONLY rollback path (I-5) ---
bash "$C" revert-last-green

assert_eq "$green_sha" "$(git rev-parse HEAD)" "HEAD back at last green sha after revert-last-green"
assert_eq "" "$(git status --porcelain)" "tree clean (git status --porcelain empty) after revert"
assert_eq "good" "$(cat feature.txt)" "recovered file content matches the green checkpoint, not the broken edit"

assert_summary
