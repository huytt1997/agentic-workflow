#!/usr/bin/env bash
# install.sh — install agentic-workflow packages into a --target config/project dir.
# Usage: install.sh --target <dir> [--package core|engineer|management|all] [--mode copy|symlink]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/install-common.sh"

ic_parse_common "$@" || exit 2
cfg="$(ic_resolve_target "$IC_TARGET")" || { echo "bad --target" >&2; exit 2; }
sel="$IC_PACKAGE"; [ -n "$sel" ] || sel="$(ic_menu)" || exit 2
pkgs="$(ic_expand_selection "$sel")" || { echo "unknown package: $sel" >&2; exit 2; }

while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ "$p" != "agentic-core" ] && ! ic_manifest_installed "$cfg" agentic-core; then
    echo "error: $p depends on agentic-core — install agentic-core first" >&2
    exit 1
  fi
  ic_install_package "$p" "$cfg" "$IC_MODE" || { echo "install failed: $p" >&2; exit 1; }
  [ "$p" = "agentic-core" ] && ic_hooks_merge "$cfg"
  if [ -d "$cfg/agentic/$p/bin" ]; then
    echo "Add to PATH: export PATH=\"$cfg/agentic/$p/bin:\$PATH\""
  fi
  echo "installed $p -> $cfg/agentic/$p (mode=$IC_MODE)"
done <<< "$pkgs"
