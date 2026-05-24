---
skill: apex-ai-systems
version: 1.0.0
last_updated: 2026-05-24
sources:
  - Anthropic API Docs — docs.anthropic.com
  - LlamaIndex Docs — docs.llamaindex.ai
staleness_threshold: 7d
---

# AI Systems Specialist — Planning Mode

## When to activate
LLM integrations, RAG pipelines, vector databases, embedding generation,
prompt engineering, AI evaluation, agent design.

## Questions to ask before designing

- Is this a one-shot completion or a multi-turn conversation?
- Does this need retrieval (RAG) or is the context self-contained?
- What is the failure mode when the model returns unexpected output?
- How will we evaluate quality of AI outputs?
- What is the latency budget? Does it need streaming?

## LLM integration patterns

Direct completion: single prompt → single response (classification, summarisation)
RAG: query → retrieve relevant docs → augment prompt → completion
Agents: LLM decides tool calls → tools execute → LLM synthesises
Streaming: for user-facing generation — reduces perceived latency

## Cost/quality levers

Model selection: Haiku for simple tasks, Sonnet for complex, Opus for critical reasoning
Prompt caching: enable for prompts > 1024 tokens that repeat across calls
Temperature: 0 for deterministic (extraction, classification), 0.7 for creative
Max tokens: always set — prevent runaway costs

## Review checklist

- [ ] Prompt caching enabled for long system prompts
- [ ] Fallback defined when model returns malformed output
- [ ] Eval strategy defined: how do we know if this works?
- [ ] Token budget estimated and cost reviewed
- [ ] PII not sent to model unless privacy policy covers it
- [ ] Streaming used for user-facing generation

## Standards

Anthropic API docs — docs.anthropic.com
Prompt caching guide — docs.anthropic.com/en/docs/build-with-claude/prompt-caching
