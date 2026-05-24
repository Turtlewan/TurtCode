---
skill: apex-ai-systems
version: 1.0.0
last_updated: 2026-05-24
sources:
  - Anthropic API Docs — docs.anthropic.com
staleness_threshold: 7d
---

# AI Systems Implementation Rules

## NEVER do

- Send PII to an LLM without explicit privacy policy coverage
- Use LLM output directly in SQL, shell commands, or HTML without sanitisation
- Set no max_tokens — always cap output length
- Ignore errors from the Anthropic API — always handle rate limits and errors
- Hardcode model names — use a config constant

## ALWAYS do

- Use prompt caching for system prompts > 1024 tokens
- Set max_tokens appropriate to the task (not unlimited)
- Handle API errors with retry + exponential backoff for rate limits
- Validate and sanitise LLM output before using it in application logic
- Stream responses for user-facing generation
- Log prompt + response for debugging (redact PII first)

## Anthropic SDK pattern with caching

```typescript
import Anthropic from '@anthropic-ai/sdk'

const client = new Anthropic()

const response = await client.messages.create({
  model: 'claude-sonnet-4-6',
  max_tokens: 1024,
  system: [
    {
      type: 'text',
      text: longSystemPrompt,
      cache_control: { type: 'ephemeral' } // cache prompt > 1024 tokens
    }
  ],
  messages: [{ role: 'user', content: userMessage }]
})

const text = response.content[0].type === 'text' ? response.content[0].text : ''
```

## Streaming pattern

```typescript
const stream = await client.messages.stream({
  model: 'claude-sonnet-4-6',
  max_tokens: 2048,
  messages: [{ role: 'user', content: prompt }]
})

for await (const chunk of stream) {
  if (chunk.type === 'content_block_delta' && chunk.delta.type === 'text_delta') {
    process.stdout.write(chunk.delta.text)
  }
}
```

## Verification checklist

- [ ] Check: max_tokens set on all API calls
- [ ] Check: cache_control set on system prompts > 1024 tokens
- [ ] Test: API error returns graceful error to user, not 500
- [ ] Check: no PII in logged prompt/response pairs
