---
name: agentic-os-video-ingestion
description: "Standing mode for agentic-OS / Claude-Code-workflow video suggestions: ingest→research→deep-dive→log a candidate verdict, DO NOT implement, deliver a consolidated report only on request."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 9a478326-5d45-4f79-9491-313736f0f4c9
---

The user feeds agentic-OS / Claude-Code-workflow **video transcripts** to evaluate against APEX, in
batches over time. For each video run the pipeline: **digest** (dedup vs already-evaluated) →
**apex-research** (source-grounded, only where a real factual question exists; skip for pure dedup) →
**apex-deep-dive** (Council mode on genuine go/no-go) → **log a verdict** (LEAD / GAP / REJECTED /
DEFERRED + the candidate idea). **Then STOP — do not implement.**

**Hold-off rule:** no build-specs-to-execute, no enabling features, no `docs/changes/` specs mid-stream.
Findings docs, ledger entries, and *decision* ADRs ("we chose not to build X") are fine; *implementation*
waits for explicit go-ahead.

**Accumulator:** `docs/research/agentic-os-video-audit.md` is the running ledger — append each video's
verdict block there so the report is one synthesis from one place.

**Report on demand:** deliver a consolidated report ONLY when the user asks ("report at end of day").
Rank candidates across all videos, tag each LEAD/GAP/REJECTED/DEFERRED, and call out the build-ready
ones separately so the user picks what graduates to implementation.

**Why:** the user wants to review the full slate of ideas before committing any build effort — separating
evaluation from implementation avoids piecemeal building and lets the strongest candidates compete.

**How to apply:** keep producing research + deep-dive verdicts + ledger entries; never start an
implementation until asked; surface the consolidated report only on request.

Related: [[be-token-efficient]] · [[user-autonomy-preference]] · [[background-work-overlap]]
