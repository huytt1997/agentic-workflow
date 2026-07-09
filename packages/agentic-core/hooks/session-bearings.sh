#!/usr/bin/env bash
# session-bearings.sh - SessionStart hook: prints a bounded "getting up to speed"
# bearings block (I-10). Never errors out: a missing state file, missing profile.sh,
# or a repo with a very long history must all degrade gracefully, not crash the
# session. Reads here are deliberately bounded (I-1): git log is always capped at 5
# entries, never the full history.

_session_bearings_main() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  echo "== agentic bearings =="
  echo "cwd: $(pwd 2>/dev/null)"

  # Active profile (profile.sh is a later feature, T-C16; tolerate absence).
  local profile_script="$root/lib/profile.sh"
  if [ -x "$profile_script" ] || [ -f "$profile_script" ]; then
    local cfg_dir
    cfg_dir="$(bash "$profile_script" config-dir 2>/dev/null)"
    if [ -n "$cfg_dir" ]; then
      echo "profile: $cfg_dir"
    else
      echo "profile: unknown"
    fi
  else
    echo "profile: unknown (profile.sh not installed yet)"
  fi

  echo "reminder: the target project's own CLAUDE.md/rules win over plugin defaults (I-10)"

  # Bounded state summary via the PRODUCT state.sh (not the harness state.sh).
  local state_script="$root/lib/state.sh"
  if [ -f "$state_script" ]; then
    local phase tasks_remaining feature
    feature="$(bash "$state_script" get feature 2>/dev/null)"
    phase="$(bash "$state_script" get phase 2>/dev/null)"
    tasks_remaining="$(bash "$state_script" tasks-remaining 2>/dev/null)"
    if [ -n "$phase" ] && [ "$phase" != "null" ]; then
      echo "state: feature=${feature:-unknown} phase=${phase} tasks-remaining=${tasks_remaining:-0}"
    else
      echo "state: no .agentic/state.json yet"
    fi
  else
    echo "state: state.sh not found"
  fi

  # Bounded git log — never unbounded history (I-1).
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "git log (last 5, bounded):"
    git log -5 --oneline 2>/dev/null
  else
    echo "git log: not a git repo"
  fi

  return 0
}

_session_bearings_main
exit 0
