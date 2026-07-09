#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"; . "$ROOT/tests/lib/assert.sh"
S="$ROOT/packages/agentic-core/lib/state.sh"; GATE="$ROOT/packages/agentic-core/hooks/verify-gate.sh"
newrepo(){ G="$(mktemp -d)"; cd "$G"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m base; export AGENTIC_STATE="$G/.agentic/state.json"; }
gate(){ bash "$GATE" >/tmp/gate.out 2>&1; echo $?; }

# fail-open baseline (feature: gate-fail-open, T-C8) — needed as foundation for gate-p2;
# not itself the feature under test here.
newrepo
assert_exit 0 "$(unset AGENTIC_STATE; gate)" "no state -> allow (fail-open)"

# gate-fail-open, T-C8: explicit fixtures proving every fail-open path never
# bricks a session, even when the underlying state would otherwise be genuinely
# red (block-worthy) — proving these are true fail-open escapes, not accidents
# of an empty/green state.

# Missing jq binary -> allow immediately, even with a state that would
# otherwise block (P2 with a task remaining). Resolve bash's own absolute path
# first so the shell doesn't need to look up "bash" itself in the now-empty
# PATH used for the hook's own execution (mirrors safety_guard_test.sh).
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P2; bash "$S" task-add t1 x
BASH_BIN="$(command -v bash)"
assert_exit 0 "$(PATH=/nonexistent-empty-dir "$BASH_BIN" "$GATE" >/tmp/gate.out 2>&1; echo $?)" \
  "missing jq binary -> allow immediately, even though P2 is genuinely red"

# Malformed / non-JSON stdin event must never crash or hang the hook. The gate
# doesn't consume any stdin event content, but Stop/SubagentStop hooks are
# always invoked with a JSON event on stdin in real usage, so garbage stdin
# must be as harmless as no stdin at all.
newrepo
assert_exit 0 "$(printf 'not json' | bash "$GATE" >/tmp/gate.out 2>&1; echo $?)" \
  "malformed non-JSON stdin -> allow immediately (no state)"
assert_exit 0 "$(printf '' | bash "$GATE" >/tmp/gate.out 2>&1; echo $?)" \
  "empty stdin -> allow immediately (no state)"
assert_exit 0 "$(printf '{"unexpected":"shape"}' | bash "$GATE" >/tmp/gate.out 2>&1; echo $?)" \
  "valid JSON, unrelated shape -> allow immediately (no state)"

# P0 gate: blocks while worktree_path is unset, allows once recorded (feature: gate-p2)
newrepo; bash "$S" init demo
assert_exit 2 "$(gate)" "P0 blocks: worktree_path unset"
assert_contains "$(cat /tmp/gate.out)" "P0" "P0 reason names P0"
bash "$S" set worktree_path "\"$G\""
assert_exit 0 "$(gate)" "P0 allows once worktree_path recorded"

# P1 gate: blocks until plan/verify_cmds recorded; interactive additionally needs approval
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P1
assert_exit 2 "$(gate)" "P1 (auto) blocks: verify_cmds/tasks not recorded"
assert_contains "$(cat /tmp/gate.out)" "P1" "P1 reason names P1"
bash "$S" set 'verify_cmds.fast' '"npm run lint"'
bash "$S" set 'verify_cmds.large' '"npm test"'
bash "$S" task-add t1 "impl"
assert_exit 0 "$(gate)" "P1 (auto) allows once verify_cmds + tasks recorded"

newrepo; bash "$S" init demo2 --mode interactive; bash "$S" phase P1
bash "$S" set 'verify_cmds.fast' '"npm run lint"'
bash "$S" set 'verify_cmds.large' '"npm test"'
bash "$S" task-add t1 "impl"
assert_exit 2 "$(gate)" "P1 (interactive) blocks without approval flag even with plan+verify_cmds recorded"
assert_contains "$(cat /tmp/gate.out)" "P1" "P1 interactive reason names P1"
bash "$S" set plan_approved true
assert_exit 0 "$(gate)" "P1 (interactive) allows once approved"

# P2 gate: blocks with task remaining; blocks if fast is not pass; allows once both clear
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P2; bash "$S" task-add t1 x
assert_exit 2 "$(gate)" "P2 blocks with task remaining"
assert_contains "$(cat /tmp/gate.out)" "P2" "reason names P2"
bash "$S" task-set t1 verified; bash "$S" check-set fast pass
assert_exit 0 "$(gate)" "P2 allows when tasks done + fast green"

# P3 gate: blocks while checks.large is unset/not-pass, allows on large pass (feature: gate-p3-p4)
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P3
assert_exit 2 "$(gate)" "P3 blocks with large unset"
assert_contains "$(cat /tmp/gate.out)" "P3" "P3 reason names P3"
bash "$S" check-set large pass
assert_exit 0 "$(gate)" "P3 allows on large green"

