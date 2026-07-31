---
name: apex-sole-coding-workflow
description: "Standing decision — APEX is the sole coding workflow; absorb good ideas from competing skill-systems into APEX, never let them co-exist as rivals"
metadata: 
  node_type: memory
  type: project
  originSessionId: cbf3399d-4a3a-4147-b89d-84e59802dd12
  modified: 2026-07-29T09:17:19.120Z
---

APEX is to be the **single coding workflow** on this machine. Competing dev-systems and
coding-process skills installed alongside it (gsd-* ~90 skills, superpowers:* coding-process skills,
controlled-yolo, full-output-enforcement, write-feature-spec, and the built-in code-review/verify/run
slash skills) must **not co-exist as rivals** — they confuse the weak literal DeepSeek coding model,
which can be pulled out of the `apex-code` loop into a competing workflow (esp. via
`superpowers:using-superpowers`' "if 1% chance a skill applies you MUST invoke it" directive).

**Why:** a weak/literal coding model degrades under contradictory + overlapping instructions
(the coding analog of the design pass's constraint-decay finding); one coherent workflow beats
several overlapping ones — the same "don't auto-load competing fixed-behaviour skills" instinct
applies on the design side.

**How to apply:** absorb-then-remove. Harvest the genuinely additive mechanisms from a competitor
INTO the relevant APEX skill (e.g. a good TDD or debugging discipline → apex-testing / apex-debug),
then **disable/remove the competing system wholesale** rather than keeping it installed. Never
recommend installing a competing dev-system; port the idea instead. Decided 2026-06-12 during the
coding-capability research pass (`docs/research/coding-capability/`); to be formalised in an ADR.
