#!/usr/bin/env bash
# pm-runner.sh — deterministic PM outer loop (I-1/D-14). Sourceable-or-runnable:
# functions are unit-tested by sourcing; `main` runs only on direct execution.
# Gates on the pm-outcome/1 contract file, never the engineer process exit code.
set -uo pipefail
PM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$PM_DIR/../lib/frontmatter.sh"

_pm_die() { echo "pm-runner: $*" >&2; exit 1; }

preflight() {
  for c in jq claude openspec; do command -v "$c" >/dev/null 2>&1 || { echo "pm-runner: missing '$c'" >&2; return 1; }; done
  [ -n "${AGENTIC_PROJECT_ROOT:-}" ] || { echo "pm-runner: AGENTIC_PROJECT_ROOT unset" >&2; return 1; }
  [ -d "$AGENTIC_PROJECT_ROOT/openspec" ] || { echo "pm-runner: target not openspec-initialized" >&2; return 1; }
  return 0
}

pg_file() { printf '%s' "$AGENTIC_PROJECT_ROOT/openspec/.pm/progress.json"; }

pg_init() {
  local f; f="$(pg_file)"; mkdir -p "$(dirname "$f")"
  [ -f "$f" ] && return 0
  jq -n '{schema:"pm-progress/1",done:[],failed:[],blocked:[],cursor:null,meta:{},
          budget:{cost_cap_usd:null,wall_clock_cap_min:null,spent_usd:0,elapsed_min:0,start_epoch:null}}' > "$f"
}

pg_bucket() { jq -r --arg b "$1" '.[$b][]' "$(pg_file)"; }

pg_in_bucket() {
  local id="$1"
  jq -e --arg id "$id" '(.done+.failed+.blocked) | index($id) != null' "$(pg_file)" >/dev/null 2>&1
}

pg_push() {
  local b="$1" id="$2" f tmp; f="$(pg_file)"; tmp="$(mktemp)"
  jq --arg b "$b" --arg id "$id" '.[$b] |= (. + [$id] | unique_by(.))' "$f" > "$tmp" && mv "$tmp" "$f"
}

pg_meta_set() {
  local id="$1" st="$2" rs="$3" cost="$4" f tmp; f="$(pg_file)"; tmp="$(mktemp)"
  jq --arg id "$id" --arg st "$st" --arg rs "${rs:0:200}" --argjson cost "${cost:-0}" \
    '.meta[$id] = ((.meta[$id] // {attempts:0}) as $m
       | {attempts:(($m.attempts // 0)+1),last_status:$st,reason:(if $rs=="" then null else $rs end),
          ts:(now|todate),cost_usd:$cost})' "$f" > "$tmp" && mv "$tmp" "$f"
}

pg_elapsed_update() {
  # C1 fix: budget.elapsed_min was never written, so PM_TIME_CAP_MIN could never
  # trip. First call persists a start_epoch marker (loop start); every later call
  # recomputes elapsed_min from that stored marker vs. current wall-clock time, so
  # a long-running main() loop's next iteration sees real elapsed minutes.
  local f tmp now start; f="$(pg_file)"; tmp="$(mktemp)"
  now="$(date +%s)"
  start="$(jq -r '.budget.start_epoch // empty' "$f")"
  if [ -z "$start" ]; then
    jq --argjson now "$now" '.budget.start_epoch = $now | .budget.elapsed_min = 0' "$f" > "$tmp" && mv "$tmp" "$f"
    return 0
  fi
  jq --argjson now "$now" --argjson start "$start" \
    '.budget.elapsed_min = ((($now - $start) / 60) | floor)' "$f" > "$tmp" && mv "$tmp" "$f"
}

pg_budget_add() {
  # Deviation from plan's literal snippet: plain jq float addition drifts
  # (e.g. 0.05+0.10 -> 0.15000000000000002). Round to 6dp to keep spent_usd
  # comparable/printable exactly (fixes pm_progress_test.sh's "budget accrues").
  local cost="$1" f tmp; f="$(pg_file)"; tmp="$(mktemp)"
  jq --argjson c "${cost:-0}" \
    '.budget.spent_usd = ((((.budget.spent_usd // 0) + $c) * 1000000 | round) / 1000000)' \
    "$f" > "$tmp" && mv "$tmp" "$f"
}

# Single indirection point for the OpenSpec CLI (decision D-A): flag drift = one-line fix here.
os_validate() { openspec validate "$1" --strict; }
os_archive()  { openspec archive "$1" --yes; }
os_list_active() {
  local d="$AGENTIC_PROJECT_ROOT/openspec/changes"
  [ -d "$d" ] || return 0
  find "$d" -mindepth 1 -maxdepth 1 -type d ! -name archive -exec basename {} \; | sort
}

# Deterministic: eligible = deps all in done AND id not in any bucket -> lowest priority -> lowest id.
next_change() {
  local done_ids id dep dir prio ok cand=""
  done_ids=" $(pg_bucket done | tr '\n' ' ') "
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    pg_in_bucket "$id" && continue
    dir="$AGENTIC_PROJECT_ROOT/openspec/changes/$id/proposal.md"
    ok=1
    for dep in $(fm_depends "$dir"); do
      case "$done_ids" in *" $dep "*) ;; *) ok=0; break;; esac
    done
    [ "$ok" = 1 ] || continue
    prio="$(fm_priority "$dir")"
    # keep the candidate with the lowest (priority,id); printf a sortable key
    printf '%06d\t%s\n' "$prio" "$id"
  done < <(os_list_active) | sort | head -1 | cut -f2-
}

