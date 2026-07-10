#!/usr/bin/env bash
# structure_test.sh — structural proof for the agentic-engineer scaffold.
# Feature `engineer-loads`: the /engineer command + engineer-hooks.json exist and are valid
# (plugin.json / marketplace registration retired with the Claude-plugin install mechanism).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"; . "$ROOT/tests/lib/assert.sh"
PP="$ROOT/packages/agentic-engineer"

assert_exit 0 "$( [ -f "$PP/commands/engineer.md" ] && echo 0 || echo 1 )" "engineer command exists"
assert_exit 0 "$(jq -e . "$PP/hooks/engineer-hooks.json" >/dev/null 2>&1 && echo 0 || echo 1)" "engineer-hooks.json valid"

# Feature `orchestrator-sop`: the P0-P5 SOP with the interactive/auto mode split (T-E1..E6,E10).
SK="$PP/skills/agentic-engineer/SKILL.md"
assert_exit 0 "$( [ -f "$SK" ] && echo 0 || echo 1 )" "SKILL.md exists"
body="$(cat "$SK" 2>/dev/null)"
for p in P0 P1 P2 P3 P4 P5; do assert_contains "$body" "$p" "SOP covers $p"; done
assert_contains "$body" "interactive" "SOP has interactive mode"
assert_contains "$body" "auto" "SOP has auto mode"
assert_contains "$body" "assumptions.md" "auto writes assumptions.md for gaps"
assert_contains "$body" "human approval" "interactive stops for human approval at P1"
assert_contains "$body" "worktree-first" "documents worktree-first (P0 before P1)"
assert_contains "$body" "agentic-state" "drives state via agentic-state"
# References the 5 subagent roles by name (files themselves are feature subagents-scoped)
for a in worktree planner executor qa reviewer; do
  assert_contains "$body" "$a" "SOP references the $a subagent"
done
# Names the confirmed superpowers skill IDs
for sk in using-git-worktrees brainstorming writing-plans executing-plans test-driven-development verification-before-completion requesting-code-review; do
  assert_contains "$body" "$sk" "SOP names superpowers skill $sk"
done
# Forward references to later features, without implementing them here
assert_contains "$body" "detect-verify" "SOP references detect-verify (feature detect-verify)"
assert_contains "$body" "auto-outcome" "SOP references the outcome contract (feature auto-outcome)"
assert_contains "$body" "needs-human-escalate" "SOP references needs_human handling (feature needs-human-escalate)"

# Feature `needs-human-escalate`: the SOP must document check-early / stop-don't-retry /
# write-outcome-with-needs_human behaviour explicitly, not just a single P0 precondition (T-E9).
# The runaway guard that SETS needs_human lives in verify-gate.sh (plan 04, gate-runaway) and
# ALLOWS the stop; this SOP owns what happens on the *next* re-entry after that allowed stop.
assert_contains "$body" "needs_human" "SOP handles needs_human"
assert_contains "$body" "blocking_reason" "SOP surfaces blocking_reason"
assert_contains "$body" "do not retry" "SOP does not retry on needs_human"
assert_contains "$body" "top of every phase" "SOP checks needs_human at the top of every phase re-entry, not just once before P0"
assert_contains "$body" "loop back into the same phase" "SOP documents it never loops back into the same phase after escalation"
assert_contains "$body" "status: needs_human" "SOP wires the auto-mode escalation into write-outcome.sh with status needs_human"

# Feature `subagents-scoped`: five correctly-scoped subagent definitions (T-E11, T-E12).
AG="$PP/agents"
for a in worktree planner executor qa reviewer; do
  assert_exit 0 "$( [ -f "$AG/$a.md" ] && echo 0 || echo 1 )" "agent $a exists"
