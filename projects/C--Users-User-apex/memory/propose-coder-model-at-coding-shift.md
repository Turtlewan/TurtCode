---
name: propose-coder-model-at-coding-shift
description: "At any planning→coding shift, name the coder path (Codex primary / Opus fallback) — don't silently auto-route"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 96111116-0ea9-4c5f-a6b9-e8ffc55b7d87
---

Whenever the user is about to shift into a coding session — any "let's build" / "shift to coding" /
"start build" / spec-ready handoff — **state which coder path will run and confirm**, with a
recommendation. Do **not** silently auto-route.

Under ADR-027 the choice collapsed (was Flash/Pro/Codex): **Codex (`gpt-5.5`) is the primary coder;
Opus is the manual fallback when Codex quota runs out.** The launchers:
- `codex-code` → **Codex** directly (standalone, supervised — no APEX pipeline). Good for quick/Artemis-style builds.
- `apex-opus` → the **Claude coding host** (`APEX_MODE=coding`): apex-code dispatches `codex exec` per task and builds inline as **Opus** on quota-out (mechanic A — full verify/review/docs/checkpoint). The integrated Plan-A path.
- Archived/recovery-only: `coding-mode-deepseek` (Flash) / `apex-code-deepseek-pro` (Pro) — DeepSeek is parked (ADR-027).

**Why:** the user wants to stay in the loop on which coding path runs (cost/capability + the manual
Codex→Opus fallback). Scoped exception to the high-autonomy default ([[user-autonomy-preference]]) —
applies to the coder pick at the coding shift, not other decisions.

**How to apply:** at the shift, name the path (codex-code vs apex-opus), recommend one for the task,
flag that Opus-fallback draws the shared Max pool (soft-pool guard), and let the user confirm before
launching. Related: [[cursor-coedit-flow]].
