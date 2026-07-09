---
name: engineer
description: Run the agentic-engineer P0-P5 single-feature pipeline (interactive or auto mode).
---

# /engineer

Drives the `agentic-engineer` orchestrator SOP (`skills/agentic-engineer/SKILL.md`) through phases
**P0 worktree -> P1 plan -> P2 execute -> P3 verify -> P4 review -> P5 lifecycle** for exactly one
feature or OpenSpec change.

## Usage

```
/engineer --mode {interactive|auto} [--change <id>]
```

- `--mode interactive` (default): human-in-the-loop. Socratic brainstorm at P1, then **stops for
  human approval** before P2.
- `--mode auto`: headless. Reads `openspec/changes/<id>/{proposal,design,specs,tasks}.md`, writes
  `assumptions.md` for any gap, and never pauses for approval. Requires `--change <id>`.
- `--change <id>`: the OpenSpec change id to implement (required in `--mode auto`).

## Depends on

This plugin depends on `agentic-core` (hooks, `agentic-state`, `agentic-checkpoint`, `agentic-profile`)
being installed; `agentic-core`'s hooks enforce safety (`safety-guard.sh`) and the phase gate
(`verify-gate.sh`) identically across both modes.

## Notes

- All work happens inside a fresh git worktree (P0, before planning — a documented divergence from the
  superpowers default worktree-after-plan ordering).
- The target project's own `CLAUDE.md` / rules win over this plugin's defaults (I-10).
