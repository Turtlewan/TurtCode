---
skill: apex-ai-systems
backend: claude
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Anthropic API Docs — docs.anthropic.com
  - Model Context Protocol (MCP) — modelcontextprotocol.io
  - Vercel AI SDK (5 / 6) — ai-sdk.dev
  - Pydantic AI — ai.pydantic.dev
  - Langfuse (LLM tracing/eval) — langfuse.com
  - Artificial Analysis (model landscape) — artificialanalysis.ai
staleness_threshold: 7d
description: >
  Use when designing an LLM/AI feature — model choice, prompting, structured output,
  tool-calling agents, RAG generation, streaming, evals, guardrails, cost. Triggers:
  "use an LLM for X", "AI agent", "chatbot/assistant", "summarise/extract/classify with
  AI", "which model", "prompt for X", "eval the AI". Provider- and framework-neutral; TS →
  AI SDK, Python → Pydantic AI / official SDK, see § Stack assumptions. The retrieval half
  of RAG (chunking/vector/hybrid) is apex-search; this skill owns generation + eval.
---

# AI Systems Specialist — Planning Mode

## When to activate
LLM integrations, RAG **generation**, tool-calling agents, prompt engineering, structured
output, AI evaluation, streaming, guardrails. (Retrieval/embeddings/vector → **apex-search**.)

## Stack assumptions

Concepts here are **provider- and framework-neutral**. The wiring differs by stack:

| Layer | TypeScript | Python |
|-------|-----------|--------|
| Framework | **Vercel AI SDK 5/6** (typed `streamText`/`generateObject`, agent loop) | **Pydantic AI** (typed agents) or LlamaIndex; or the official SDK directly |
| Provider SDK | `@anthropic-ai/sdk` / `openai` | `anthropic` / `openai` (same API shape) |
| Tracing/eval | Langfuse / OTel | Langfuse / OTel |

Provider choice is also swappable — the prompting, agent-loop, structured-output, and eval
**patterns are identical** across Claude / GPT / Gemini; only model id + client change.

## Current model landscape — June 2026 (⚠ staleness 7d — re-verify, this moves weekly)

Pick by task, not by reflex-reaching for the biggest model:

| Tier | Current (Claude family) | Use for |
|------|-------------------------|---------|
| Frontier | **Claude Opus 4.8** | hardest reasoning, agentic coding, critical judgement |
| **Balanced default** | **Claude Sonnet 4.6** (≈1M context, strong caching) | most production traffic — near-frontier at a fraction of cost |
| Cheap/fast | **Claude Haiku 4.5** | classification, extraction, routing, high-volume simple tasks |

Cross-provider peers: GPT-5.x, Gemini 3.x (often cheaper input). **Default to Sonnet-tier**
for production; reserve Opus-tier for tasks that measurably need it; route trivial work to Haiku-tier.

## Patterns — pick the simplest that fits

- **Direct completion** — single prompt → response (classify, summarise, extract). Use `generateObject` / structured output for anything parsed downstream.
- **RAG** — retrieve (apex-search) → inject context → generate. This skill owns the *generate + cite + ground* half; never let the model answer outside retrieved context for factual queries.
- **Tool-calling agent** — model decides tool calls → execute → feed results back → loop until done. Control the loop explicitly (AI SDK `stopWhen` / max steps); never an unbounded loop.
- **MCP (Model Context Protocol)** — the standard way to expose tools/context/resources to the model. Prefer an MCP server over bespoke glue when tools are reused across agents/apps.
- **Streaming** — for any user-facing generation (reduces perceived latency). SSE is the transport (→ apex-realtime).

## Structured output & reliability

- Prefer **structured output / tool schemas** (typed: Zod in TS, pydantic in Python) over parsing freeform text — eliminates a whole class of failures.
- Always define the **failure path**: malformed/refused/empty output → validate, retry once with a repair prompt, then fall back gracefully. Never assume well-formed output.
- **Temperature**: 0 for deterministic (extraction/classification/structured), higher only for genuinely creative copy.

## Evaluation — "how do we know it works?" is not optional

The most-skipped step. Define eval *before* shipping:

- **Golden dataset** — a versioned set of representative inputs + expected/acceptable outputs; run it on every prompt/model change (regression eval). Even 20–50 hand-checked cases beats vibes.
- **LLM-as-judge** — for open-ended outputs, score with a rubric prompt (a cheaper model judging against criteria); calibrate the judge against human labels on a sample.
- **RAG-specific** — measure **faithfulness/groundedness** (answer supported by context?), **context relevance**, and **answer relevance** — not just "looks right".
- **Tracing** — instrument every call (Langfuse / OTel): prompt, tokens, latency, cost, tool calls. You can't improve what you don't trace.
- **Guardrails** — input (prompt-injection, PII) and output (toxicity, schema, policy) checks on untrusted or user-facing paths.

## Cost/quality levers

- **Model selection** is the biggest lever (see landscape table) — right-size per task.
- **Prompt caching** — enable for stable prefixes > ~1024 tokens repeated across calls (large savings on system prompts / RAG context / few-shot).
- **Max tokens** — always cap output; prevents runaway cost and latency.
- **Batch** non-interactive work where the provider offers a discounted batch tier.

## Review checklist

- [ ] Model right-sized to the task (not Opus-tier by default)
- [ ] Structured output used where the result is parsed downstream
- [ ] Failure path defined for malformed/refused/empty output (validate → retry → fallback)
- [ ] Agent/tool loop has an explicit stop condition (no unbounded loops)
- [ ] Prompt caching enabled for long stable prefixes; max_tokens set
- [ ] **Eval strategy defined** (golden set / LLM-judge / RAG metrics) before ship
- [ ] Tracing instrumented (prompt, tokens, cost, latency)
- [ ] PII/prompt-injection guardrails on untrusted & user-facing paths
- [ ] Streaming for user-facing generation

## Standards

- Anthropic API & prompt caching — docs.anthropic.com
- MCP — modelcontextprotocol.io · AI SDK — ai-sdk.dev · Pydantic AI — ai.pydantic.dev
