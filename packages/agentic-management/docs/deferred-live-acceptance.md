# Deferred: live acceptance

`agentic-management` is **built and fixture-verified**, not yet proven against live tooling. Two things
are deliberately deferred (see .agentic/plans/00-overview.md decisions D-A/D-B):

1. **Real `openspec` CLI.** All tests use a stub `openspec` under `tests/fixtures/bin/`. Before claiming
   live readiness, install `openspec`, confirm `validate <id> --strict` / `archive <id> --yes` flags
   against the installed version, and re-run the fixture flows against the real binary.
2. **Real `claude -p` engineer.** All tests use a stub engineer (fake `claude`) that writes a canned
   `pm-outcome/1` file. The full autonomous definition-of-done (spec §8 steps 2–8: BA → PM → real
   engineer → archive over a multi-change backlog, block/fail/budget paths) requires a real engineer
   proven end-to-end on a real repo first (roadmap hard gate) and is a follow-up.

INT-2 (live env passthrough of `AGENTIC_PROJECT_ROOT` / `AGENTIC_PM_OUTCOME_FILE` from a real engineer
run) is validated as part of that live follow-up.

Gap noted separately: repo-root `bin/install.sh` (D-13/WS-E) does not exist; installing this plugin for
real depends on that being built.

Known implementation gap (not a live-acceptance deferral): `PM_BA_SYNC` / `PM_DOCS_GLOB` are documented as
`pm-runner.sh` env knobs (00-overview.md §2.5, the `agentic-pm` skill) but no `maybe_ba_sync` wiring exists
in `bin/pm-runner.sh` yet — setting `PM_BA_SYNC=1` is currently a silent no-op. Default is `0` (off), so
the loop's default behavior is unaffected; wiring `maybe_ba_sync` into `main()` is a follow-up.
