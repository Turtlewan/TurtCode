---
name: be-token-efficient
description: "User prefers token-efficient responses — lean prose, no unnecessary tool calls or re-reads"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 302c7ff0-6939-4b49-b55d-e49c2c8af19b
---

Keep responses token-efficient: lean prose, minimal preamble, don't re-read files already in
context, batch tool calls, don't over-explain.

**Why:** user explicitly asked to economise tokens (2026-05-31).
**How to apply:** default concise; reserve long-form only for genuinely complex design discussion.
