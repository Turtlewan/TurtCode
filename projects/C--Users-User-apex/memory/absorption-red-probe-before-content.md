---
name: absorption-red-probe-before-content
description: "Before absorbing external-skill *content* into APEX, run a cheap bare-agent RED probe — external content is often model-knowledge-redundant; \"flagged for rigor\" tends to defer real cuts that never happen."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: bdca191d-e751-456b-8bc0-e6c66a90cf3d
---

The 2026-06-13 addyosmani/agent-skills full dogfood found **3 of ~10 freshly-absorbed additions were redundant** — a bare agent produced them cold (CWV/perf reference content via haiku; hypothesis-confidence elicitation and a deprecation procedure via sonnet). They slipped through because the baseline was deferred as "lightweight Iron Law, flagged for rigor."

**Why:** external skill-systems are peer-quality; their *content* (diagnostic trees, named-principle prose, standard procedures) is usually what a frontier — or even a cheap — model already produces cold. Absorbing it violates the content rule (*spend lines only on what the model doesn't already know*). By contrast, *discipline/behaviour* rules earned their place — the model failed them cold: metric-honesty (fabricated CWV numbers point-blank), source-grounding (wrote framework code from memory, no version-check), AI-slop self-flagging (produced slop without noticing), prompt-injection self-defense (cheap one-liner insurance).

**How to apply:** when absorbing *content* (not just structural edits), run a quick bare-agent RED probe at the executor floor **before** adding — if the cold agent produces it, don't absorb. Reserve "flagged for rigor" for genuinely deferred *behavioural* tests, not as a default skip. Caveat: coder-target (`impl.md`) probes use **haiku as a DeepSeek-Flash proxy** — redundancy there is Mac-gated/uncertain, so keep-and-verify rather than cut on the proxy.

Related: [[iron-law-application-depth]] (this refines it — content additions deserve a probe, not just structural-vs-emphasis), [[removal-over-prohibition]], [[be-token-efficient]], [[sweep-includes-refresh]].
