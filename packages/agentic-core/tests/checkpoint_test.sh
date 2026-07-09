#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
S="$ROOT/packages/agentic-core/lib/state.sh"
C="$ROOT/packages/agentic-core/lib/checkpoint.sh"

G="$(mktemp -d)"; cd "$G"; git init -q; git config user.email t@t; git config user.name t
export AGENTIC_STATE="$G/.agentic/state.json"
bash "$S" init demo

echo one > a.txt; git add -A
bash "$C" checkpoint P2 t1 --green
sha1="$(git rev-parse HEAD)"
assert_contains "$(git log -1 --pretty=%s)" "[agentic:ckpt] P2/t1" "checkpoint subject carries marker"
assert_eq "1" "$(bash "$S" get 'checkpoints | length')" "checkpoint recorded in state"
assert_eq "P2" "$(bash "$S" get 'checkpoints[0].phase')" "checkpoint phase recorded"
assert_eq "t1" "$(bash "$S" get 'checkpoints[0].label')" "checkpoint label recorded"
assert_eq "$sha1" "$(bash "$S" get 'checkpoints[0].sha')" "checkpoint sha recorded"
assert_eq "true" "$(bash "$S" get 'checkpoints[0].green')" "checkpoint green flag recorded"

echo two > b.txt; git add -A
bash "$C" checkpoint P3 t2
sha2="$(git rev-parse HEAD)"
assert_eq "2" "$(bash "$S" get 'checkpoints | length')" "second checkpoint recorded"
assert_eq "false" "$(bash "$S" get 'checkpoints[1].green')" "non-green checkpoint defaults green=false"

# list — one line per checkpoint, in order
list_out="$(bash "$C" list)"
assert_contains "$list_out" "P2/t1" "list shows first checkpoint"
assert_contains "$list_out" "P3/t2" "list shows second checkpoint"
list_lines="$(echo "$list_out" | wc -l | tr -d ' ')"
assert_eq "2" "$list_lines" "list has one line per checkpoint"

# last — most recent checkpoint's sha
assert_eq "$sha2" "$(bash "$C" last)" "last returns most recent checkpoint sha"

# last-green — most recent green checkpoint's sha (t2 not green, so t1 still last-green)
assert_eq "$sha1" "$(bash "$C" last-green)" "last-green returns newest green checkpoint sha"

# revert-last-green — the only rollback path (I-5): reset --hard to the last green checkpoint
echo three > c.txt; git add -A
bash "$C" checkpoint P4 t3 --green
sha3="$(git rev-parse HEAD)"
assert_eq "$sha3" "$(bash "$C" last-green)" "last-green now points to newest green checkpoint t3"

echo BROKEN >> a.txt; git add -A; git commit -q -m "broken (no ckpt)"
assert_eq "$sha3" "$(bash "$S" get 'checkpoints | [.[] | select(.green == true)] | last | .sha')" "sanity: broken commit not recorded as green checkpoint"
bash "$C" revert-last-green
assert_eq "$sha3" "$(git rev-parse HEAD)" "HEAD back at last-green sha after revert"
assert_eq "" "$(git status --porcelain)" "tree clean after revert-last-green"

assert_summary
