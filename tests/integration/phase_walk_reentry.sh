#!/usr/bin/env bash
# tests/integration/phase_walk_reentry.sh — deterministic simulated P4->P2
# re-entry cycle (feature: phasewalk-reentry, plan 07). Extends the
# phasewalk-green happy path: drives the REAL shipped kernel binaries
# (state.sh / checkpoint.sh / verify-gate.sh) all the way to a genuinely
# green P4, then proves the full integration-level re-entry story that
# plan 04's `gate-reentry` only proved at the unit level:
#   P4 green -> reviewer requests changes -> `state.sh reopen P2` -> the gate
#   re-blocks P3 and P4 on the nulled downstream checks -> only a fresh
#   large+review pass lets P4 terminate again. No LLM involved.
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

gate(){
  printf '{"session_id":"phasewalk-reentry","hook_event_name":"Stop","stop_hook_active":false}' \
    | bash "$GATE" >/tmp/pwr_gate.out 2>&1
  echo $?
}

npm install --no-audit --no-fund >/tmp/pwr_npm_install.out 2>&1

# ================= P0 -> P4: reach a genuinely green review (real kernel) =================
bash "$S" init demo --mode auto --change c-1
bash "$S" phase P0
bash "$S" set worktree_path "\"$G\""
assert_exit 0 "$(gate)" "P0 allows once worktree_path recorded"

bash "$S" phase P1
bash "$S" set 'verify_cmds.fast' '"npm run lint && npm run typecheck"'
bash "$S" set 'verify_cmds.large' '"npm run lint && npm run typecheck && npm test"'
bash "$S" task-add t1 "implement feature"
assert_exit 0 "$(gate)" "P1 allows once verify_cmds + tasks recorded"

bash "$S" phase P2
bash "$S" task-set t1 verified
fast_cmd="$(bash "$S" get 'verify_cmds.fast')"
if bash -c "$fast_cmd" >/tmp/pwr_fast.out 2>&1; then
  bash "$S" check-set fast pass
else
  bash "$S" check-set fast fail
fi
assert_eq "pass" "$(bash "$S" get 'checks.fast')" "real fast verify_cmd passed"
assert_exit 0 "$(gate)" "P2 allows once tasks verified + fast green"
bash "$C" checkpoint P2 t1 --green >/dev/null

bash "$S" phase P3
large_cmd="$(bash "$S" get 'verify_cmds.large')"
if bash -c "$large_cmd" >/tmp/pwr_large.out 2>&1; then
  bash "$S" check-set large pass
else
  bash "$S" check-set large fail
fi
assert_eq "pass" "$(bash "$S" get 'checks.large')" "real large verify_cmd passed"
assert_exit 0 "$(gate)" "P3 allows on real large check green"
bash "$C" checkpoint P3 large --green >/dev/null

bash "$S" phase P4
bash "$S" check-set review pass
assert_exit 0 "$(gate)" "P4 allows on review pass (first pass, genuinely green)"
bash "$C" checkpoint P4 review --green >/dev/null

# ================= P4 -> P2 re-entry: reviewer requests changes =================
bash "$S" set 'checks.review' '"changes_requested"'
bash "$S" reopen P2
assert_eq "P2" "$(bash "$S" get phase)" "reopen P2 sets phase back to P2"
assert_eq "null" "$(bash "$S" get 'checks.large')" "reopen P2 nulls checks.large (downstream)"
assert_eq "null" "$(bash "$S" get 'checks.review')" "reopen P2 nulls checks.review (downstream)"

# A stale/skipped re-verification must NOT slip through anywhere in the cycle.
# The P2/P3/P4 checkpoints already committed since `fast` was stamped (each
# `checkpoint.sh` commits the state file itself), so HEAD has moved past
# `checks.fast_at` too (T-C6 SHA staleness) -- fast reads effective-null even
# though `reopen P2` only explicitly nulled large/review. So P2 re-blocks and
# ALL THREE checks (fast, large, review) must be genuinely re-earned; none of
# the previous pass's green survives the cycle.
assert_exit 2 "$(gate)" "re-entry: P2 re-blocks (fast gone stale via HEAD advance from later checkpoints)"
assert_contains "$(cat /tmp/pwr_gate.out)" "P2" "re-entry P2 block reason names P2"

# re-earn fast for real.
if bash -c "$fast_cmd" >/tmp/pwr_fast2.out 2>&1; then
  bash "$S" check-set fast pass
else
  bash "$S" check-set fast fail
fi
assert_eq "pass" "$(bash "$S" get 'checks.fast')" "fast re-earned for real on re-entry"
assert_exit 0 "$(gate)" "re-entry: P2 allows once fast is genuinely re-earned"

# a stale/skipped re-verification must NOT slip through: moving straight to P3
# without redoing the large check must re-block, because reopen nulled it.
bash "$S" phase P3
assert_exit 2 "$(gate)" "re-entry: P3 re-blocks (large nulled by reopen, no stale pass slips through)"
assert_contains "$(cat /tmp/pwr_gate.out)" "P3" "re-entry P3 block reason names P3"

# re-earn large for real (fixes still applied against the same fixture code,
# so the real command still passes) and advance to P4.
if bash -c "$large_cmd" >/tmp/pwr_large2.out 2>&1; then
  bash "$S" check-set large pass
else
  bash "$S" check-set large fail
fi
assert_eq "pass" "$(bash "$S" get 'checks.large')" "large re-earned for real on re-entry"
assert_exit 0 "$(gate)" "re-entry: P3 allows once large is genuinely re-earned"

bash "$S" phase P4
assert_exit 2 "$(gate)" "re-entry: P4 re-blocks (review nulled by reopen, no stale pass slips through)"
assert_contains "$(cat /tmp/pwr_gate.out)" "P4" "re-entry P4 block reason names P4"

# only a fresh review pass (a genuine second review, post re-entry) lets P4
# terminate again -- this is the "only a fresh full cycle" acceptance bar.
bash "$S" check-set review pass
assert_exit 0 "$(gate)" "re-entry terminates only on fresh fast+large+review, not the stale first-pass green"
bash "$C" checkpoint P4 review-2 --green >/dev/null

# ================= P5 cleanup, same as the happy path =================
bash "$S" phase P5
assert_exit 2 "$(gate)" "P5 (auto) blocks: worktree still present, cleanup not done"
cd "$ROOT"
rm -rf "$G"
assert_exit 0 "$(gate)" "P5 allows once the worktree (and its ephemeral state) is removed"

assert_summary
