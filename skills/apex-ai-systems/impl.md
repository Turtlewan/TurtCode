---
skill: apex-ai-systems
backend: deepseek
version: 1.2.0
last_updated: 2026-06-10
sources:
  - Anthropic API Docs — docs.anthropic.com
  - Vercel AI SDK (5/6) — ai-sdk.dev
  - Pydantic AI — ai.pydantic.dev
staleness_threshold: 7d
description: >
  Coding-mode enforcement for LLM-calling code — prompt caching on stable prefixes, max_tokens
  caps, structured output (Zod/pydantic), bounded agent loops, 429/transient retry with backoff,
  model id from a config constant, no-PII logging. Loaded when a task calls an LLM API
  (Anthropic/OpenAI SDK, Vercel AI SDK, Pydantic AI) — "call the model", "add an AI feature",
  "agent loop", "stream the response". Retrieval/embeddings code is apex-search; design-time
  model choice and eval strategy are SKILL.md.
---

# AI Systems Implementation Rules

## Stack assumptions

Code below is **TypeScript + `@anthropic-ai/sdk`**. The **Python `anthropic` SDK has the same
shape** (`client.messages.create(...)`, `cache_control`, `.stream()`), so the patterns
translate directly. Higher-level: TS → **Vercel AI SDK 5/6** (`streamText`/`generateObject`/
agent loop with `stopWhen`); Python → **Pydantic AI** typed agents or LlamaIndex. Use a typed
structured-output API (Zod / pydantic) rather than hand-parsing model text. Retrieval/embeddings
→ apex-search. Model id from a config constant, never hardcoded at call sites.

## NEVER do

- Send PII to an LLM without explicit privacy-policy coverage
- Use LLM output directly in SQL, shell commands, or HTML without sanitisation
- Set no max_tokens — always cap output length
- Ignore API errors — always handle rate limits (429) + transient errors
- Hardcode model names at call sites — use a config constant
- Run a tool/agent loop with no stop condition — bound it (`stopWhen` / max steps)
- Parse freeform text when a structured-output / tool schema is available

## ALWAYS do

- Use prompt caching (`cache_control: ephemeral`) for stable prefixes > 1024 tokens
- Set max_tokens appropriate to the task (not unlimited)
- Retry rate-limit/transient errors with exponential backoff
- Use structured output (Zod / pydantic schema) for any result parsed downstream
- Validate + sanitise LLM output before using it in application logic
- Define a failure path: malformed/refused/empty → validate → retry once → graceful fallback
- Stream responses for user-facing generation
- Log prompt + response for debugging (redact PII first); instrument tokens/cost/latency

## Anthropic SDK pattern with caching  (TS — Python `anthropic` is identical shape)

```typescript
import Anthropic from '@anthropic-ai/sdk'

const client = new Anthropic()

const response = await client.messages.create({
  model: MODEL, // config constant, e.g. 'claude-sonnet-4-6'
  max_tokens: 1024,
  system: [
    { type: 'text', text: longSystemPrompt, cache_control: { type: 'ephemeral' } }, // cache > 1024 tokens
  ],
  messages: [{ role: 'user', content: userMessage }],
})

const text = response.content[0].type === 'text' ? response.content[0].text : ''
```

## Streaming pattern  (TS)

```typescript
const stream = await client.messages.stream({
  model: MODEL,
  max_tokens: 2048,
  messages: [{ role: 'user', content: prompt }],
})
for await (const chunk of stream) {
  if (chunk.type === 'content_block_delta' && chunk.delta.type === 'text_delta') {
    process.stdout.write(chunk.delta.text)
  }
}
```

## Common errors → fix

| Symptom | Fix |
|---------|-----|
| 429 / overloaded | exponential backoff + retry; lower concurrency |
| Model returns prose instead of JSON | use structured output / tool schema, not a "return JSON" instruction |
| Cache never hits | the cached prefix must be byte-identical & ≥ min tokens; put volatile content *after* the cached block |
| Agent loop never ends | set an explicit stop condition / max steps |
| Cost spikes | cap max_tokens, right-size the model, enable caching, batch non-interactive work |

## Verification checklist

- [ ] Check: max_tokens set on all API calls; model from a config constant
- [ ] Check: cache_control on stable system prefixes > 1024 tokens
- [ ] Check: structured output used where the result is parsed; output validated before use
- [ ] Check: agent/tool loops have an explicit stop condition
- [ ] Test: API error returns a graceful message to the user, not a 500
- [ ] Check: no PII in logged prompt/response pairs
