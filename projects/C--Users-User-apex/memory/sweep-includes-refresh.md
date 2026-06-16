---
name: sweep-includes-refresh
description: "An SP5/Opus-4.8 skill sweep is de-couple PLUS real-world content refresh, not just restructure"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 38c41336-72ab-41fa-bdb6-295ed9a0c69d
---

When sweeping/de-coupling an APEX skill, you must ALSO bring its content current with real-world
progress — not just mechanically restructure it. The user corrected this mid-batch ("you are also
supposed to update the skill based on progress in the real world") after I waved off research on a
bad criterion.

**Why:** the assistant's training cutoff (Jan 2026) lags the present, so domain facts in a skill may
be stale even when `last_updated` is recent. Restructuring stale content forward = preserving the
staleness. Real catches this session: OWASP Top 10 **2025** (skill cited 2021), **Better Auth** = new
JS default + **Lucia deprecated**, **SSE** = 2026 default for LLM token streaming.

**How to apply:** for each swept skill — (1) read the skill's OWN research/findings table first; (2)
web-research (apex-research / WebSearch / context7) the *gaps* and anything in a fast-moving domain
(auth libs, AI tooling, security advisories, frameworks); (3) update stale recommendations, tag
findings by tier; (4) skip research only for genuinely slow-moving domains (DB/migration invariants,
HTTP semantics, perf fundamentals) and SAY SO in the history row. See [[skill-authoring-workflow]],
[[iron-law-application-depth]], [[be-token-efficient]].
