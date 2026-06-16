---
name: absorption-pass-protocol
description: "How the user wants external-system \"compare and absorb into APEX\" passes run — dedup-aware, token-cost-flagged report FIRST, no skill edits until approved"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 35d440d2-61e9-47e6-ae9b-ace9261b612e
---

When comparing an external system (ECC, Odysseus, GSD/Spec-Kit/Kiro/BMAD/Aider/Cline/OpenSpec, …) to decide what APEX should absorb, run this protocol:

1. **Deep parallel-agent research** — dispatch many fresh-context agents (one per system/facet). Each writes its FULL analysis to a `docs/research/...` file and returns only a compact summary, so the orchestrator window stays lean.
   - **Source-grounding is MANDATORY, not conditional.** The agent must (a) resolve + confirm the exact repo URL first (a separate discovery step if unknown — do NOT let web-discovery snippets become the analysis), then (b) `git clone --depth 1` — **required, never "if helpful"**. If the clone fails, report the failure explicitly; NEVER substitute web-search/training summaries for reading the source.
   - **Cite-or-drop.** Every candidate must cite a real file path (ideally + line) from the clone, or it is dropped. Repo identity must carry the resolved URL + commit SHA. Stars/metrics from memory are untrusted — verify or omit.
   - **Orchestrator verifies before trusting.** After agents return, the dispatcher checks clone evidence / citations *before* synthesising. (Failure mode seen 2026-06-05: 5/8 agents skipped cloning when the prompt said "clone if reading the source helps" and gave no URL — they confabulated stars/versions/an arXiv ID from web+training instead.)
2. **Dedup-aware** — tag every candidate already-have / partial / novel against APEX's current state; explicitly call out what's already incorporated so it's skipped (the user asks for this directly: "check if there is any repeated items").
3. **Token-cost flagged** — every candidate carries a Low/Med/High token-cost-when-used tag. Anything that makes APEX burn a lot of tokens when the feature is used MUST be called out (HIGH = always-loaded content, many subagent spawns, large per-invocation loads). The user asks for this explicitly.
4. **Report first, no edits** — deliver the consolidated dedup+cost report and let the user bundle-select. THEN design-first ADRs for architectural items, wire the skills, commit per batch.

**Why:** keeps APEX lean (its whole charter) and avoids re-importing mechanisms it already has; mirrors the ECC absorption the user liked.
**How to apply:** on any "compare X to APEX / what can we add" request, follow this order; never jump to editing skills. See [[be-token-efficient]], [[user-autonomy-preference]].
