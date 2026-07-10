#!/usr/bin/env bash
# update.sh — re-sync already-installed agentic-workflow packages at --target.
# Usage: update.sh --target <dir> [--package core|engineer|management|all]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/install-common.sh"

ic_parse_common "$@" || exit 2
cfg="$(ic_resolve_target "$IC_TARGET")" || { echo "bad --target" >&2; exit 2; }
sel="$IC_PACKAGE"; [ -n "$sel" ] || sel="$(ic_menu)" || exit 2
pkgs="$(ic_expand_selection "$sel")" || { echo "unknown package: $sel" >&2; exit 2; }

while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! ic_manifest_installed "$cfg" "$p"; then
    echo "error: $p is not installed at $cfg — run install.sh first" >&2
    exit 1
  fi
  mode="$(jq -r '.mode' "$(ic_manifest_path "$cfg" "$p")")"
  ic_install_package "$p" "$cfg" "$mode" || { echo "update failed: $p" >&2; exit 1; }
  [ "$p" = "agentic-core" ] && ic_hooks_merge "$cfg"
  echo "updated $p at $cfg/agentic/$p (mode=$mode)"
done <<< "$pkgs"
