---
name: sol-deliberation-feed-evidence
description: "gpt-5.6-sol's knowledge cutoff is June 2024 — feed it neutral evidence bundles, don't ask it to recall current facts; mechanism now formalized in apex-plan/references/sol-plan-check.md"
metadata: 
  node_type: memory
  type: reference
  originSessionId: b00b700a-01c9-469b-a3dc-6174b2463cda
  modified: 2026-07-29T09:15:27.115Z
---

`gpt-5.6-sol` self-reports a **June-2024 knowledge cutoff** (confirmed by live probe, session 66) —
older than the Claude planning model's. It cannot recall current model/benchmark facts (it doesn't
even know it's "5.6"), so never ask it to assess "how good is model X in 2026" from memory — **feed
it a neutral evidence bundle** (facts + the decision questions) and let it reason *over the evidence*;
its value is judgment/skepticism, not recall. This also neutralises self-eval conflicts (it can't tilt
via selective recall of favourable benchmarks when the question concerns its own family).

The dispatch mechanism (cold-read discipline, evidence-not-position, `codex exec` invocation shape)
is now formalized in `apex-plan/references/sol-plan-check.md` — see that file for the current
procedure. The session-66 review lives at `docs/research/gpt56-vs-claude-model-usage/`.