# P4 gate: blocks on changes_requested, allows on review pass
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P4
bash "$S" set 'checks.review' '"changes_requested"'
assert_exit 2 "$(gate)" "P4 blocks on changes_requested"
assert_contains "$(cat /tmp/gate.out)" "P4" "P4 reason names P4"
bash "$S" check-set review pass
assert_exit 0 "$(gate)" "P4 allows on review pass"

# P5 gate: blocks while worktree still present in auto mode, allows once cleaned up
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P5
bash "$S" set worktree_path "\"$G/wt\""
mkdir -p "$G/wt"
assert_exit 2 "$(gate)" "P5 (auto) blocks: worktree still present"
assert_contains "$(cat /tmp/gate.out)" "P5" "P5 reason names P5"
rm -rf "$G/wt"
assert_exit 0 "$(gate)" "P5 (auto) allows once worktree removed"

# P5 gate (interactive): handed off to human, never blocks on cleanup
newrepo; bash "$S" init demo2 --mode interactive; bash "$S" phase P5
bash "$S" set worktree_path "\"$G\""
assert_exit 0 "$(gate)" "P5 (interactive) allows: handed off, no cleanup enforced"

# else phase: never blocks
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P9
assert_exit 0 "$(gate)" "unknown phase never blocks"

# P4->P2 re-entry cannot terminate on stale green (feature: gate-reentry, T-C5).
# Full simulated cycle: P2 (fresh) -> P3 (fresh large) -> P4 (fresh review pass) ->
# reviewer requests changes -> orchestrator reopens P2 -> re-walk P3/P4 and prove
# the cycle CANNOT terminate until BOTH large and review are fresh again, even
# though both were green once already this run.
newrepo; bash "$S" init demo --mode auto

# First pass: earn a real green all the way to P4 pass, so the second pass has
# stale-but-real green values sitting in state (the dangerous case — not just
# never-set values).
bash "$S" phase P2; bash "$S" check-set fast pass
assert_exit 0 "$(gate)" "first pass: P2 allows on fresh fast + no tasks"
bash "$S" phase P3; bash "$S" check-set large pass
assert_exit 0 "$(gate)" "first pass: P3 allows on fresh large"
bash "$S" phase P4; bash "$S" check-set review pass
assert_exit 0 "$(gate)" "first pass: P4 allows on fresh review pass"

# Reviewer requests changes on a second look; orchestrator reopens to P2.
bash "$S" set 'checks.review' '"changes_requested"'
bash "$S" reopen P2
assert_eq "P2" "$(bash "$S" get phase)" "reopen moved phase back to P2"
assert_eq "null" "$(bash "$S" get 'checks.large')" "reopen nulled large"
assert_eq "null" "$(bash "$S" get 'checks.review')" "reopen nulled review"

# Even though fast/tasks are still genuinely green from before, P2 alone must
# still gate; but the real proof is downstream: large+review must not survive.
assert_exit 0 "$(gate)" "P2 still allows: fast untouched by reopen, no tasks pending"

bash "$S" phase P3
assert_exit 2 "$(gate)" "P3 re-blocks: large was nulled by reopen, cannot ride first-pass green"
assert_contains "$(cat /tmp/gate.out)" "P3" "P3 re-entry reason names P3"

# Try to cheat: jump straight to P4 without re-earning large. Must still block.
bash "$S" phase P4
assert_exit 2 "$(gate)" "P4 re-blocks: review was nulled by reopen, cannot ride first-pass green"
assert_contains "$(cat /tmp/gate.out)" "P4" "P4 re-entry reason names P4"

# Re-earn large (fresh) -> P3 opens, but P4 must still be red (review still stale-null).
bash "$S" phase P3; bash "$S" check-set large pass
assert_exit 0 "$(gate)" "P3 allows once large re-earned fresh"
bash "$S" phase P4
assert_exit 2 "$(gate)" "P4 still re-blocks: review not yet re-earned even though large is fresh"

# Only once BOTH are fresh again does the cycle terminate.
bash "$S" check-set review pass
assert_exit 0 "$(gate)" "P4->P2->P3->P4 cycle terminates only once fresh large+review are both green"

