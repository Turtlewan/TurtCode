---
name: user-autonomy-preference
description: "How the user wants Claude to work — high autonomy, batch questions to the end"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d21109e0-2749-476d-a04d-405f7fc42f93
---

The user prefers **high-autonomy "auto mode"** working: when they say so, proceed through a whole
agenda of items without stopping, make reasonable decisions yourself, and **batch all questions to
the very end** rather than asking one at a time mid-flow. They grant broad web access (no sketchy
downloads). They are comfortable delegating decisions as long as the genuinely behaviour-altering
ones are surfaced for review at the end (the APEX handoff "review needed ⚠️" pattern fits).

**Why:** stated directly mid-session 16 ("auto mode on", "continue with all the items", "leave all
questions to the end"). Matches [[be-token-efficient]] — don't drip-feed.

**How to apply:** in auto mode, drive the full task list, record autonomous decisions with rationale
+ review flags, and consolidate open decisions into one batched question set at the end. Reserve
mid-flow questions for true blockers only.
