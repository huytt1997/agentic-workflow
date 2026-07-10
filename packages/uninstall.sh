#!/usr/bin/env bash
# uninstall.sh — remove agentic-workflow packages from --target, preserving user data.
# Usage: uninstall.sh --target <dir> [--package core|engineer|management|all]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/install-common.sh"

ic_parse_common "$@" || exit 2
cfg="$(ic_resolve_target "$IC_TARGET")" || { echo "bad --target" >&2; exit 2; }
sel="$IC_PACKAGE"; [ -n "$sel" ] || sel="$(ic_menu)" || exit 2
pkgs="$(ic_expand_selection "$sel")" || { echo "unknown package: $sel" >&2; exit 2; }
# uninstall in reverse dependency order (core last)
pkgs="$(printf '%s\n' "$pkgs" | sed '1!G;h;$!d')"

while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! ic_manifest_installed "$cfg" "$p"; then
    echo "skip: $p is not installed at $cfg"
    continue
  fi
  mf="$(ic_manifest_path "$cfg" "$p")"
  [ "$p" = "agentic-core" ] && ic_hooks_unmerge "$cfg"
  # remove discovery links recorded in the manifest
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    rm -f "$cfg/$rel"
  done < <(jq -r '.links[]? // empty' "$mf")
  rm -rf "$cfg/agentic/$p"
  rm -f "$mf"
  echo "uninstalled $p from $cfg"
done <<< "$pkgs"
