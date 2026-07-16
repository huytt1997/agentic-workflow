---
name: agentic-init
description: Bootstrap a target project for the agentic workflow — install/verify the OpenSpec CLI, run openspec init, and scaffold the docs/ folder the BA reads.
---

# /agentic-init

Prepares the **current project** to be driven by `agentic-ba` and `agentic-pm`.

Use the `agentic-init` skill. It will:

1. Verify the `openspec` CLI is available, installing it if it is not.
2. Run `openspec init` to create `openspec/`.
3. Create `docs/` with an example spec showing the shape the BA expects.

Safe to re-run: it never clobbers an existing `openspec/` or overwrites your docs.