# Regression guard: re-requesting changes a second time must re-null again (not
# a one-shot reopen quirk) — proves reopen is idempotent/repeatable, not a flag.
bash "$S" set 'checks.review' '"changes_requested"'
bash "$S" reopen P2
assert_eq "null" "$(bash "$S" get 'checks.large')" "second reopen also nulls large"
assert_eq "null" "$(bash "$S" get 'checks.review')" "second reopen also nulls review"
bash "$S" phase P4
assert_exit 2 "$(gate)" "second cycle: P4 re-blocks again on the fresh reopen"
bash "$S" phase P3; bash "$S" check-set large pass; bash "$S" phase P4; bash "$S" check-set review pass
assert_exit 0 "$(gate)" "second cycle terminates only once fresh large+review are both green again"

# Per-check SHA staleness threads through EVERY relevant gate check, not just the
# ones gate-p2/gate-p3-p4 happened to wire (feature: gate-staleness, T-C6). Each
# check below is earned green at SHA X with no reopen/task change involved, then
# HEAD alone advances; the gate must re-block as if the check were unset, even
# though the raw stored value is still literally "pass".

# P2 / checks.fast: earn green, advance HEAD, re-block (no reopen involved).
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P2; bash "$S" check-set fast pass
assert_exit 0 "$(gate)" "fresh fast green allows P2 (no tasks pending)"
git commit -q --allow-empty -m "advance HEAD"
assert_exit 2 "$(gate)" "fast check goes stale after HEAD advance -> P2 re-blocks"
assert_contains "$(cat /tmp/gate.out)" "P2" "P2 stale reason names P2"
assert_eq "pass" "$(bash "$S" get 'checks.fast')" "raw checks.fast is still literally pass (proves staleness is check-get logic, not a raw reset)"

# P3 / checks.large: same shape.
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P3; bash "$S" check-set large pass
assert_exit 0 "$(gate)" "fresh large green allows P3"
git commit -q --allow-empty -m "advance HEAD"
assert_exit 2 "$(gate)" "large check goes stale after HEAD advance -> P3 re-blocks"
assert_contains "$(cat /tmp/gate.out)" "P3" "P3 stale reason names P3"
assert_eq "pass" "$(bash "$S" get 'checks.large')" "raw checks.large is still literally pass"

# P4 / checks.review: same shape — this is the gap gate-p3-p4 left unclosed
# (that feature read checks.review raw, not via check-get).
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P4; bash "$S" check-set review pass
assert_exit 0 "$(gate)" "fresh review green allows P4"
git commit -q --allow-empty -m "advance HEAD"
assert_exit 2 "$(gate)" "review check goes stale after HEAD advance -> P4 re-blocks"
assert_contains "$(cat /tmp/gate.out)" "P4" "P4 stale reason names P4"
assert_eq "pass" "$(bash "$S" get 'checks.review')" "raw checks.review is still literally pass"

# Runaway guard: exceeding AGENTIC_GATE_MAX in a single phase escalates to
# needs_human + blocking_reason then allows stop (feature: gate-runaway, T-C7).
newrepo; bash "$S" init demo; bash "$S" phase P2; bash "$S" task-add t1 x
export AGENTIC_GATE_MAX=3
for i in 1 2 3; do gate >/dev/null; done
assert_exit 0 "$(gate)" "past cap -> gate allows stop (escape loop)"
assert_eq "true" "$(bash "$S" get needs_human)" "needs_human set"
assert_contains "$(bash "$S" get blocking_reason)" "P2" "blocking_reason names phase"

# Once needs_human is set, the gate allows immediately on every subsequent stop
# attempt (escape hatch stays open; doesn't keep re-blocking or re-counting).
assert_exit 0 "$(gate)" "needs_human already true -> gate allows immediately"
unset AGENTIC_GATE_MAX

# Staying under the cap keeps blocking normally (no premature escalation).
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P2; bash "$S" task-add t1 x
export AGENTIC_GATE_MAX=5
for i in 1 2 3; do assert_exit 2 "$(gate)" "attempt $i under cap still blocks normally"; done
assert_eq "false" "$(bash "$S" get needs_human)" "needs_human NOT set while under cap"
assert_eq "null" "$(bash "$S" get blocking_reason)" "blocking_reason NOT set while under cap"
unset AGENTIC_GATE_MAX

# A fresh phase gets its own counter: exhausting the cap in P2 must not carry
# over once the run legitimately advances to a new phase.
newrepo; bash "$S" init demo --mode auto; bash "$S" phase P2; bash "$S" task-add t1 x
export AGENTIC_GATE_MAX=2
for i in 1 2; do gate >/dev/null; done
bash "$S" task-set t1 verified; bash "$S" check-set fast pass
bash "$S" phase P3
assert_exit 2 "$(gate)" "new phase P3 starts its own counter (not pre-tripped by P2's exhausted count)"
assert_eq "false" "$(bash "$S" get needs_human)" "needs_human still false: P3's own attempts are under cap"
unset AGENTIC_GATE_MAX

assert_summary

