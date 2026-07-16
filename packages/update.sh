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
pkgs="$(ic_with_deps $pkgs)" || { echo "unknown package: $sel" >&2; exit 2; }

# The explicitly-selected packages must already be installed; dependencies pulled
# in by the resolver may not be, and are installed to reach a consistent state.
selected="$(ic_expand_selection "$sel")"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! ic_manifest_installed "$cfg" "$p"; then
    case "
$selected" in
      *"
$p"*) echo "error: $p is not installed at $cfg — run install.sh first" >&2; exit 1 ;;
      *)    echo "installing missing dependency $p" ;;
    esac
  fi
  ic_install_package "$p" "$cfg" || { echo "update failed: $p" >&2; exit 1; }
  [ "$p" = "agentic-core" ] && ic_hooks_merge "$cfg"
  echo "updated $p at $cfg/agentic/$p"
done <<< "$pkgs"
