#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
export AGENTIC_STATE="$(mktemp -d)/state.json"
S="$ROOT/packages/agentic-core/lib/state.sh"
bash "$S" init demo --mode auto --change c-1
assert_eq "agentic-state/1" "$(bash "$S" get schema)" "schema key"
assert_eq "demo" "$(bash "$S" get feature)" "feature recorded"
assert_eq "P0" "$(bash "$S" get phase)" "phase defaults P0"
assert_eq "auto" "$(bash "$S" get mode)" "mode recorded"
assert_eq "c-1" "$(bash "$S" get change_id)" "change_id recorded"
assert_eq "null" "$(bash "$S" get worktree_path)" "worktree_path default null"
assert_eq "null" "$(bash "$S" get 'verify_cmds.fast')" "verify_cmds.fast null"
assert_eq "null" "$(bash "$S" get 'verify_cmds.component')" "verify_cmds.component null"
assert_eq "null" "$(bash "$S" get 'verify_cmds.large')" "verify_cmds.large null"
assert_eq "null" "$(bash "$S" get 'checks.fast')" "checks.fast null"
assert_eq "null" "$(bash "$S" get 'checks.large')" "checks.large null"
assert_eq "null" "$(bash "$S" get 'checks.review')" "checks.review null"
assert_eq "0" "$(bash "$S" get 'tasks | length')" "tasks empty array"
assert_eq "0" "$(bash "$S" get 'checkpoints | length')" "checkpoints empty array"
assert_eq "0" "$(bash "$S" get gate_attempts)" "gate_attempts default 0"
assert_eq "false" "$(bash "$S" get needs_human)" "needs_human default"
assert_eq "null" "$(bash "$S" get blocking_reason)" "blocking_reason default null"

# default mode/change_id when flags omitted
export AGENTIC_STATE="$(mktemp -d)/state.json"
bash "$S" init demo2
assert_eq "interactive" "$(bash "$S" get mode)" "mode defaults interactive"
assert_eq "null" "$(bash "$S" get change_id)" "change_id defaults null"

# set an arbitrary dot-key
bash "$S" set blocking_reason '"stuck"'
assert_eq "stuck" "$(bash "$S" get blocking_reason)" "set writes blocking_reason"

# phase transitions + task lifecycle + tasks-remaining (feature: state-phase-tasks)
export AGENTIC_STATE="$(mktemp -d)/state.json"
bash "$S" init demo3
bash "$S" phase P2
assert_eq "P2" "$(bash "$S" get phase)" "phase set"
bash "$S" task-add t1 "impl add"
bash "$S" task-add t2 "impl sub"
assert_eq "2" "$(bash "$S" get 'tasks | length')" "two tasks added"
assert_eq "pending" "$(bash "$S" get 'tasks[0].status')" "task defaults pending status"
assert_eq "impl add" "$(bash "$S" get 'tasks[0].title')" "task title recorded"
assert_eq "2" "$(bash "$S" tasks-remaining)" "2 remaining"
bash "$S" task-set t1 verified
assert_eq "verified" "$(bash "$S" get 'tasks[0].status')" "task-set updates status"
assert_eq "1" "$(bash "$S" tasks-remaining)" "1 remaining after verify"

# reopen nulls downstream checks on P4->P2 re-entry (feature: state-reopen, T-C5)
export AGENTIC_STATE="$(mktemp -d)/state.json"
bash "$S" init demo4
bash "$S" phase P4
bash "$S" set 'checks.fast' '"pass"'
bash "$S" set 'checks.fast_at' '"sha-fast-old"'
bash "$S" set 'checks.large' '"pass"'
bash "$S" set 'checks.large_at' '"sha-old-1"'
bash "$S" set 'checks.review' '"changes_requested"'
bash "$S" set 'checks.review_at' '"sha-old-2"'
bash "$S" reopen P2
assert_eq "P2" "$(bash "$S" get phase)" "reopen sets phase to fromPhase"
assert_eq "null" "$(bash "$S" get 'checks.large')" "large nulled on reopen P2"
assert_eq "null" "$(bash "$S" get 'checks.large_at')" "large_at nulled on reopen P2"
assert_eq "null" "$(bash "$S" get 'checks.review')" "review nulled on reopen P2"
assert_eq "null" "$(bash "$S" get 'checks.review_at')" "review_at nulled on reopen P2"
assert_eq "pass" "$(bash "$S" get 'checks.fast')" "fast NOT nulled on reopen P2 (not downstream)"
assert_eq "sha-fast-old" "$(bash "$S" get 'checks.fast_at')" "fast_at NOT nulled on reopen P2"

# SHA-stamped check-set + staleness-aware check-get (feature: state-check-sha, T-C6)
G="$(mktemp -d)"
( cd "$G" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m base )
export AGENTIC_STATE="$G/.agentic/state.json"
( cd "$G" && bash "$S" init demo5 )
( cd "$G" && bash "$S" check-set fast pass )
sha1="$(cd "$G" && git rev-parse HEAD)"
assert_eq "pass" "$(cd "$G" && bash "$S" get 'checks.fast')" "check-set writes checks.fast"
assert_eq "$sha1" "$(cd "$G" && bash "$S" get 'checks.fast_at')" "check-set stamps checks.fast_at with HEAD sha"
assert_eq "pass" "$(cd "$G" && bash "$S" check-get fast)" "check-get returns value when HEAD unchanged"

# advance HEAD; the stamped check must now read as stale (null) via check-get
( cd "$G" && echo more >> f.txt && git add -A && git commit -q -m advance )
sha2="$(cd "$G" && git rev-parse HEAD)"
assert_eq "no" "$([ "$sha1" = "$sha2" ] && echo yes || echo no)" "HEAD actually advanced"
assert_eq "pass" "$(cd "$G" && bash "$S" get 'checks.fast')" "raw checks.fast value untouched by advancing HEAD"
assert_eq "null" "$(cd "$G" && bash "$S" check-get fast)" "check-get reports stale check as null after HEAD advances"

# a check that was never set is null via check-get too
assert_eq "null" "$(cd "$G" && bash "$S" check-get large)" "check-get null for never-set check"

# re-stamping at the new HEAD makes it valid again
( cd "$G" && bash "$S" check-set fast pass )
assert_eq "pass" "$(cd "$G" && bash "$S" check-get fast)" "check-get valid again after re-running fast at new HEAD"

# --- e2e_plan (feature: e2e-plan-gate) ---
assert_eq "0" "$(bash "$S" get 'e2e_plan | length')" "e2e_plan initializes empty"
bash "$S" e2e-plan-add "Given a report with rows, clicking Export downloads a .csv"
assert_eq "1" "$(bash "$S" get 'e2e_plan | length')" "e2e-plan-add appends a scenario"
bash "$S" e2e-plan-add "Given zero rows, the .csv has only a header row"
assert_eq "2" "$(bash "$S" get 'e2e_plan | length')" "e2e-plan-add appends a second scenario"
assert_contains "$(bash "$S" get 'e2e_plan[0]')" "downloads a .csv" "scenario text round-trips"

# e2e_plan is plan data, not a check: reopen must NOT clear it (mirrors .tasks)
bash "$S" reopen P2 >/dev/null
assert_eq "2" "$(bash "$S" get 'e2e_plan | length')" "reopen P2 preserves e2e_plan"

assert_summary
