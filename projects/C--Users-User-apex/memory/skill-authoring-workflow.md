---
name: skill-authoring-workflow
description: "How APEX skills are created/updated — apex-skill-author skill, Iron Law dogfooding, planning-direct editing"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 9afb47b9-c721-47e7-961e-a3361f048425
---

APEX skill authoring is governed by the `apex-skill-author` skill (created 2026-05-29),
which is the source of truth — `apex/CLAUDE.md` only holds a pointer to it now.

Key working preferences established this session:
- **Dogfood the Iron Law for real.** When creating/editing a skill, actually run the
  baseline subagent test (RED) and the with-skill verification (GREEN) via spawned agents —
  don't just assert it. The user explicitly wants the "watch it fail / watch it pass" runs,
  not a skipped/assumed version. Verify GREEN by reading the output file, not the self-report.
- **Skill `.md` editing is done directly in planning mode** (Claude), since skills are `.md`
  and the planning hook allows `.md`. Not specced out to DeepSeek by default.
- **Per-edit execution gate, not a fixed policy.** At the moment of editing a skill, ask the
  user which backend executes it (Claude-direct vs DeepSeek). The user chose to be asked each
  time rather than lock a standing rule.
- **Judgment skills are planning-only, single `SKILL.md`** (no impl.md) — e.g. apex-research
  was merged to single-file. impl.md only when there's genuine coding-mode enforcement (code,
  NEVER/ALWAYS, verification commands).

**Why:** the baseline tests this session showed capable agents already copy skill *structure*
fine but miss the *judgment* (testing, length cap, description field, defaulting to DeepSeek).
The skill targets that gap.

**How to apply:** for any future "add/edit a skill" request, invoke [[apex-skill-author]]
and run its Iron Law loop. Related: [[parked-discussion-handover]].
