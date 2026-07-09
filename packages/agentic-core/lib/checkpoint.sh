#!/usr/bin/env bash
# agentic-core checkpoint.sh — git checkpoints + state.checkpoints bookkeeping (D-12).
# Usage: checkpoint.sh <command> [args...]
#   checkpoint <phase> <label> [--green]   stage tracked changes, commit with subject
#                                           "[agentic:ckpt] <phase>/<label>", record it
#                                           in state.checkpoints via state.sh checkpoints-add
#   list                                   one line per checkpoint: "<sha> <phase>/<label> [green]"
#   last                                   sha of the most recently recorded checkpoint
#   last-green                             sha of the newest checkpoint with green:true
#   revert-last-green                      the ONLY rollback (I-5): git reset --hard to the
#                                           sha returned by `last-green`, leaving the tree clean
#
# $AGENTIC_STATE (via state.sh) overrides the state file location.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_SH="$LIB_DIR/state.sh"

_has_jq() { command -v jq >/dev/null 2>&1; }

cmd_checkpoint() {
  local phase="$1" label="$2"; shift 2
  local green="false"
  while [ $# -gt 0 ]; do
    case "$1" in
      --green) green="true"; shift ;;
      *) shift ;;
    esac
  done
  git add -A
  git commit -q -m "[agentic:ckpt] ${phase}/${label}"
  local sha
  sha="$(git rev-parse HEAD)"
  bash "$STATE_SH" checkpoints-add "$phase" "$label" "$sha" "$green"
  echo "$sha"
}

cmd_list() {
  _has_jq || { exit 0; }
  bash "$STATE_SH" get 'checkpoints[] | .sha + " " + .phase + "/" + .label + (if .green then " green" else "" end)' 2>/dev/null
}

cmd_last() {
  _has_jq || { echo ""; exit 0; }
  bash "$STATE_SH" get 'checkpoints[-1].sha // ""' 2>/dev/null
}

cmd_last_green() {
  _has_jq || { echo ""; exit 0; }
  bash "$STATE_SH" get 'checkpoints | [.[] | select(.green == true)] | last | .sha // ""' 2>/dev/null
}

cmd_revert_last_green() {
  local sha
  sha="$(cmd_last_green)"
  if [ -z "$sha" ]; then
    echo "checkpoint.sh: no green checkpoint recorded, cannot revert" >&2
    exit 1
  fi
  git reset --hard "$sha" >/dev/null
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    checkpoint) cmd_checkpoint "$@" ;;
    list) cmd_list "$@" ;;
    last) cmd_last "$@" ;;
    last-green) cmd_last_green "$@" ;;
    revert-last-green) cmd_revert_last_green "$@" ;;
    *) echo "usage: checkpoint.sh {checkpoint|list|last|last-green|revert-last-green} ..." >&2; exit 1 ;;
  esac
}

main "$@"
