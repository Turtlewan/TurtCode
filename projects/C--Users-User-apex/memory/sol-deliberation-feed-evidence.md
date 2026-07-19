---
name: sol-deliberation-feed-evidence
description: "Running the ADR-032 Opus×Sol deliberation — Sol's knowledge cutoff is June 2024, so feed it evidence; use it for reasoning, not recall"
metadata: 
  node_type: memory
  type: reference
  originSessionId: b00b700a-01c9-469b-a3dc-6174b2463cda
---

`gpt-5.6-sol` self-reports a **June-2024 knowledge cutoff** (confirmed by live probe, session 66) — older
than the Claude planning model's. Consequences for the ADR-032 Opus×Sol Tier-1 deliberation mode:

- **Sol cannot recall current model/benchmark facts** (it doesn't even know it's "5.6"). Never ask it to
  assess "how good is model X in 2026" from memory. **Feed it a neutral evidence bundle** (facts + the
  decision questions) and let it reason *over the evidence* — its value is judgment/skepticism, not recall.
- This also **neutralises the self-eval conflict**: when the questions concern GPT-5.6's own merits, Sol
  can't tilt via selective recall of favourable benchmarks — it only has what you gave it. Still ask it to
  **declare its conflict of interest** per question (it did, and twice recommended against its own family).
- Keep the cold read sacred (ADR-032): give Sol the evidence, **not** the Opus position. Dispatch:
  `codex exec -m gpt-5.6-sol -c model_reasoning_effort=max --sandbox read-only -` with the bundle on stdin.
  A ~5-question bundle at effort max returns in ~1 min, ~12k tokens — cheap enough to run foreground.

See [[propose-coder-model-at-coding-shift]], [[prove-design-against-reality-first]] (probe live, don't
assume). The session-66 review lives at `docs/research/gpt56-vs-claude-model-usage/`.
