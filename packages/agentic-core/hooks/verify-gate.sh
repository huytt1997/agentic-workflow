#!/usr/bin/env bash
# verify-gate.sh — Stop/SubagentStop hook (D-8/I-3).
#
# On every stop attempt, evaluates the current phase's gate against
# `.agentic/state.json` (via the product `state.sh`, D-7). If the gate is red,
# prints `{"decision":"block","reason":"<gate_reason>"}` and exits 2 (force
# the agent to continue); otherwise exits 0 (allow the stop).
#
# Fail-open (T-C8, feature: gate-fail-open): a missing `jq` binary or missing
# state file must never brick a session — both cases exit 0 immediately (see
# the `command -v jq` / `[ -f "$STATE_FILE" ]` guards just below). The hook
# never reads its stdin event at all (unlike safety-guard.sh, it doesn't need
# tool_name/tool_input), so a malformed/non-JSON stdin payload is inherently
# harmless — it is simply never parsed. All three fail-open paths (missing
# state, missing jq, malformed stdin) are proven end-to-end, including against
# a genuinely red state (not just an empty one), by the "gate-fail-open"
# fixtures in verify_gate_test.sh.
#
# Gate contract per phase (execution-plan.md §3.2 / plan 04's gate-contract
# table). This feature (gate-p2) implements P0, P1, and P2; feature gate-p3-p4
# adds P3, P4, P5, and the else (default-allow) case:
#   P0 | block: worktree_path unset                | allow: worktree recorded
#   P1 | block: verify_cmds.fast/large or tasks     | allow: recorded, and
#      | unrecorded; (interactive) plan_approved    |   (interactive) approved
#      | not true                                   |
#   P2 | block: tasks-remaining != 0, or effective   | allow: all tasks
#      | checks.fast != pass                         |   verified AND fast pass
#   P3 | block: effective checks.large != pass       | allow: large pass
#   P4 | block: checks.review != pass                | allow: review pass
#      | (e.g. == "changes_requested")               |
#   P5 | block: auto mode AND worktree_path still    | allow: interactive
#      | exists on disk (cleanup not done)            |   (handed off), or
#      |                                               |   worktree removed
#   else | never blocks                               | always allows
# P4->P2 re-entry (gate-reentry, T-C5): no gate code change was needed here —
# the P3/P4 branches already read the effective (staleness-aware) checks, and
# `state.sh reopen P2` (plan 02) nulls checks.large/checks.review on re-entry,
# so a P4 changes_requested -> reopen P2 -> P3 -> P4 cycle cannot terminate on
# the *previous* pass's green. Proven end-to-end by the integration-style
# fixture in verify_gate_test.sh (a full two-cycle P4->P2->P3->P4 walk).
# Per-check SHA staleness (gate-staleness, T-C6): every gate-relevant check
# (fast/P2, large/P3, review/P4) reads through `state.sh check-get`, which
# treats a check as effective-null whenever its `_at` stamp no longer equals
# the current HEAD -- so a green check earned at SHA X silently goes stale the
# moment HEAD advances past X, with no reopen required. Proven end-to-end by
# the "SHA staleness" fixtures in verify_gate_test.sh (advance HEAD alone,
# raw stored value stays "pass", gate still re-blocks). The runaway guard
# (gate-runaway) is a separate feature, not implemented here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
STATE_SH="$SCRIPT_DIR/../lib/state.sh"

command -v jq >/dev/null 2>&1 || exit 0

STATE_FILE="${AGENTIC_STATE:-$(pwd)/.agentic/state.json}"
[ -f "$STATE_FILE" ] || exit 0

_get() { bash "$STATE_SH" get "$1" 2>/dev/null; }

# needs_human already escalated (e.g. a prior runaway) -> always allow the
# stop immediately; don't keep re-blocking or re-counting attempts (T-C7).
if [ "$(_get needs_human)" = "true" ]; then
  exit 0
fi

