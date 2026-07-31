---
name: prove-design-against-reality-first
description: "Before committing a non-trivial design/plan to skills or executing it, validate it against real project data/state — dry-run before building, and wait for an in-flight build's real output before planning the next step."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 0048b7e4-865c-4fe2-b7ea-2c2b8016f467
  modified: 2026-07-29T09:17:27.993Z
---

The user steers **proof-first**: don't implement a design or draft a plan against assumptions or a stale snapshot — ground it in real current state first.

Two facets observed (2026-06-24, cross-spec-parallelism + Artemis mechanic-A session):
- **"test it first"** — before baking a proposed system/design change into skills, dry-run it against real project data. Doing this on the cross-spec-parallel design (ADR-029) against Artemis's actual specs caught a corruption bug (dependency-independence ≠ file-disjointness; two no-prereq specs both editing `ports/types.py`) *before* it shipped.
- **"do you not need to see what's been done?"** — don't pre-draft a plan against state an in-flight build is about to rewrite. Wait for the build to finish, read its real output (updated status.md + handoff), then plan.

**Why:** assumptions and stale snapshots produce designs/plans that are wrong or premature; a cheap dry-run / waiting-for-real-state catches it before cost is sunk. The user will explicitly ask for the test or the wait — honor it, don't shortcut to implementation.

**How to apply:** when proposing a design or skill change, test against real data before writing it (extends the Iron Law from skill-edits to design decisions). When a build/process is in flight, check live state and wait for its output before acting — and verify the tree is clean before editing files a build may be writing. Links: [[verify-env-claims-live]], [[be-token-efficient]].
