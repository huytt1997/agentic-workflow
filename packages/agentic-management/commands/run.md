---
name: run
description: Start the agentic-management PM loop (dry-run by default) over the target project's OpenSpec changes.
---

# /agentic-management:run

Runs `pm-runner.sh` via `${CLAUDE_PLUGIN_ROOT}/bin/pm-run.sh`, which **defaults to a dry-run**
(prints selection + the engineer command, launches nothing).

## Usage

Set `AGENTIC_PROJECT_ROOT` to the target project, then run:

```
bash "${CLAUDE_PLUGIN_ROOT}/bin/pm-run.sh"
```

Review the selection order. To run for real, re-invoke with `PM_DRY_RUN=0`. Configure caps/policy via the
env surface documented in the `agentic-pm` skill.
