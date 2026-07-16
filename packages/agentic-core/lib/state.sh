#!/usr/bin/env bash
# agentic-core state.sh — jq-backed CLI over the `.agentic/state.json` schema (D-7).
# Usage: state.sh <command> [args...]
#   init <feature> [--mode interactive|auto] [--change <id>]
#   get <dot-path>            (jq filter, no leading dot required for plain keys)
#   set <dot-path> <json>     (json is a raw jq value literal, e.g. '"foo"', '42', 'null')
#   check-set <name> <value>  (sets checks.<name> and checks.<name>_at = current HEAD sha, T-C6)
#   check-get <name>          (checks.<name> if checks.<name>_at == HEAD, else "null" — stale)
#   checkpoints-add <phase> <label> <sha> <green>  (appends to state.checkpoints, consumed by checkpoint.sh)
#   e2e-plan-add <scenario>   (appends to state.e2e_plan; plan data, never SHA-stamped)
#
# $AGENTIC_STATE overrides the state file location (default: <cwd>/.agentic/state.json).
# Fail-open on missing jq or missing state file for read paths (never brick a session, D-9/T-C8).
set -uo pipefail

STATE_FILE="${AGENTIC_STATE:-$(pwd)/.agentic/state.json}"

_has_jq() { command -v jq >/dev/null 2>&1; }

cmd_init() {
  local feature="$1"; shift
  local mode="interactive" change_id="null"
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      --change) change_id="\"$2\""; shift 2 ;;
      *) shift ;;
    esac
  done
  _has_jq || { echo "jq not found; skipping init" >&2; exit 0; }
  mkdir -p "$(dirname "$STATE_FILE")"
  local created_at
  created_at="$(date -u +%FT%TZ)"
  jq -n \
    --arg schema "agentic-state/1" \
    --arg feature "$feature" \
    --arg created_at "$created_at" \
    --arg mode "$mode" \
    --argjson change_id "$change_id" \
    '{
      schema: $schema,
      feature: $feature,
      created_at: $created_at,
      phase: "P0",
      mode: $mode,
      change_id: $change_id,
      worktree_path: null,
      verify_cmds: { fast: null, component: null, large: null },
      checks: { fast: null, large: null, review: null },
      tasks: [],
      e2e_plan: [],
      checkpoints: [],
      gate_attempts: 0,
      needs_human: false,
      blocking_reason: null
    }' > "$STATE_FILE"
}

cmd_get() {
  local path="$1"
  _has_jq || { echo "null"; exit 0; }
  [ -f "$STATE_FILE" ] || { echo "null"; exit 0; }
  jq -r ".${path}" "$STATE_FILE" 2>/dev/null
}

