# Locked decisions (`D-*`)

_Applicability: read when a change touches the affected area, or when you're tempted to do something a
different way — check here first. These are **settled**; changing one is a deliberate act that ripples
through the scaffold, not a casual refactor._
_Authoritative source: [specs/plan.md](../../specs/plan.md) §3._

| ID       | Decision                                                                                                     | Why                                                                                                     |
| -------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| **D-1**  | Ship as a **Claude Code plugin marketplace**, not an SDK app                                                  | Hard constraint: no Agent SDK. Reuse the hook/subagent/CLI surface.                                     |
| **D-2**  | Three packages: `agentic-core` + `agentic-engineer` + `agentic-management`; core is shared                   | Clean seam between the enforcement kernel and the role pipelines.                                       |
| **D-3**  | Use **`obra/superpowers`** skills inside subagents; don't reimplement brainstorm/plan/execute/review          | Superpowers already has them.                                                                           |
| **D-4**  | Use **`Fission-AI/OpenSpec`** as the spec/ticket substrate                                                    | `changes/{id}/` proposals + `specs/` truth + `archive/`; propose→apply→archive bounds active work.      |
| **D-5**  | Support **both interactive and headless (`auto`)** per invocation, via `--mode`                              | Same pipeline; humans drive locally, PM drives in batch.                                                |
| **D-6**  | **Model + effort per role**, pinned **explicitly at each dispatch**                                           | Cost/quality balance; pinning works around Claude Code bug #44385 (`model:` frontmatter ignored).       |
| **D-7**  | Within-feature state is one JSON file, `.agentic/state.json`, in the worktree                                 | The `feature_list.json` role: one durable source for phase/tasks/checks.                                |
| **D-8**  | **Verification enforced by a Stop/SubagentStop hook** (`verify-gate.sh`)                                      | The agent cannot end its turn while a phase gate is red.                                                |
| **D-9**  | **All destructive-op denial in one PreToolUse hook** (`safety-guard.sh`)                                      | Single choke point; fail-closed on danger, fail-open on parse error.                                    |
| **D-10** | Headless safety = **PreToolUse allow-list + `permissions.allow`**, never global `--dangerously-skip-permissions` | PreToolUse deny runs before permission-mode and can only tighten. Guards the `curl … \| bash` RCE vector. |
| **D-11** | Observability now = **PostToolUse NDJSON emitter**; SSE + SQLite + dashboard deferred to M3                   | `emit-event.sh` writes `events.ndjson`, optionally POSTs `$AGENTIC_SSE_URL`.                            |
| **D-12** | **Git checkpoint after every phase and every green task**; only rollback is revert-to-last-green              | Marker `[agentic:ckpt]`. Ties to `I-5`.                                                                 |
| **D-13** | Install/update/uninstall via `bin/*.sh` with `--target` (default `~/.claude`) and `--mode {symlink\|copy}`   | Symlink for live editing during development.                                                            |
| **D-14** | The **PM outer loop is deterministic shell** spawning a fresh `claude -p` per change                          | Structural answer to context bloat. Ties to `I-1`.                                                      |
