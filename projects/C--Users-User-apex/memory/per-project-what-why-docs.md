---
name: per-project-what-why-docs
description: "Project direction — every APEX-built project should ship and maintain a human-readable \"what it does + why\" doc pair (System Overview narrative + ADR decision log) as human/model-portability insurance"
metadata: 
  node_type: memory
  type: project
  originSessionId: 302c7ff0-6939-4b49-b55d-e49c2c8af19b
---

**STATUS: substantially DELIVERED (2026-06-03, session 27, ADR-014 + ADR-013).** The production+
enforcement wiring landed: `overview.md` is now a **living capability index** kept current via
**merge-on-archive** (apex-code/docs-technical-agent fold each shipped spec's capability in on
archive), apex-init seeds it, apex-plan's doc-coverage check flags it stale-vs-last-archive
(informational, no gate = the "enforced-capture-no-gate / leans recommended" fork, resolved). ADRs now
exist in APEX itself (14). Remaining nuance: applies to *built projects* once APEX builds one. The
original objective text is kept below for context.

Goal for a dedicated planning session: make APEX reliably **produce and keep current**, for
every project it builds, a human-readable "what the system does + why we do certain things"
documentation pair —

1. **System Overview** (`docs/technical/architecture/overview.md`, Divio "Explanation") — the
   readable narrative: what it does, how it's structured, the shaping decisions. Read top-to-bottom.
2. **ADR decision log** (`docs/technical/adr/`) — the append-only ledger of decisions + rejected
   alternatives. The overview links down into it; overview = story, ADRs = footnotes.

**Why:** the driver is portability — keep the system's *why* from dying in conversation context
or thin, drained handoffs. Audience is humans first; the same artifact doubles as model-switch
insurance. Switch scope is **scenario A** (swap the LLM, keep APEX running underneath) — so
conventions in `impl.md` survive the swap and do NOT need lifting into the repo; only the
project-specific *why* + *system map* need durable homes.

**How to apply:** APEX already *describes* these doc types (`apex-docs-product` Divio types,
`apex-docs-technical` ADR/architecture/runbook) but the pipeline never *produces* them — zero
ADRs exist even in APEX itself. The fix is production+enforcement wiring across ~5 skills
(apex-init scaffold, apex-plan ADR-at-decision + overview update, apex-code/handoff promote
build-time decisions → ADR, apex-plan drain "→ ADR" disposition, apex-docs-technical agent
overview upkeep, apex-refresh? freshness). Open design fork = enforcement level
(capture-only / enforced-capture-no-gate [leans recommended] / gated build). Multi-spec → split.
Keep it simple (medium, no blocking gate) so it doesn't fight the AFK flow. Full parked spec in
`docs/status.md` Future Discussions. Relates to [[parked-discussion-handover]] (handoff/context
efficiency) and [[skill-authoring-workflow]].