# _set_str <dot-path> <raw-string-value> — write a JSON string value through
# state.sh's generic `set` (which expects a jq value literal), quoting safely.
_set_str() {
  local path="$1" val="$2" json
  json="$(jq -n --arg v "$val" '$v')"
  bash "$STATE_SH" set "$path" "$json" >/dev/null 2>&1
}

# _block <reason> — per-phase runaway guard (T-C7): each block attempt for
# the CURRENT phase increments a counter; a phase change resets it (a fresh
# phase starts its own counter). Once the count exceeds AGENTIC_GATE_MAX
# (default 25) this phase is declared stuck: set needs_human=true + a
# human-readable blocking_reason, and ALLOW the stop instead of blocking
# forever. Below the cap, behaves exactly as before: print the block JSON
# and exit 2.
_block() {
  local reason="$1"
  local gate_max="${AGENTIC_GATE_MAX:-25}"
  local stored_phase attempts
  stored_phase="$(_get gate_attempts_phase)"
  if [ "$stored_phase" = "$PHASE" ]; then
    attempts="$(_get gate_attempts)"
    case "$attempts" in ''|null|*[!0-9]*) attempts=0 ;; esac
  else
    attempts=0
  fi
  attempts=$((attempts + 1))
  _set_str gate_attempts_phase "$PHASE"
  bash "$STATE_SH" set gate_attempts "$attempts" >/dev/null 2>&1

  if [ "$attempts" -gt "$gate_max" ]; then
    bash "$STATE_SH" set needs_human true >/dev/null 2>&1
    _set_str blocking_reason "runaway in ${PHASE}: ${reason}"
    exit 0
  fi

  jq -n --arg reason "$reason" '{decision:"block",reason:$reason}'
  exit 2
}

PHASE="$(_get phase)"

case "$PHASE" in
  P0)
    wt="$(_get worktree_path)"
    if [ -z "$wt" ] || [ "$wt" = "null" ]; then
      _block "P0: worktree_path not recorded"
    fi
    ;;
  P1)
    vf="$(_get 'verify_cmds.fast')"
    vl="$(_get 'verify_cmds.large')"
    tasks_len="$(_get 'tasks | length')"
    if [ -z "$vf" ] || [ "$vf" = "null" ] || [ -z "$vl" ] || [ "$vl" = "null" ] \
      || [ -z "$tasks_len" ] || [ "$tasks_len" = "0" ]; then
      _block "P1: plan/verify_cmds not recorded"
    fi
    mode="$(_get mode)"
    if [ "$mode" = "interactive" ]; then
      approved="$(_get plan_approved)"
      if [ "$approved" != "true" ]; then
        _block "P1: plan not approved (interactive)"
      fi
    fi
    ;;
  P2)
    remaining="$(bash "$STATE_SH" tasks-remaining 2>/dev/null)"
    if [ "$remaining" != "0" ]; then
      _block "P2: tasks remaining"
    fi
    fast="$(bash "$STATE_SH" check-get fast 2>/dev/null)"
    if [ "$fast" != "pass" ]; then
      _block "P2: fast verify red"
    fi
    ;;
  P3)
    large="$(bash "$STATE_SH" check-get large 2>/dev/null)"
    if [ "$large" != "pass" ]; then
      _block "P3: large verify red"
    fi
    ;;
  P4)
    review="$(bash "$STATE_SH" check-get review 2>/dev/null)"
    if [ "$review" != "pass" ]; then
      _block "P4: review not pass (${review})"
    fi
    ;;
  P5)
    mode="$(_get mode)"
    if [ "$mode" = "auto" ]; then
      wt="$(_get worktree_path)"
      if [ -n "$wt" ] && [ "$wt" != "null" ] && [ -d "$wt" ]; then
        _block "P5: cleanup not done (worktree still present)"
      fi
    fi
    ;;
  *)
    : # else -> always allow (unknown/unhandled phase)
    ;;
esac

exit 0
