---
name: host-writes-void-open-gates
description: "While a pinned read-only gate is open on a tree, the host must not write to that tree — even status.md; the 2026-07-16 spec-check VOIDed on the host's own status update"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 58b80d38-03b1-4bf3-a098-8c7a9f621f62
---

2026-07-16: the host dispatched a tree-pinned read-only Sol spec check into `~/apex`, then updated
`docs/status.md` in that same tree while the gate was open. The pin correctly VOIDed the verdict
(exit path: "THE TREE MOVED WHILE THE GATE WAS OPEN — NEW: docs/status.md"). The gate had to be
re-run.

**Why:** a gate's verdict describes the tree at pin time; ANY write to the pinned root — including
the host's own bookkeeping — makes the verdict describe a tree that no longer exists. The pin cannot
distinguish "harmless status note" from "concurrent coder".

**How to apply:** sequence host bookkeeping around gates — update status.md and other in-tree state
BEFORE dispatching a pinned gate on that tree, or AFTER its verdict returns; never in between. Same
discipline as [[prove-design-against-reality-first]] ("verify the tree is clean before editing files
a build may be writing"), applied to the host's own writes.
