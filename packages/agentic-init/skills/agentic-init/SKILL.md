---
name: agentic-init
description: Bootstrap a target project for the agentic workflow - verify/install the OpenSpec CLI, run openspec init, and scaffold the docs/ folder that agentic-ba reads.
---

# agentic-init

Bootstrap SOP. Prepares a target project so `agentic-ba` has input to read and `agentic-pm` has an
`openspec/` tree to drive. Runs **in the target project**, not in the tooling repo.

**Announce at start:** "I'm using the agentic-init skill to bootstrap this project."

**This SOP is idempotent.** Every step below checks before it writes. Re-running on an
already-initialized project must change nothing and must never clobber `openspec/` or overwrite a
user's docs.

## Step 1 — ensure the OpenSpec CLI

```bash
command -v openspec >/dev/null 2>&1 || npm install -g @fission-ai/openspec@latest
openspec --version
```

If the install fails (no npm, no network, EACCES on a global prefix), **stop and surface the error** —
do not fake the rest of the bootstrap. The remaining steps depend on a working CLI.

## Step 2 — initialize OpenSpec

```bash
[ -d openspec ] || openspec init
```

Never re-run `openspec init` over an existing `openspec/` — it is the durable cross-feature source of
truth (I-11) and re-initializing risks destroying real history.

## Step 3 — scaffold the docs/ folder

`docs/**/*.md` is what `agentic-ba` reads to author OpenSpec changes. It is deliberately **separate**
from `openspec/specs/`, which is OpenSpec's own source of truth (I-11) — do not conflate them.

```bash
mkdir -p docs
```

Then, **only if `docs/example-feature.md` does not already exist**, write it:

```markdown
# Example: Export a report as CSV

> Delete this file once you have real specs. It exists to show the shape `agentic-ba` expects.

## Why

Users need report data in a spreadsheet to do their own analysis.

## What

A single "Export CSV" action on the report view that downloads the current report as a `.csv` file.

## Acceptance criteria

Each criterion must be **observable** — a user-visible behaviour or a checkable output. "Works
correctly" is not a criterion; `agentic-engineer`'s `qa` turns each of these into a real test.

- Given a report with rows, when the user clicks "Export CSV", then a `.csv` file downloads.
- The downloaded file's first line is a header row naming every visible column.
- The downloaded file has exactly one line per report row, plus the header.
- Given a report with zero rows, when the user clicks "Export CSV", then the file downloads with the
  header row and no data rows.
- Given an export that fails server-side, the user sees an error message and no file downloads.
```

## Step 4 — report

Print what was done and what was skipped (already present), then tell the operator the next step:
write real specs under `docs/`, then run the `agentic-ba` skill to turn them into OpenSpec changes.

## Constraints

- The target project's own `CLAUDE.md` / rules win over this plugin's defaults (I-10).
- `openspec/` is the durable, cross-feature source of truth; never invent a parallel store (I-11).
