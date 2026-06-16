---
name: iron-law-application-depth
description: When to run the full RED/GREEN subagent dogfood vs a lightweight design-decided Iron Law pass for skill edits
metadata: 
  node_type: memory
  type: feedback
  originSessionId: eece656e-9a82-4109-8687-75ba890f1990
---

For APEX skill edits, the user's default is the **lightweight** Iron Law: write against a decided design + existing precedent and verify by inspection, *skipping* the full RED/GREEN subagent dogfood — reserving the full dogfood (isolated baseline subagents) for skills they explicitly flag for **emphasis** (new stack/domain skills, or ones the app leans on heavily).

**Why:** the full dogfood costs ~6–10× the tokens (~90–130k vs ~10–20k for a 2-file convention edit), mostly burned in throwaway subagent contexts. For structural/convention edits with a decided design the marginal information is low; for new stack/domain skills (where the model writes confidently-wrong framework facts from stale memory) it's high. The user weighs this token trade-off explicitly and decides per-skill.

**How to apply:** for a convention/structural/discipline-tweak edit, propose lightweight + state the token delta, and proceed unless they ask for emphasis. When the user says a skill needs "more emphasis" (or it's a new stack/domain skill), run the full dogfood — and remember subagent spend needs their explicit go-ahead (the harness blocks unprompted agent spawns). Always log which path was taken in the handoff/history row. Relates to [[be-token-efficient]], [[baseline-test-isolation]], [[skill-authoring-workflow]].