# Deviation from plan's literal snippet: an unescaped `}` inside the default
# text closes the ${VAR:=...} expansion early (bash parses the first
# unescaped `}` as the end of the substitution), truncating the default to
# ".../--change {id". Escape the inner brace so the full default survives.
: "${PM_ENGINEER_CMD:=/agentic-engineer:engineer --change {id\} --mode auto}"
: "${PM_ALLOWED_TOOLS:=Task,Bash,Edit,Write,Read,Grep,Glob,TodoWrite}"
: "${PM_PERMISSION_MODE:=acceptEdits}"
: "${PM_DRY_RUN:=0}"

PM_LAST_COST=0
dispatch() {   # replaces the Task 6 version; keep the dry-run branch
  local id="$1" prompt outcome logdir log
  prompt="${PM_ENGINEER_CMD//\{id\}/$id}"
  outcome="$AGENTIC_PROJECT_ROOT/openspec/.pm/outcomes/$id.json"
  if [ "$PM_DRY_RUN" = "1" ]; then
    echo "DRY-RUN: would dispatch engineer for '$id': claude -p \"$prompt\" (outcome -> $outcome)"
    return 0
  fi
  rm -f "$outcome"                              # stale-outcome guard (spec §7 T-M-E1)
  logdir="$AGENTIC_PROJECT_ROOT/openspec/.pm/logs"; mkdir -p "$logdir"
  log="$logdir/$id.$(date -u +%Y%m%dT%H%M%SZ).ndjson"
  export AGENTIC_PM_OUTCOME_FILE="$outcome"
  set +e
  claude -p "$prompt" --allowedTools "$PM_ALLOWED_TOOLS" --permission-mode "$PM_PERMISSION_MODE" \
    ${PM_MODEL:+--model "$PM_MODEL"} > "$log" 2>&1
  set -e
  PM_LAST_COST="$(grep -o '"total_cost_usd":[0-9.]*' "$log" | tail -1 | cut -d: -f2)"
  [ -n "$PM_LAST_COST" ] || PM_LAST_COST=0
  return 0
}

read_outcome_status() {
  local f="$AGENTIC_PROJECT_ROOT/openspec/.pm/outcomes/$1.json"
  [ -f "$f" ] || { printf ''; return 0; }
  jq -r '.status // ""' "$f"
}
read_outcome_large() {
  local f="$AGENTIC_PROJECT_ROOT/openspec/.pm/outcomes/$1.json"
  [ -f "$f" ] || { printf 'false'; return 0; }
  jq -r '.verification.large_passed // false' "$f"
}

classify() {   # archive | block | fail
  local id="$1" st lg; st="$(read_outcome_status "$id")"; lg="$(read_outcome_large "$id")"
  if [ -z "$st" ]; then echo fail; return 0; fi
  case "$st" in
    success)      [ "$lg" = "true" ] && echo archive || echo block ;;
    needs_human)  echo block ;;
    *)            echo fail ;;
  esac
}

: "${PM_MAX_RETRIES:=1}"
: "${PM_BACKOFF_SEC:=5}"
: "${PM_ON_FAIL:=continue}"
: "${PM_ON_BLOCK:=stop}"
PM_HALT=0

