---
name: spec-files-to-change-include-tests
description: "a spec's \"Files to change\" header must list the test files + any file its task body directs touching, not just impl files"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f0ed34b3-7bf3-48ec-bb55-7e6526f56080
---

When authoring an APEX spec, the `## Files to change` header list must include **every** file the build will touch — specifically the test files required by acceptance criteria AND any file a task body directs editing (e.g. "extend settings-hub.css"). Listing only the primary implementation files causes an avoidable surgical-scope fork at build time.

**Why:** In wave-0-restyle, restyle-2 and restyle-3 both under-listed: restyle-2's acceptance required `SettingsHub.test.tsx` but the header omitted it; restyle-3's Task 2 directed extending `settings-hub.css` and acceptance required `AppearanceSection.test.tsx`, both omitted from the header. The coder had to treat them as in-intent deviations. The header list is also the wave-grouping + scope-lock, so an incomplete list weakens both.

**How to apply:** Before freezing any spec, cross-check the `## Files to change` list against (a) every test file named in acceptance criteria and (b) every file named in a task body's edit instruction. Add the missing ones with their operation (create/modify). Relates to [[host-verify-full-mypy]] and the wave-0 build.

(migrated from Artemis memory 2026-07-19)
