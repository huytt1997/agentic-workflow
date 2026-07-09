# shellcheck shell=bash
# Parses the YAML frontmatter block at the top of an OpenSpec change proposal.md.
# The BA (Plan 03) emits this block; the PM selector consumes it. One parser, one seam.
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
