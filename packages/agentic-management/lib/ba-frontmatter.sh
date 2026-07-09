# shellcheck shell=bash
# Emits OpenSpec change frontmatter parseable by Plan 02's fm_priority/fm_depends.
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
