---
name: one-shot-long-build-initiative
description: "User's ongoing goal — reliably one-shot long multi-spec build sessions; tracks the lever roadmap (batch-joinable shipped, others pending)"
metadata: 
  node_type: memory
  type: project
  originSessionId: de2f59b8-1b20-41b5-9aa1-a730045806f1
---

User is driving an initiative to **reliably one-shot long building sessions** — kick off a queue of specs and have a session drain it without babysitting each step. Framed as removing four *stoppers* — under-specified specs · context exhaustion · Opus-pool starvation · approval halts — plus a checkpoint safety net (per-spec commits + In-Flight resume) so an interrupted run resumes cleanly.

**Pool economics anchor (x5 plan):** keep the heavy *build* phase on Codex's separate pool (config A: Opus-plan / Codex-build / Opus-verify). Never make a standing default of Opus-build + Codex-verify (config B) — it burns the scarce Opus pool on the cheap-to-offload phase. Full-Opus is a deliberate per-spec escalation, not config B.

**Lever #1 SHIPPED (2026-06-25):** batch-joinable spec design default — apex-plan 1.28.0 makes planning author every spec file-disjoint + `## Prerequisites`-ordered so specs are eligible for ADR-028/029 parallel waves; readiness-gate checkbox enforces it, shared-substrate gotcha (types/barrel re-export/schema/route-registry) homed in the spec-template. See [[spec-mechanism-not-just-outcome]].

**Remaining candidate levers (designed-not-scheduled — pick up here):**
1. **Autonomy + permissions preset** — L3/L4 + AFK + `dontAsk` + a *complete* background-worker allow-list (an incomplete allow-list is the most common silent staller — [[background-agents-no-interactive-approval]]).
2. **Context-discipline pass** — workflow dispatch + bounded returns + compact-at-spec-boundary so the main window survives a long multi-spec run (the ADR-015 / P6-maths backlog).
3. **Headless autonomous** (truly AFK) — Mac-Mini-gated; Cloud Routines can't run the APEX coding loop.

**How to apply:** when the user returns to one-shotting builds, resume from the remaining levers; lever #1 is done.
