#!/usr/bin/env bash
# emit-event.sh - PostToolUse hook: fire-and-forget NDJSON event log (D-11, I-8).
# Reads the PostToolUse JSON event from stdin, appends one NDJSON line to
# $AGENTIC_HOME/events.ndjson (default ~/.agentic), optionally POSTs it to
# $AGENTIC_SSE_URL in the background if set. Always exits 0: a missing jq, a
# malformed payload, or an unreachable SSE endpoint must never block the agent.

_emit_main() {
  local home="${AGENTIC_HOME:-$HOME/.agentic}"
  local input
  input="$(cat 2>/dev/null)"

  local tool="" event="" session=""
  if command -v jq >/dev/null 2>&1 && [ -n "$input" ] && printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
    tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
    event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)"
    session="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
  fi
  [ -n "$event" ] || event="${CLAUDE_HOOK_EVENT:-PostToolUse}"
  [ -n "$session" ] || session="${CLAUDE_SESSION_ID:-}"

  mkdir -p "$home" 2>/dev/null || return 0

  local ts
  ts="$(date -u +%FT%TZ 2>/dev/null)"

  local line
  line="$(jq -nc --arg ts "$ts" --arg tool "$tool" --arg event "$event" --arg session "$session" \
    '{ts:$ts, tool:$tool, event:$event, session:$session}' 2>/dev/null)"
  [ -n "$line" ] || return 0

  printf '%s\n' "$line" >> "$home/events.ndjson" 2>/dev/null

  if [ -n "${AGENTIC_SSE_URL:-}" ] && command -v curl >/dev/null 2>&1; then
    ( curl -m 1 -s -X POST -H 'Content-Type: application/json' -d "$line" "$AGENTIC_SSE_URL" >/dev/null 2>&1 & ) 2>/dev/null
  fi
  return 0
}

_emit_main
exit 0