cmd_set() {
  local path="$1" value="$2"
  _has_jq || { echo "jq not found; skipping set" >&2; exit 0; }
  [ -f "$STATE_FILE" ] || { echo "no state file at $STATE_FILE" >&2; exit 0; }
  local tmp
  tmp="$(mktemp)"
  jq ".${path} = ${value}" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

cmd_phase() {
  local p="$1"
  _has_jq || { exit 0; }
  [ -f "$STATE_FILE" ] || { exit 0; }
  local tmp
  tmp="$(mktemp)"
  jq --arg p "$p" '.phase = $p' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

cmd_task_add() {
  local id="$1" title="$2"
  _has_jq || { exit 0; }
  [ -f "$STATE_FILE" ] || { exit 0; }
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$id" --arg title "$title" \
    '.tasks += [{id: $id, title: $title, status: "pending"}]' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# e2e-plan-add <scenario> — appends one planned e2e scenario to .e2e_plan.
# Plan data, not a check: it carries no SHA stamp and `reopen` never clears it,
# exactly like .tasks. The P1 gate requires this to be non-empty before execute
# whenever the project actually has an e2e runner (verify_cmds.e2e non-null).
cmd_e2e_plan_add() {
  local scenario="${1:?usage: e2e-plan-add <scenario>}" tmp
  tmp="$(mktemp)"
  jq --arg s "$scenario" '.e2e_plan += [$s]' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

cmd_task_set() {
  local id="$1" status="$2"
  _has_jq || { exit 0; }
  [ -f "$STATE_FILE" ] || { exit 0; }
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$id" --arg status "$status" \
    '.tasks |= map(if .id == $id then .status = $status else . end)' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

cmd_tasks_remaining() {
  _has_jq || { echo "0"; exit 0; }
  [ -f "$STATE_FILE" ] || { echo "0"; exit 0; }
  jq -r '[.tasks[] | select(.status != "verified")] | length' "$STATE_FILE" 2>/dev/null
}

# reopen <fromPhase> — re-entering fromPhase after a downstream rejection (e.g. P4
# sets review=changes_requested and the orchestrator moves back to P2). Nulls the
# checks that are downstream of fromPhase so a later stop can't pass on a stale
# green from the previous pass (T-C5), then sets phase to fromPhase.
cmd_reopen() {
  local from="$1"
  _has_jq || { exit 0; }
  [ -f "$STATE_FILE" ] || { exit 0; }
  local tmp
  tmp="$(mktemp)"
  case "$from" in
    P2)
      # large (P3) and review (P4) are downstream of P2; fast is P2's own check
      # and is left to SHA-based staleness (T-C6), not reopen.
      jq --arg p "$from" \
        '.phase = $p
         | .checks.large = null | .checks.large_at = null
         | .checks.review = null | .checks.review_at = null' \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      ;;
    *)
      jq --arg p "$from" '.phase = $p' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      ;;
  esac
}

# check-set <name> <value> — sets checks.<name> and stamps checks.<name>_at with the
# current `git rev-parse HEAD` (empty string outside a repo). T-C6 support: lets a
# consumer (verify-gate.sh, plan 04) tell a check was computed for the current commit.
cmd_check_set() {
  local name="$1" value="$2"
  _has_jq || { exit 0; }
  [ -f "$STATE_FILE" ] || { exit 0; }
  local sha tmp
  sha="$(git rev-parse HEAD 2>/dev/null || echo "")"
  tmp="$(mktemp)"
  jq --arg name "$name" --arg value "$value" --arg sha "$sha" \
    '.checks[$name] = $value | .checks[$name + "_at"] = $sha' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# check-get <name> — staleness-aware read (T-C6): returns the stamped value only if
# checks.<name>_at still equals the current HEAD; otherwise "null" (never-set or the
# tree has moved past the commit the check was computed at — treat as unset).
cmd_check_get() {
  local name="$1"
  _has_jq || { echo "null"; exit 0; }
  [ -f "$STATE_FILE" ] || { echo "null"; exit 0; }
  local sha stamped_at value
  sha="$(git rev-parse HEAD 2>/dev/null || echo "")"
  stamped_at="$(jq -r ".checks[\"${name}_at\"] // \"\"" "$STATE_FILE" 2>/dev/null)"
  if [ -z "$stamped_at" ] || [ "$stamped_at" = "null" ] || [ "$stamped_at" != "$sha" ]; then
    echo "null"
    return 0
  fi
  value="$(jq -r ".checks[\"${name}\"] // \"null\"" "$STATE_FILE" 2>/dev/null)"
  echo "$value"
}

# checkpoints-add <phase> <label> <sha> <green> — appends a checkpoint record
# {phase,label,sha,green,ts} to state.checkpoints. <green> is "true"/"false" (or
# anything jq's `test("^true$")` treats as true). Consumed by checkpoint.sh (D-12).
cmd_checkpoints_add() {
  local phase="$1" label="$2" sha="$3" green="$4"
  _has_jq || { exit 0; }
  [ -f "$STATE_FILE" ] || { exit 0; }
  local ts tmp greenjson
  ts="$(date -u +%FT%TZ)"
  [ "$green" = "true" ] && greenjson="true" || greenjson="false"
  tmp="$(mktemp)"
  jq --arg phase "$phase" --arg label "$label" --arg sha "$sha" --argjson green "$greenjson" --arg ts "$ts" \
    '.checkpoints += [{phase: $phase, label: $label, sha: $sha, green: $green, ts: $ts}]' \
    "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    init) cmd_init "$@" ;;
    get) cmd_get "$@" ;;
    set) cmd_set "$@" ;;
    phase) cmd_phase "$@" ;;
    task-add) cmd_task_add "$@" ;;
    task-set) cmd_task_set "$@" ;;
    tasks-remaining) cmd_tasks_remaining "$@" ;;
    e2e-plan-add) cmd_e2e_plan_add "$@" ;;
    reopen) cmd_reopen "$@" ;;
    check-set) cmd_check_set "$@" ;;
    check-get) cmd_check_get "$@" ;;
    checkpoints-add) cmd_checkpoints_add "$@" ;;
    *) echo "usage: state.sh {init|get|set|phase|task-add|task-set|tasks-remaining|e2e-plan-add|reopen|check-set|check-get|checkpoints-add} ..." >&2; exit 1 ;;
  esac
}

main "$@"
