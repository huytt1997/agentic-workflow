# shellcheck shell=bash
# Derives a stable, idempotent kebab-case OpenSpec change id from a doc-section title.
ba_changeid() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'
}
