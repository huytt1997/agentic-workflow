---
name: agentic-ba
description: Sync a target project's docs/design into OpenSpec changes with testable acceptance criteria and depends_on/priority frontmatter.
---

# agentic-ba

Orchestrator SOP: given a docs glob, produce/update OpenSpec changes. Dispatch the `ba-analyst` subagent
(pinned `opus`/`high`) for the heavy reading/writing.

## Headless invocation (how the PM loop calls this)

```
claude -p "Use the agentic-ba skill to sync OpenSpec changes from the project docs under: <glob> — one
feature-level change each, with testable acceptance criteria and depends_on/priority frontmatter." \
  --allowedTools "Task,Read,Write,Bash,Grep,Glob"
```

## Rules

1. **Idempotent.** Derive ids with `lib/ba-changeid.sh`; re-running over unchanged docs must be
   idempotent — identical ids and **no** spurious new changes.
2. **Incremental diff.** When a doc section changes, update exactly the one affected active change;
   never silently drop scope.
3. **Never touch `openspec/changes/archive/`.** Archived changes are immutable history (I-11).
4. **Frontmatter.** Emit `depends_on`/`priority` via `lib/ba-frontmatter.sh` so the PM selector parses it.
5. **Validate.** Every change must pass `openspec validate <id> --strict` before you finish.

## Deferred

Live acceptance against the real `openspec` CLI is deferred (00-overview.md D-A); helpers and structure
are fixture-tested today.
