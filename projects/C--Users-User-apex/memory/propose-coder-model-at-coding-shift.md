---
name: propose-coder-model-at-coding-shift
description: "Before any build, name the coder path (Codex primary / Opus fallback) and confirm — don't silently auto-route"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 97a47186-588e-4011-a69e-aab98ab8c5c7
---

Before starting any build — "let's build" / "start build" / a spec going ready — **state which coder
will run, recommend one, and confirm.** Do not silently auto-route.

**The paths (as of 2026-07-14):**
- **Codex `gpt-5.6-sol`** — the primary coder. Dispatched **per task as a `codex exec` subprocess**
  from the current session. Its own auth, its own quota; spends none of the Anthropic pool.
- **Opus** — the fallback, a fresh `model: opus` worker in the same session, when Codex quota runs
  out. **This one draws the scarce Anthropic Max pool** — the reason the user wants to be told.
- `codex-code` (PS function) — drives Codex standalone, outside the APEX pipeline. Fine for a quick
  supervised build.

**Why:** the user wants to stay in the loop on cost and capability, especially the Codex→Opus
fallback. A scoped exception to the high-autonomy default ([[user-autonomy-preference]]) — it applies
to the *coder pick*, not to other decisions.

**How to apply:** name the path, recommend one, flag it if Opus-fallback is likely (shared pool), and
let the user confirm before launching.

**Superseded machinery — do not reference these, they are deleted (ADR-038):** there is no
"planning→coding shift" and no coding *session* — one session plans and builds. `APEX_MODE`, the
`apex-build` / `apex-opus` / `planning-mode` / DeepSeek launchers, and the planning write-guard are
all gone. The mode split only ever existed because `ANTHROPIC_BASE_URL` is session-level and reaching
DeepSeek required a restart; Codex is a subprocess, so it doesn't.

Related: [[cursor-coedit-flow]].
