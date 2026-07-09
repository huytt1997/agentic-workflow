#!/usr/bin/env bash
# tests/integration/run-integration.sh — e2e entry point (.verify_cmd_e2e,
# 00-overview.md). Runs the deterministic simulated P0->P5 phase-walk
# scenario(s) against the real shipped kernel binaries. No LLM, no network
# beyond the fixture's own `npm install`. Never wired into the fast gate
# (tests/run-all.sh only picks up `*_test.sh`; this dir's scenario scripts are
# deliberately named without that suffix).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
bash "$ROOT/tests/integration/phase_walk.sh" || fail=1
bash "$ROOT/tests/integration/phase_walk_reentry.sh" || fail=1
bash "$ROOT/tests/integration/phase_walk_safety.sh" || fail=1
bash "$ROOT/tests/integration/phase_walk_rollback.sh" || fail=1
bash "$ROOT/tests/integration/phase_walk_events.sh" || fail=1
bash "$ROOT/tests/integration/checklist_test.sh" || fail=1
exit $fail
