#!/usr/bin/env bash
# install.sh — install agentic-workflow packages into a --target config/project dir.
# Usage: install.sh --target <dir> [--package core|engineer|management|all]
# Installs are copy-only (D-13 as amended); --mode is retired.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/install-common.sh"

ic_parse_common "$@" || exit 2
cfg="$(ic_resolve_target "$IC_TARGET")" || { echo "bad --target" >&2; exit 2; }
sel="$IC_PACKAGE"; [ -n "$sel" ] || sel="$(ic_menu)" || exit 2
pkgs="$(ic_expand_selection "$sel")" || { echo "unknown package: $sel" >&2; exit 2; }
# resolve dependencies: selecting engineer/init/ba/pm pulls in what they need,
# in dependency order, so core is always placed (and its hooks merged) first.
pkgs="$(ic_with_deps $pkgs)" || { echo "unknown package: $sel" >&2; exit 2; }

while IFS= read -r p; do
  [ -n "$p" ] || continue
  ic_install_package "$p" "$cfg" || { echo "install failed: $p" >&2; exit 1; }
  [ "$p" = "agentic-core" ] && ic_hooks_merge "$cfg"
  if [ -d "$cfg/agentic/$p/bin" ]; then
    echo "Add to PATH: export PATH=\"$cfg/agentic/$p/bin:\$PATH\""
  fi
  echo "installed $p -> $cfg/agentic/$p"
done <<< "$pkgs"
