#!/usr/bin/env bash
# tests/integration/phase_walk.sh — deterministic simulated P0->P5 phase-walk
# (feature: phasewalk-green, plan 07). Drives the REAL shipped kernel binaries
# (state.sh / checkpoint.sh / verify-gate.sh) through a full happy-path walk
# in a throwaway git repo built from the tests/fixtures/npm-sample fixture, no
# LLM involved. FAST/LARGE verify_cmds are the fixture's real lint/typecheck/
# test scripts and are actually EXECUTED (I-7: verification is real) — the
# fast/large checks are only recorded pass/fail based on the real exit code.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; . "$ROOT/tests/lib/assert.sh"
S="$ROOT/packages/agentic-core/lib/state.sh"
GATE="$ROOT/packages/agentic-core/hooks/verify-gate.sh"
C="$ROOT/packages/agentic-core/lib/checkpoint.sh"

# --- build a fresh, hermetic throwaway repo from the npm fixture ---
G="$(mktemp -d)"
cp -R "$ROOT/tests/fixtures/npm-sample/." "$G/"
rm -rf "$G/node_modules" "$G/package-lock.json"
printf 'node_modules/\npackage-lock.json\n' > "$G/.gitignore"
cd "$G"
git init -q; git config user.email t@t; git config user.name t
git add -A; git commit -q -m base

export AGENTIC_STATE="$G/.agentic/state.json"

# gate() feeds a representative Stop-event payload on stdin (verify-gate.sh
# doesn't need to parse it, but a real Stop/SubagentStop hook always receives
# one — feed it anyway so the harness exercises the real invocation shape).
gate(){
  printf '{"session_id":"phasewalk","hook_event_name":"Stop","stop_hook_active":false}' \
    | bash "$GATE" >/tmp/pw_gate.out 2>&1
  echo $?
}

# real fixture build prerequisite (not a phase step, just environment setup
# for the real fast/large verify_cmds run below).
npm install --no-audit --no-fund >/tmp/pw_npm_install.out 2>&1

# ================= P0 =================
bash "$S" init demo --mode auto --change c-1
bash "$S" phase P0
assert_exit 2 "$(gate)" "P0 blocks before worktree_path recorded"
assert_contains "$(cat /tmp/pw_gate.out)" "P0" "P0 block reason names P0"
bash "$S" set worktree_path "\"$G\""
assert_exit 0 "$(gate)" "P0 allows once worktree_path recorded"
bash "$C" checkpoint P0 init --green >/dev/null

# ================= P1 =================
bash "$S" phase P1
assert_exit 2 "$(gate)" "P1 blocks before verify_cmds/tasks recorded"
assert_contains "$(cat /tmp/pw_gate.out)" "P1" "P1 block reason names P1"
bash "$S" set 'verify_cmds.fast' '"npm run lint && npm run typecheck"'
bash "$S" set 'verify_cmds.large' '"npm run lint && npm run typecheck && npm test"'
bash "$S" task-add t1 "implement feature"
assert_exit 0 "$(gate)" "P1 allows once verify_cmds + tasks recorded (auto mode)"
bash "$C" checkpoint P1 plan --green >/dev/null

# ================= P2 =================
bash "$S" phase P2
assert_exit 2 "$(gate)" "P2 blocks with task remaining"
bash "$S" task-set t1 verified
assert_exit 2 "$(gate)" "P2 still blocks: task verified but fast check not yet recorded"

fast_cmd="$(bash "$S" get 'verify_cmds.fast')"
if bash -c "$fast_cmd" >/tmp/pw_fast.out 2>&1; then
  bash "$S" check-set fast pass
else
  bash "$S" check-set fast fail
fi
assert_eq "pass" "$(bash "$S" get 'checks.fast')" "real fast verify_cmd (lint+typecheck) actually passed (I-7)"
assert_exit 0 "$(gate)" "P2 allows once tasks verified + real fast check green at current SHA"
bash "$C" checkpoint P2 t1 --green >/dev/null

# ================= P3 =================
bash "$S" phase P3
assert_exit 2 "$(gate)" "P3 blocks until large check recorded"
assert_contains "$(cat /tmp/pw_gate.out)" "P3" "P3 block reason names P3"

large_cmd="$(bash "$S" get 'verify_cmds.large')"
if bash -c "$large_cmd" >/tmp/pw_large.out 2>&1; then
  bash "$S" check-set large pass
else
  bash "$S" check-set large fail
fi
assert_eq "pass" "$(bash "$S" get 'checks.large')" "real large verify_cmd (lint+typecheck+test) actually passed (I-7)"
assert_exit 0 "$(gate)" "P3 allows on real large check green at current SHA"
bash "$C" checkpoint P3 large --green >/dev/null

# ================= P4 =================
bash "$S" phase P4
assert_exit 2 "$(gate)" "P4 blocks until review pass recorded"
assert_contains "$(cat /tmp/pw_gate.out)" "P4" "P4 block reason names P4"
bash "$S" check-set review pass
assert_exit 0 "$(gate)" "P4 allows on review pass"
bash "$C" checkpoint P4 review --green >/dev/null

# ================= P5 =================
bash "$S" phase P5
assert_exit 2 "$(gate)" "P5 (auto) blocks: worktree still present, cleanup not done"
assert_contains "$(cat /tmp/pw_gate.out)" "P5" "P5 block reason names P5"
# simulate real P5 cleanup: the whole worktree (incl. .agentic/, I-4) is
# removed; cd out first so the shell doesn't sit inside a deleted directory.
cd "$ROOT"
rm -rf "$G"
assert_exit 0 "$(gate)" "P5 allows once the worktree (and its ephemeral state) is removed"

assert_summary
