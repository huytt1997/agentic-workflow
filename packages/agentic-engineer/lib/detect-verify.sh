#!/usr/bin/env bash
# detect-verify.sh <project-dir>
# Node-first verify auto-detect (T-E7). Reads <project-dir>/package.json .scripts
# and the lockfile present to pick a package manager, then prints a JSON object:
#   {"fast": "…|null", "component": "…|null", "large": "…|null"}
#
#   fast      = lint + typecheck, joined with " && " (whichever scripts exist)
#   component = first of test:component / test:unit / test (null if none exist)
#   large     = fast + component + integration (test:integration/integration)
#               + e2e (test:e2e/e2e), whichever exist, joined with " && "
#
# No package.json (non-Node project) -> {"fast":null,"component":null,"large":null}.
set -euo pipefail

DIR="${1:?usage: detect-verify.sh <project-dir>}"
PKG="$DIR/package.json"

if [ ! -f "$PKG" ]; then
  jq -n '{fast: null, component: null, large: null}'
  exit 0
fi

# --- package manager, from lockfile (pnpm > yarn > npm default) ---
if [ -f "$DIR/pnpm-lock.yaml" ]; then
  runner="pnpm run"
elif [ -f "$DIR/yarn.lock" ]; then
  runner="yarn run"
else
  runner="npm run"
fi

scripts_json="$(jq -c '.scripts // {}' "$PKG")"

has_script() {
  jq -e --arg s "$1" 'has($s)' >/dev/null 2>&1 <<<"$scripts_json"
}

cmd_for() {
  printf '%s %s' "$runner" "$1"
}

first_present() {
  # prints the first script name from the given candidates that exists, else empty
  for s in "$@"; do
    if has_script "$s"; then
      printf '%s' "$s"
      return 0
    fi
  done
  return 0
}

component_script="$(first_present test:component test:unit test)"
integration_script="$(first_present test:integration integration)"
e2e_script="$(first_present test:e2e e2e)"

fast_parts=()
has_script lint && fast_parts+=("$(cmd_for lint)")
has_script typecheck && fast_parts+=("$(cmd_for typecheck)")

join_parts() {
  # NOTE: don't use `local IFS=" && "; printf '%s' "$*"` — bash's "$*" only
  # honors the FIRST CHARACTER of IFS as separator, so that silently joins
  # with a single space instead of " && " (I-7 violation: downstream `bash -c`
  # would then only run the first command).
  local result="$1"
  shift
  for p in "$@"; do
    result="$result && $p"
  done
  printf '%s' "$result"
}

fast=""
[ "${#fast_parts[@]}" -gt 0 ] && fast="$(join_parts "${fast_parts[@]}")"

component=""
[ -n "$component_script" ] && component="$(cmd_for "$component_script")"

large_parts=("${fast_parts[@]}")
[ -n "$component_script" ] && large_parts+=("$(cmd_for "$component_script")")
[ -n "$integration_script" ] && large_parts+=("$(cmd_for "$integration_script")")
[ -n "$e2e_script" ] && large_parts+=("$(cmd_for "$e2e_script")")

large=""
[ "${#large_parts[@]}" -gt 0 ] && large="$(join_parts "${large_parts[@]}")"

jq -n --arg fast "$fast" --arg component "$component" --arg large "$large" '
  {
    fast: (($fast | select(length > 0)) // null),
    component: (($component | select(length > 0)) // null),
    large: (($large | select(length > 0)) // null)
  }
'
