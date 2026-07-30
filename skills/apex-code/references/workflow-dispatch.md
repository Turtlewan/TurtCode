# Workflow dispatch path — full procedure

Loaded on demand by apex-code when a build sets `wave_dispatch: workflow`. The SKILL.md carries the
trigger + the worker return contract (SKILL.md § Codex dispatch — the wrapper's exit codes); this file carries the mechanics.

When `wave_dispatch: workflow` is active, run each **2+-task (sub-)wave** through the native Workflow
tool instead of inline Agent dispatch. This keeps the per-worker transcripts inside the Workflow
runtime (ADR-015 isolation) — the main context receives only a bounded status array.

Per 2+-task (sub-)wave:
1. Build the `args` object from the wave plan you already produced:
   ```
   {
     "spec_path": "<full path to the spec being built>",
     "wave_label": "Wave <N>",
     "isolate": <true if this wave's workers run an artifact-producing recipe, or headless/AFK; else false>,
     "tasks": [
       { "id": "<task id>", "text": "<exact task text>",
         "files": ["<file>", ...], "acceptance": "<the task's done-when / acceptance criterion>",
         "model": "sonnet" }
     ]
   }
   ```
   > `model` carries **only `sonnet`** — the Claude fallback coder (Sonnet 5; A1/ADR-045). Codex — the default coder — is **NOT** dispatched here: it runs as a `codex exec` subprocess in-session (ADR-027). This workflow / parallel fan-out path applies only to Claude-fallback builds. The Claude fallback (Sonnet 5) fires on exactly three triggers: (1) Codex quota-out or unavailability; (2) a whole-spec `coder_model: sonnet` pin; (3) terminal verify-failure routing by the executor (the orchestrator, or the host as interim executor). Nothing else reaches it.
2. Invoke `Workflow({ scriptPath: "<home>/.claude/workflows/apex-build-wave.js", args })`
   (resolve `<home>` to the absolute home directory, e.g. `C:/Users/User` here).
3. The call returns `{ wave, tasks: [ { task, status, files_changed, summary, concern? } ] }`.
   Route each returned status through the **worker return contract (SKILL.md § Codex dispatch — the wrapper's exit codes)** — `DONE` /
   `DONE_WITH_CONCERNS` → decisions table; `BLOCKED` / `NEEDS_CONTEXT` → Forks (capture-at-halt stays
   in apex-code, fed by the returned status).
4. A single-task wave skips the workflow (no fan-out to orchestrate) but still **dispatches**: one `model: sonnet` worker, exactly as the inline rule. The host never writes the task itself (ADR-045).
5. After the wave returns, run § Post-build and continue — review, sequencing, and post-build
   are unchanged by this path.

Prerequisite: `enableWorkflows: true` in settings (already set). If the `Workflow` tool is unavailable
or errors at dispatch, fall back to inline Agent dispatch for that wave and log it in the decisions
table — never block the build on the workflow path.
