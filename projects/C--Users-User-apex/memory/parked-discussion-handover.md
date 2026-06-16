---
name: parked-discussion-handover
description: "Parked discussion topic — planning-to-coding handover process, context efficiency, token management"
metadata: 
  node_type: memory
  type: project
  originSessionId: c3d6f121-1930-4211-85f3-88fb5bfecc61
---

User wants to discuss the planning→coding handover process before the next major pipeline change.

Key focus areas:
- What is the **minimum context** coding mode (DeepSeek) actually needs to execute a spec well?
- How to write specs and handoff docs that are **token-efficient** — not overloaded with background
- Whether **specs should be chunked** for large builds (to keep each coding agent's context lean)
- Avoiding the **"read everything" trap** where coding mode front-loads all docs before acting

**Why:** AI context windows are finite and expensive. A coding agent that reads 10 docs before writing a line of code wastes tokens and risks losing precision. The handover artifact (spec + handoff) should be the only thing coding mode needs.

**When to raise:** at the start of the next planning session, or when the user brings it up.

Related: [[apex-pipeline]] [[karpathy-pipeline-discipline]]
