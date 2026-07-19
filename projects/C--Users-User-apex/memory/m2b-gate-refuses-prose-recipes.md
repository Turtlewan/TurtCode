---
name: m2b-gate-refuses-prose-recipes
description: "The M2b pre-flight refuses ALL build dispatches into a repo (exit 72 UNPARSEABLE) if its AGENTS.md has prose between the `## Verify commands` heading and the fence; fix via -SkipBaselineCheck bootstrap + relocate the prose"
metadata: 
  node_type: memory
  type: project
  originSessionId: 04486d28-1528-4572-bab2-2f8a50197759
---

2026-07-17 (step-2.5 build): a build dispatched into `~/apex` was refused by the live M2b pre-flight
with `exit 72 / UNPARSEABLE -- recipe fence not immediately adjacent to heading`. Cause: step-2's
Task-1g adjacency rule (only blank lines allowed between an AGENTS.md `## Verify commands` heading and
its opening fence, to close a decoy-fence attack) fires on any recipe that carries an explanatory
sentence between heading and fence. `~/apex/AGENTS.md` had one. This blocks EVERY dispatch into that
repo, not just the offending task.

**Chicken-and-egg:** the gate refuses the very dispatch that would fix the gate-breaking file.

**How to apply:** (1) if a build suddenly refuses ALL dispatches into a repo with exit 72 UNPARSEABLE
"fence not adjacent", check that repo's AGENTS.md `## Verify commands` — move any prose from between the
heading and the fence to BELOW the closing fence (recipe content unchanged). (2) Dispatch the fixing
build with `-SkipBaselineCheck` (the M2b bootstrap escape's exact purpose — host-authorized, not the
orchestrator's call). (3) Verify with `apex-baseline-check.ps1 -Preflight -Worktree <repo>` → GREEN.
Recorded in ADR-041. Also: the orchestrator ticking spec checkboxes writes `docs/changes/<spec>.md`,
which is in `~/apex`; if it ticks DURING a `~/apex` dispatch's scope check, the spec file shows as an
out-of-scope write — tick after the same-tree scope check closes ([[host-writes-void-open-gates]]).
