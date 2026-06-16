---
name: removal-over-prohibition
description: "To fix a skill conflict for the weak coder, remove the conflicting source — don't add a \"don't do X\" prohibition rule"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: cbf3399d-4a3a-4147-b89d-84e59802dd12
---

When a competing/conflicting instruction reaches the DeepSeek coding backend, the fix is to
**remove the source**, not to add a prohibition rule ("don't follow skill X", "never do Y") to
out-rank it.

**Why:** primary 2025–26 evidence (coding-capability pass, ADR-018 / `docs/research/coding-capability/ws-3`)
shows prohibition-type constraints **decay fastest** on weak models (60–73% → 10–20% compliance over a
session; commission rules hold at ~100%), and a literal weak coder under conflicting directives is more
likely to violate *both* than resolve them. Adding "don't" rules also pays the constraint-stacking tax
(~30 pt coding-benchmark drop) and the always-on token cost.

**How to apply:** prefer deletion/archival of the conflicting skill over a guard rule. When a backstop
directive is genuinely needed, phrase it **positively (commission form)** — e.g. apex-code's "follow
apex-code only", not "never invoke other skills". Ties to [[apex-sole-coding-workflow]] and the
"fewer, consistent constraints beat more" finding from the design pass.
