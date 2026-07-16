# shellcheck shell=bash
# agentic-core frontmatter contract — the single BA<->PM seam.
#
# The BA (agentic-ba) EMITS this block at the top of an OpenSpec change
# proposal.md via ba_frontmatter; the PM selector (agentic-pm) CONSUMES it via
# fm_priority/fm_depends. Both packages depend on agentic-core, so the emitter
# and the parser live here together: one contract, one home, no drift.

fm_block() { awk 'NR==1&&/^---[[:space:]]*$/{f=1;next} f&&/^---[[:space:]]*$/{exit} f{print}' "$1"; }

fm_priority() {
  local p
  p="$(fm_block "$1" | sed -n 's/^priority:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  printf '%s' "${p:-100}"
}

fm_depends() {
  local raw
  raw="$(fm_block "$1" | sed -n 's/^depends_on:[[:space:]]*\[\(.*\)\].*/\1/p' | head -1)"
  [ -n "$raw" ] || { printf ''; return 0; }
  printf '%s' "$raw" | tr ',' ' ' | tr -d "[]\"'" | xargs 2>/dev/null
}

# Emits frontmatter parseable by fm_priority/fm_depends above.
ba_frontmatter() {
  local prio="$1"; shift
  echo "---"
  if [ "$#" -gt 0 ]; then
    local joined; joined="$(printf '%s, ' "$@")"; joined="${joined%, }"
    echo "depends_on: [$joined]"
  fi
  echo "priority: $prio"
  echo "---"
}
