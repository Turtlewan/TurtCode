---
name: autonomous-wave-build-cadence
description: "Once a multi-spec build is greenlit, run autonomously through the waves — don't checkpoint per-wave"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: cf607d2e-1612-4e3b-8357-6aa52dac5f38
---

When a multi-spec / multi-wave build is underway and the owner has greenlit it ("resume build", "build the cluster"), do NOT stop at each wave boundary to ask "continue?". Run autonomously through the waves; halt only for a **genuine blocker/fork** (a real dependency/architecture decision that's the owner's to make) or to **report at the end**.

**Why:** asked the owner per-wave after F0 of the Artemis cluster build (2026-06-24); they chose "Continue, don't ask per-wave — plow through, only halt for a genuine blocker/fork or report at the end." Aligns with [[prefers-end-state-scope]] and [[afk-spec-drafting-workflow]].

**How to apply:** keep the per-spec build loop (Codex dispatch → host-verify full recipe → commit under standing auto-commit) running across waves without check-ins. Still surface genuine forks (e.g. the M3-a docling dep decision) via one question. Dispatch mode (serial vs parallel) is a separate choice — the owner picked **serial** for this build (easier to watch the structural amendments). Context-exhaustion risk IS a legitimate reason to checkpoint with a thorough handoff rather than risk a mid-build stop.

(migrated from Artemis memory 2026-07-19)
