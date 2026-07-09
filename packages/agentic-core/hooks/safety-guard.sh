#!/usr/bin/env bash
# safety-guard.sh — PreToolUse hook (D-9/I-2).
#
# Reads a Claude Code PreToolUse JSON event on stdin:
#   {"tool_name":"Bash","tool_input":{"command":"..."}}
#   {"tool_name":"Edit"|"Write","tool_input":{"file_path":"..."}}
# Denies a catalog of destructive operations fail-closed (exit 2); allows
# everything else, including on any parse failure (fail-open, exit 0) so a
# malformed event can never brick a session.
#
# Currently implemented deny families (T-C9):
#   - safety-fs-destructive: rm -rf on root/home/system paths, recursive
#     delete of root/home, fork bomb, mkfs.*, dd of=/dev/..., redirects to a
#     block device
#   - safety-rce-pipe (D-10): curl|wget piped into a shell (RCE / prompt
#     injection), git push --force/--force-with-lease/--delete, chmod 777
#     (or similarly permissive) on root-ish paths
#   - safety-secrets: writes (Edit/Write file_path, or Bash `>`/`>>`
#     redirects) targeting credential/system paths — `.git/`, `.ssh/`,
#     `.aws/`, `.gnupg/`, `/etc/`, and `.env` files. Matched on whole path
#     components (not substrings), so `.env.example` / `src/environment.js`
#     stay allowed.
#   - safety-confinement (I-6): Edit/Write file_path and Bash redirect targets
#     must resolve inside the active worktree ($WORKTREE_PATH, else the
#     product's `agentic-state get worktree_path`), except a target whose
#     resolved path has an `openspec/` path component anywhere — the durable
#     OpenSpec-artifact exception. If no worktree is known at all, confinement
#     is skipped (fail-open: that's a different concern than "is this
#     destructive", don't deny by default with nothing to confine against).
#   - safety-fail-open (D-9, T-C10): malformed/non-JSON stdin, empty stdin, a
#     missing `jq` binary, or valid-JSON-but-wrong-shape input all fail open
#     (exit 0) — this hook must never crash or hang a session. On a genuine
#     deny, a structured `hookSpecificOutput.permissionDecision:"deny"` object
#     (with a human-readable reason) is printed to stdout before `exit 2`, for
#     clearer surfacing than a raw exit code alone.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

EVENT="$(cat)"
echo "$EVENT" | jq -e . >/dev/null 2>&1 || exit 0

TOOL_NAME="$(echo "$EVENT" | jq -r '.tool_name // empty' 2>/dev/null)"
COMMAND="$(echo "$EVENT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
FILE_PATH="$(echo "$EVENT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"

deny() {
  local reason="$1"
  echo "safety-guard: denied — $reason" >&2
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg reason "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
      "$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
  exit 2
}

# Whole-path-component match for credential/dotfile/system targets (feature:
# safety-secrets). Deliberately anchored on full components (`(^|/)name(/|$)`)
# rather than a bare substring, so `.env.example` and `src/environment.js`
# are not mistaken for `.env` writes.
is_secret_path() {
  echo "$1" | grep -Eq \
    '(^|/)\.git(/|$)|(^|/)\.ssh(/|$)|(^|/)\.aws(/|$)|(^|/)\.gnupg(/|$)|^/etc(/|$)|(^|/)\.env$'
}

# --- worktree confinement (feature: safety-confinement, I-6) ---

