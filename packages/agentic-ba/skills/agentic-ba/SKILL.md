---
name: agentic-ba
description: Sync a target project's docs/design into OpenSpec changes with testable acceptance criteria and depends_on/priority frontmatter.
---

# agentic-ba

Orchestrator SOP: read the target project's specs and produce/update OpenSpec changes. Dispatch the
`ba-analyst` subagent (pinned `opus`/`high`) for the heavy reading/writing.

## Where the source docs live

**Default source: `docs/**/*.md`** at the target project root — the folder `agentic-init` scaffolds.
An explicit glob passed at invocation (or `PM_DOCS_GLOB` from the PM loop) overrides the default.

`docs/` is human-authored input. It is **not** `openspec/specs/`, which is OpenSpec's own durable
source of truth (I-11) and is written by `openspec archive`, never by hand. Never read one expecting
the other.

If `docs/` does not exist, stop and tell the operator to run `/agentic-init` first — do not invent a
docs location.

## Headless invocation (how the PM loop calls this)

```
claude -p "Use the agentic-ba skill to sync OpenSpec changes from the project docs under: docs/**/*.md
— one feature-level change each, with testable acceptance criteria and depends_on/priority
frontmatter." \
  --allowedTools "Task,Read,Write,Bash,Grep,Glob"
```

## Rules

1. **Idempotent.** Derive ids with `lib/ba-changeid.sh`; re-running over unchanged docs must be
   idempotent — identical ids and **no** spurious new changes.
2. **Incremental diff.** When a doc section changes, update exactly the one affected active change;
   never silently drop scope.
3. **Never touch `openspec/changes/archive/`.** Archived changes are immutable history (I-11).
4. **Frontmatter.** Emit `depends_on`/`priority` via `agentic-core/lib/frontmatter.sh` so the PM
   selector parses it. That file is the one BA↔PM seam: core owns both the emitter and the parser.
5. **Validate.** Every change must pass `openspec validate <id> --strict` before you finish.

## Deferred

Live acceptance against the real `openspec` CLI is deferred; helpers and structure are
fixture-tested today.