done
# reviewer is read-only: must NOT grant Edit or Write
assert_exit 1 "$(grep -Eiq '^\s*tools:.*(Edit|Write)' "$AG/reviewer.md" && echo 0 || echo 1)" "reviewer has no Edit/Write"
# qa restricted to test files (states the constraint)
assert_contains "$(cat "$AG/qa.md")" "test files only" "qa restricted to test files"
# model pins present per role
assert_contains "$(cat "$AG/worktree.md")" "haiku" "worktree pins haiku"
assert_contains "$(cat "$AG/planner.md")" "opus" "planner pins opus"
assert_contains "$(cat "$AG/executor.md")" "sonnet" "executor pins sonnet"
assert_contains "$(cat "$AG/qa.md")" "sonnet" "qa pins sonnet"
assert_contains "$(cat "$AG/reviewer.md")" "opus" "reviewer pins opus"
# skill IDs referenced correctly (plural worktrees)
assert_contains "$(cat "$AG/worktree.md")" "using-git-worktrees" "correct worktree skill id"
assert_contains "$(cat "$AG/planner.md")" "brainstorming" "planner names brainstorming"
assert_contains "$(cat "$AG/planner.md")" "writing-plans" "planner names writing-plans"
assert_contains "$(cat "$AG/executor.md")" "executing-plans" "executor names executing-plans"
assert_contains "$(cat "$AG/qa.md")" "test-driven-development" "qa names test-driven-development"
assert_contains "$(cat "$AG/qa.md")" "verification-before-completion" "qa names verification-before-completion"
assert_contains "$(cat "$AG/reviewer.md")" "requesting-code-review" "reviewer names requesting-code-review"
# every subagent restates worktree confinement (I-6) and target-project-wins (I-10)
for a in worktree planner executor qa reviewer; do
  b="$(cat "$AG/$a.md")"
  assert_contains "$b" "worktree" "$a restates worktree confinement"
  assert_contains "$b" "target project" "$a restates target project's guidelines win"
done
# frontmatter has name/description/tools/model keys
for a in worktree planner executor qa reviewer; do
  assert_exit 0 "$(grep -Eq '^name:' "$AG/$a.md" && echo 0 || echo 1)" "$a frontmatter has name"
  assert_exit 0 "$(grep -Eq '^description:' "$AG/$a.md" && echo 0 || echo 1)" "$a frontmatter has description"
  assert_exit 0 "$(grep -Eq '^tools:' "$AG/$a.md" && echo 0 || echo 1)" "$a frontmatter has tools"
done

# Feature `auto-outcome`: P5-auto outcome contract writer (T-E8, pm-outcome/1 schema).
WO="$PP/lib/write-outcome.sh"
assert_exit 0 "$( [ -f "$WO" ] && echo 0 || echo 1 )" "write-outcome helper exists"

TGT="$(mktemp -d)"
bash "$WO" "$TGT" c-1 success 3 2
oc="$TGT/openspec/.pm/outcomes/c-1.json"
assert_exit 0 "$(jq -e . "$oc" >/dev/null 2>&1 && echo 0 || echo 1)" "outcome json valid"
assert_eq "pm-outcome/1" "$(jq -r .schema "$oc")" "outcome schema"
assert_eq "c-1" "$(jq -r .change_id "$oc")" "outcome change_id"
assert_eq "success" "$(jq -r .status "$oc")" "outcome status"
assert_eq "null" "$(jq -r .reason "$oc")" "success -> reason null"
assert_eq "3" "$(jq -r .checkpoints "$oc")" "outcome checkpoints"
assert_eq "null" "$(jq -r .pr "$oc")" "outcome pr defaults null"
assert_exit 0 "$(jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$oc" >/dev/null 2>&1 && echo 0 || echo 1)" "outcome ts is iso8601"
assert_eq "true" "$(jq -r .verification.large_passed "$oc")" "success -> large_passed true"
assert_eq "2" "$(jq -r .verification.tests_written "$oc")" "outcome tests_written"
assert_eq "component" "$(jq -r '.verification.levels[0]' "$oc")" "outcome levels present"

# needs_human / failed must never claim large_passed:true (no self-contradictory success record)
TGT2="$(mktemp -d)"
bash "$WO" "$TGT2" c-2 needs_human 1 0 "blocked on missing credential"
oc2="$TGT2/openspec/.pm/outcomes/c-2.json"
assert_eq "needs_human" "$(jq -r .status "$oc2")" "needs_human status recorded"
assert_eq "false" "$(jq -r .verification.large_passed "$oc2")" "needs_human -> large_passed false"
assert_eq "blocked on missing credential" "$(jq -r .reason "$oc2")" "needs_human reason recorded"

TGT3="$(mktemp -d)"
bash "$WO" "$TGT3" c-3 failed 0 0 "large suite red"
oc3="$TGT3/openspec/.pm/outcomes/c-3.json"
assert_eq "false" "$(jq -r .verification.large_passed "$oc3")" "failed -> large_passed false"

# an unknown status must fail closed: non-zero exit, no file written
TGT4="$(mktemp -d)"
bash "$WO" "$TGT4" c-4 bogus-status 0 0 >/tmp/write-outcome-bogus.out 2>&1
rc=$?
assert_exit 1 "$rc" "bogus status exits non-zero"
assert_exit 1 "$( [ -f "$TGT4/openspec/.pm/outcomes/c-4.json" ] && echo 0 || echo 1 )" "bogus status writes no outcome file"

assert_summary
