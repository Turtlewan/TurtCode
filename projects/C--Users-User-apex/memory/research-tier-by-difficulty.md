---
name: research-tier-by-difficulty
description: "Default to lean searches / apex-research; reach for the deep-research exhaustive harness ONLY for contested × high-stakes × hard-to-reverse questions — don't reflexively fan out ~100 agents."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 89ddb43e-a0eb-4c43-86c4-9716737d597a
  modified: 2026-07-29T09:17:34.164Z
---

Research effort must scale to the question's **reversibility × stakes × prior-bias**, NOT to how much literature exists. Default to `apex-research` (model-gated, right-sizes itself) or a handful of targeted searches. Reach for the heavyweight `deep-research` harness (scope → search → fetch → per-claim 3-verifier adversarial sweep → synthesise; fans out ~100 agents) **only** for the contested × high-stakes × hard-to-reverse class. deep-research is KEPT, but as a deliberate "exhaustive tier," never the default.

**Why:** a `/deep-research` run on a settled sports-nutrition question (muscle-protein-synthesis dosing) fanned out ~105 agents before being killed. Root cause: deep-research is a fixed script whose agent count ≈ O(claims × 3 verifiers), and claims scale with corpus size — so it spends its heaviest machinery on *well-studied* topics where consensus is clear and adversarial verification refutes ~nothing. The fan-out is **inversely correlated** with where verification actually pays off. A RED probe (one bare Sonnet agent, no skill) already gated effort correctly by difficulty — declined the adversarial pass for the settled question ("would cost more than the signal gained"), reserved it for the contested/irreversible one — so the discipline is **model-native**; the harness's flaw is having no difficulty input, not the model lacking judgment.

**How to apply:** before invoking deep-research, ask "is this contested / high-stakes / irreversible?" No → lean searches or apex-research. Yes → deep-research earns its cost. APEX needs **no skill edits** for this (gate is RED-rejected as model-redundant content; adversarial-independence already lives in apex-deep-dive council ADR-010; apex-research already says scale-to-stakes + stop-early). The absorption pass closed with zero edits — the value was the validating signal. Links: [[be-token-efficient]].