# normalize_path <path> — resolve <path> to an absolute, "."/".."-collapsed
# form WITHOUT requiring it to exist (portable fallback for realpath -m,
# which is a GNU-only flag: BSD/macOS realpath has no -m and errors on a
# nonexistent path, and this hook must stay dependency-light).
normalize_path() {
  local p="$1"
  case "$p" in
    /*) ;;
    *) p="$(pwd)/$p" ;;
  esac
  local part
  local -a comps out
  local IFS='/'
  read -ra comps <<< "$p"
  for part in "${comps[@]}"; do
    case "$part" in
      ''|'.') continue ;;
      '..')
        if [ "${#out[@]}" -gt 0 ]; then
          unset "out[$((${#out[@]}-1))]"
        fi
        ;;
      *) out+=("$part") ;;
    esac
  done
  local result=""
  for part in "${out[@]:-}"; do
    [ -n "$part" ] && result="$result/$part"
  done
  printf '%s' "${result:-/}"
}

# resolve_abs <path> — GNU `realpath -m` if it behaves that way here, else
# fall back to normalize_path (handles a not-yet-created file/dir either way).
resolve_abs() {
  local p="$1" out
  out="$(realpath -m "$p" 2>/dev/null)"
  if [ -n "$out" ]; then
    printf '%s' "$out"
  else
    normalize_path "$p"
  fi
}

# resolve_worktree — $WORKTREE_PATH env first, else the product's own
# `agentic-state get worktree_path` (packages/agentic-core/lib/state.sh,
# NOT the harness's own bookkeeping state.sh). Prints the raw worktree path
# and returns 0 if one is known; returns 1 (nothing printed) otherwise.
resolve_worktree() {
  local wt="${WORKTREE_PATH:-}"
  if [ -z "$wt" ]; then
    local script_dir state_sh
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    state_sh="$script_dir/../lib/state.sh"
    if [ -n "$script_dir" ] && [ -f "$state_sh" ]; then
      wt="$(bash "$state_sh" get worktree_path 2>/dev/null)"
    fi
  fi
  if [ -z "$wt" ] || [ "$wt" = "null" ]; then
    return 1
  fi
  printf '%s' "$wt"
}

# is_openspec_path <resolved-path> — the I-6 exception: durable OpenSpec
# artifacts are allowed to write outside the confined worktree. Matched as a
# whole path component anywhere in the resolved path (target-project-root
# openspec/, a worktree-nested openspec/, etc. all qualify).
is_openspec_path() {
  echo "$1" | grep -Eq '(^|/)openspec(/|$)'
}

# check_confinement <path> — deny (exit 2) if <path> resolves outside the
# active worktree and isn't an openspec/ exception. No-ops (allow) if <path>
# is empty or no worktree is known at all (confinement is a different concern
# than "is this destructive"; don't deny by default with nothing to confine
# against).
check_confinement() {
  local target="$1"
  [ -n "$target" ] || return 0
  local wt
  wt="$(resolve_worktree)" || return 0
  local resolved_wt resolved_target
  resolved_wt="$(resolve_abs "$wt")"
  resolved_target="$(resolve_abs "$target")"
  case "$resolved_target" in
    "$resolved_wt"|"$resolved_wt"/*) return 0 ;;
  esac
  if is_openspec_path "$resolved_target"; then
    return 0
  fi
  deny "write outside worktree confinement: $target (resolved=$resolved_target, worktree=$resolved_wt)"
}

if [ "$TOOL_NAME" = "Bash" ] && [ -n "$COMMAND" ]; then
  # rm -rf (or -fr / -Rf / etc.) on root, home, or a glob directly under root/home.
  if echo "$COMMAND" | grep -Eq 'rm[[:space:]]+(-[A-Za-z]*[rRfF][A-Za-z]*[[:space:]]+)+(/|~)([[:space:]]|/?\*?[[:space:]]*$)'; then
    deny "destructive rm -rf on root/home: $COMMAND"
  fi
  # fork bomb
  if echo "$COMMAND" | grep -Eq ':\(\)[[:space:]]*\{[[:space:]]*:\|:&[[:space:]]*\};:'; then
    deny "fork bomb: $COMMAND"
  fi
  # mkfs.*
  if echo "$COMMAND" | grep -Eq '(^|[;&|[:space:]])mkfs(\.[A-Za-z0-9]+)?([[:space:]]|$)'; then
    deny "filesystem format (mkfs): $COMMAND"
  fi
  # dd of=/dev/... (raw block device overwrite)
  if echo "$COMMAND" | grep -Eq '(^|[;&|[:space:]])dd([[:space:]].*)?[[:space:]]of=/dev/'; then
    deny "raw block-device overwrite (dd of=/dev/...): $COMMAND"
  fi
  # redirect to a block device, e.g. echo x > /dev/sda
  if echo "$COMMAND" | grep -Eq '>{1,2}[[:space:]]*/dev/(sd|hd|nvme|xvd|disk)[A-Za-z0-9]*([[:space:]]|$)'; then
    deny "redirect to block device: $COMMAND"
  fi
  # curl|wget piped into a shell interpreter (RCE / prompt-injection, D-10).
  if echo "$COMMAND" | grep -Eq '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh)([[:space:]]|$)'; then
    deny "pipe-to-shell RCE: $COMMAND"
  fi
  # git push --force / --force-with-lease / --delete (D-10).
  if echo "$COMMAND" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]]+[^;&|]*)?[[:space:]]+--(force(-with-lease)?|delete)([[:space:]=]|$)'; then
    deny "git push --force/--delete: $COMMAND"
  fi
  # chmod 777 (or equally permissive) on root-ish paths.
  if echo "$COMMAND" | grep -Eq '(^|[;&|[:space:]])chmod[[:space:]]+(-R[[:space:]]+)?(777|a\+rwx|ugo\+rwx)[[:space:]]+(/|~)([[:space:]]|$)'; then
    deny "chmod 777 on root-ish path: $COMMAND"
  fi
  # Redirect (>/>>) into a credential/dotfile/system path (safety-secrets).
  REDIRECT_TARGET="$(echo "$COMMAND" | grep -oE '>{1,2}[[:space:]]*[^[:space:]]+' | tail -1 | \
    sed -E "s/^>{1,2}[[:space:]]*//; s/^['\"]//; s/['\"]\$//")"
  if [ -n "$REDIRECT_TARGET" ] && is_secret_path "$REDIRECT_TARGET"; then
    deny "redirect into credential/system path: $COMMAND"
  fi
  # Worktree confinement (I-6) applies to redirect targets too.
  if [ -n "$REDIRECT_TARGET" ]; then
    check_confinement "$REDIRECT_TARGET"
  fi
fi

if { [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; } && [ -n "$FILE_PATH" ]; then
  if is_secret_path "$FILE_PATH"; then
    deny "write to credential/system path: $FILE_PATH"
  fi
  check_confinement "$FILE_PATH"
fi

exit 0
