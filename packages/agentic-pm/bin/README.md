# pm-runner.sh — bounded-read discipline (I-1)

Per-iteration reads are bounded and independent of how many changes have completed:

- `progress.json`: only bucket arrays (`done/failed/blocked`) + the per-change `meta.<id>` slice.
- Change listing: `os_list_active` lists `openspec/changes/*` and **excludes** `archive/`.
- Compaction: `maybe_compact` operates over the rollup (counts) only — never full history.

Deferred: live acceptance against the real `openspec` CLI and real `claude -p` engineer runs
(see .agentic/plans/00-overview.md decisions D-A/D-B). All tests here use the stub `openspec`
and stub engineer under `tests/fixtures/bin/`.
