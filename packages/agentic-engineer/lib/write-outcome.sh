#!/usr/bin/env bash
# write-outcome.sh — writes the engineer -> PM outcome contract file
# (openspec/.pm/outcomes/<change_id>.json, schema pm-outcome/1) at P5 auto,
# before worktree cleanup (I-6's OpenSpec exception, T-E8).
#
# Usage: write-outcome.sh <target-dir> <change_id> <status> <checkpoints> <tests_written> [reason] [pr]
#   status         success|needs_human|failed
#   checkpoints    integer count of checkpoints taken during the run
#   tests_written  integer count of tests qa wrote
#   reason         optional blocking/failure reason (default: null)
#   pr             optional PR URL or branch name (default: null)
#
# verification.large_passed is DERIVED from status, never taken as a separate
# argument: it is true iff status == success. This makes a self-contradictory
# record (status=success but LARGE not actually green) structurally
# unwritable through this script's interface.
set -uo pipefail

usage() {
  echo "usage: $(basename "$0") <target-dir> <change_id> <status> <checkpoints> <tests_written> [reason] [pr]" >&2
}

target="${1:-}"; change_id="${2:-}"; status="${3:-}"; checkpoints="${4:-}"; tests_written="${5:-}"
reason="${6:-}"; pr="${7:-}"

if [ -z "$target" ] || [ -z "$change_id" ] || [ -z "$status" ] || [ -z "$checkpoints" ] || [ -z "$tests_written" ]; then
  usage
  exit 2
fi

case "$status" in
  success|needs_human|failed) ;;
  *)
    echo "write-outcome: unknown status '$status' (want success|needs_human|failed) — refusing to write a record" >&2
    exit 1
    ;;
esac

case "$checkpoints" in
  ''|*[!0-9]*) echo "write-outcome: checkpoints must be a non-negative integer, got '$checkpoints'" >&2; exit 1 ;;
esac
case "$tests_written" in
  ''|*[!0-9]*) echo "write-outcome: tests_written must be a non-negative integer, got '$tests_written'" >&2; exit 1 ;;
esac

# large_passed is derived, never independently settable — a success record
# always implies LARGE (incl. qa's tests) actually passed (verify-gate would
# not have let the run reach P5 otherwise).
if [ "$status" = "success" ]; then
  large_passed=true
else
  large_passed=false
fi

reason_json="null"
[ -n "$reason" ] && reason_json="$(jq -n --arg r "$reason" '$r')"
pr_json="null"
[ -n "$pr" ] && pr_json="$(jq -n --arg p "$pr" '$p')"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

out_dir="$target/openspec/.pm/outcomes"
mkdir -p "$out_dir" || exit 1
out_file="$out_dir/$change_id.json"
tmp_file="$out_file.tmp.$$"

jq -n \
  --arg schema "pm-outcome/1" \
  --arg change_id "$change_id" \
  --arg status "$status" \
  --argjson reason "$reason_json" \
  --argjson checkpoints "$checkpoints" \
  --argjson pr "$pr_json" \
  --arg ts "$ts" \
  --argjson large_passed "$large_passed" \
  --argjson tests_written "$tests_written" \
  '{
    schema: $schema,
    change_id: $change_id,
    status: $status,
    reason: $reason,
    checkpoints: $checkpoints,
    pr: $pr,
    ts: $ts,
    verification: {
      large_passed: $large_passed,
      tests_written: $tests_written,
      levels: ["component", "integration", "e2e"]
    }
  }' > "$tmp_file" || { rm -f "$tmp_file"; exit 1; }

mv "$tmp_file" "$out_file"
