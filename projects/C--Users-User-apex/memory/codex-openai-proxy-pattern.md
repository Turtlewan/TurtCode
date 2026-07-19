---
name: codex-openai-proxy-pattern
description: "To let an off-the-shelf tool that expects an OpenAI HTTP endpoint use a subscription model, put a tiny local OpenAI-compatible shim over `codex exec`; eval-grade only (~13k tok/call overhead)."
metadata: 
  node_type: memory
  type: reference
  originSessionId: 249e2fd5-e8ad-489d-b78a-16a0ac7ee1b5
---

Subscription CLIs (`codex exec`, `claude -p`) are **not** web APIs, so tools that require an
OpenAI-compatible `base_url` (Cognee, Graphiti, most LLM libraries) can't use them directly. A
~120-line local FastAPI shim exposing `POST /v1/chat/completions` that dispatches each request to
`codex exec` (with `--output-schema` for structured output, strict-schema normalization) bridges the
gap — proven 2026-06-30 driving both Cognee and Graphiti off the ChatGPT subscription. Reference impl
lived at `scratch/spike/codex_proxy.py` (throwaway).

**Caveat:** each call carries ~13k tokens of Codex agentic-system-prompt overhead → fine for one-off
evals/spikes, **too expensive for high-volume use** (e.g. production memory extraction → use local
Ollama or a metered endpoint there instead). Owner constraint: prefer subscription over metered API
even for evals (see [[artemis-v2-harness-pivot]]). Full context:
`docs/findings/cognee-vs-graphiti-spike-2026-06-30.md`.

(migrated from Artemis memory 2026-07-19)
