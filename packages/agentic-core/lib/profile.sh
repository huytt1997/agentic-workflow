#!/usr/bin/env bash
# profile.sh — minimal active-profile detection (T-C16, kept minimal per scope-trim).
#
# Reports the active Claude config dir: honors direnv-provided $CLAUDE_CONFIG_DIR
# (see .envrc / dev-workflow.md "Profiles"), else defaults to ~/.claude.
#
# Usage: profile.sh config-dir
set -uo pipefail

cmd="${1:-config-dir}"

case "$cmd" in
  config-dir)
    echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    ;;
  *)
    echo "usage: profile.sh config-dir" >&2
    exit 1
    ;;
esac
