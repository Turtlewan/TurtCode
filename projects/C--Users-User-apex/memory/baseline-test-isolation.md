---
name: baseline-test-isolation
description: Iron-Law RED/GREEN subagent tests get contaminated when the repo documents the change under test — isolate the agent from planning docs.
metadata: 
  node_type: memory
  type: feedback
  originSessionId: ff214eb2-488f-4552-a09f-ca025651ca9d
---

When Iron-Law baseline-testing an APEX skill edit, a bare subagent with repo read access will
find the roadmap / ADRs / status.md describing the *very change under test* and front-run it —
producing a false "it already works" RED.

**Why:** APEX documents its own intended changes in `docs/` (ADR-005/006, the status roadmap),
so the test environment leaks the answer. Observed session 13 (cluster 3, `apex-stack`): the RED
agent read `status.md`, cited "roadmap item #3 sanctions this," and produced the redesigned
behaviour the current skill doesn't have.

**How to apply:** in the test subagent's prompt, forbid reading `docs/status.md`,
`docs/technical/adr/`, `docs/research/`, `ROADMAP.md`, and handoffs — restrict it to the skill
under test + the registry. The clean GREEN re-run with reads forbidden is what actually proves
the skill drives the behaviour. Also: runtime-behaviour skills (e.g. `apex-code` running a
recipe) can't be validated by a planning subagent at all — defer to a real build (the pilot).

Related: [[skill-authoring-workflow]].