handle_change() {
  local id="$1" verdict reason=""
  dispatch "$id"
  pg_budget_add "${PM_LAST_COST:-0}"
  verdict="$(classify "$id")"
  case "$verdict" in
    archive)
      if os_archive "$id"; then
        pg_push done "$id"; pg_meta_set "$id" success "" "${PM_LAST_COST:-0}"; echo done; return 0
      else
        pg_push blocked "$id"; pg_meta_set "$id" archive_failed "archive failed" "${PM_LAST_COST:-0}"
        [ "$PM_ON_BLOCK" = "stop" ] && PM_HALT=1; echo blocked; return 0
      fi ;;
    block)
      reason="$(jq -r '.reason // "needs_human"' "$AGENTIC_PROJECT_ROOT/openspec/.pm/outcomes/$id.json" 2>/dev/null)"
      pg_push blocked "$id"; pg_meta_set "$id" needs_human "$reason" "${PM_LAST_COST:-0}"
      [ "$PM_ON_BLOCK" = "stop" ] && PM_HALT=1; echo blocked; return 0 ;;
    fail)
      local tries=0
      pg_meta_set "$id" failed "run failed (attempt 1)" "${PM_LAST_COST:-0}"
      while [ "$tries" -lt "$PM_MAX_RETRIES" ]; do
        tries=$((tries+1))
        [ "${PM_BACKOFF_SEC:-5}" -gt 0 ] && sleep "$PM_BACKOFF_SEC"
        dispatch "$id"; pg_budget_add "${PM_LAST_COST:-0}"
        verdict="$(classify "$id")"
        if [ "$verdict" = "archive" ]; then
          if os_archive "$id"; then
            pg_push done "$id"; pg_meta_set "$id" success "" "${PM_LAST_COST:-0}"; echo done; return 0
          else
            # M2 fix: mirror the first-attempt archive-failure routing (else ->
            # blocked/archive_failed, honoring PM_ON_BLOCK) instead of falling
            # through and being misclassified as `failed`.
            pg_push blocked "$id"; pg_meta_set "$id" archive_failed "archive failed on retry" "${PM_LAST_COST:-0}"
            [ "$PM_ON_BLOCK" = "stop" ] && PM_HALT=1; echo blocked; return 0
          fi
        elif [ "$verdict" = "block" ]; then
          pg_push blocked "$id"; pg_meta_set "$id" needs_human "blocked on retry" "${PM_LAST_COST:-0}"
          [ "$PM_ON_BLOCK" = "stop" ] && PM_HALT=1; echo blocked; return 0
        fi
        pg_meta_set "$id" failed "run failed (attempt $((tries+1)))" "${PM_LAST_COST:-0}"
      done
      pg_push failed "$id"
      [ "$PM_ON_FAIL" = "stop" ] && PM_HALT=1
      echo failed; return 0 ;;
  esac
}

budget_exceeded() {
  local f; f="$(pg_file)"
  if [ -n "${PM_COST_CAP_USD:-}" ]; then
    jq -e --argjson cap "$PM_COST_CAP_USD" '.budget.spent_usd >= $cap' "$f" >/dev/null 2>&1 && return 0
  fi
  if [ -n "${PM_TIME_CAP_MIN:-}" ]; then
    jq -e --argjson cap "$PM_TIME_CAP_MIN" '.budget.elapsed_min >= $cap' "$f" >/dev/null 2>&1 && return 0
  fi
  return 1
}

summary() {
  local f; f="$(pg_file)"
  jq -r '"pm-runner summary: done=\(.done|length) blocked=\(.blocked|length) failed=\(.failed|length) spent_usd=\(.budget.spent_usd)"' "$f"
}

: "${PM_COMPACT_EVERY:=0}"
maybe_compact() {
  local done_count="$1"
  [ "${PM_COMPACT_EVERY:-0}" -gt 0 ] || return 0
  [ "$((done_count % PM_COMPACT_EVERY))" -eq 0 ] || return 0
  # Bounded re-prioritization: input is the compact rollup only (counts), never full history (I-1).
  echo "COMPACT: re-prioritize after $done_count done (rollup-only input)"
}

main() {
  preflight || exit 1
  pg_init
  local id done_count=0
  while :; do
    pg_elapsed_update
    if budget_exceeded; then echo "pm-runner: budget cap reached, stopping"; break; fi
    id="$(next_change)"; [ -n "$id" ] || break
    handle_change "$id" >/dev/null
    done_count="$(pg_bucket done | grep -c . || true)"
    maybe_compact "$done_count"
    [ "${PM_HALT:-0}" = "1" ] && { echo "pm-runner: halting (policy)"; break; }
  done
  summary
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
