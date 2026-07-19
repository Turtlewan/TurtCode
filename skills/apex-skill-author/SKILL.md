---
skill: apex-skill-author
version: 2.0.0
last_updated: 2026-07-14
sources:
  - docs/technical/adr/ADR-011-instinct-loop-no-engine.md
  - docs/technical/adr/ADR-031-codex-context-propagation.md
  - docs/technical/adr/ADR-036-remove-knowledge-layer.md
  - docs/technical/adr/ADR-037-three-context-files.md
staleness_threshold: 30d
description: >
  Use when creating, editing, or reviewing an APEX skill. Triggers: "add a skill", "new skill for
  X", "update the X skill", a new domain needs a skill, or before changing skill frontmatter or the
  index. Use even if the request doesn't say "skill" but clearly means authoring one. Owns the Iron
  Law, the frontmatter contract, the double-write, and the line caps.
---

# Authoring an APEX skill

**The default answer is: don't write one.**

APEX deleted 36 domain skills and ~650 lines from its two core skills (ADR-036) because they encoded
what the model already does. A RED probe of *this very skill* reproduced its Iron Law, its caps, its
description contract, and its removal-over-prohibition rule — cold, with nothing loaded. The lesson
generalises: **most proposed skills should not exist.**

Written-down knowledge the model already has is not neutral. It is **harmful**:
- Anthropic: *"Bloated files cause Claude to ignore your actual instructions."*
- The AGENTS.md study: LLM-authored restatement **lowered task success in 5 of 8 settings**.
- A stale skill is **worse than no skill** — it overrides a prior that *improves with every model
  release*, confidently and silently, and the agent will never flag it.

So **bias the set toward LOCAL facts** — this repo's build command, this user's preference, this
project's convention. Local facts have no prior to fall back on, and they fail loudly when wrong.
General best-practice content decays worst and justifies itself least.

## The Iron Law

**Baseline-test before you write. No exceptions.**

1. **RED.** Dispatch a bare agent — **no skill loaded** — and give it the real task, 2–3 realistic
   prompts. Capture verbatim what it gets wrong.
2. **The skill teaches only those gaps.** If the bare agent already does it right, the skill has no
   work to do. **Don't write it.**
3. **GREEN.** Re-run with the skill. If behaviour didn't change, the skill is a no-op — delete it.

**Sandbox the probe.** The agent must not read `docs/` — no status.md, no ADRs, no roadmaps, no
other specs. A probe that reads the project's own narrative measures **the context, not the model**,
and will rubber-stamp whatever you were about to write.

A skill is a **diff against the model's default behaviour**. If you never measured the default, you
don't know what you're shipping.

**Depth:** full RED/GREEN for a new skill or a new domain. A lightweight pass — state the rule, ask
"would a bare agent already do this?", answer honestly — for convention or structural edits.

## When a rule is genuinely needed

The reflex is "the agent keeps doing X — add a rule against it." That is usually wrong, and it is
how rule-lists rot. In order of preference:

1. **Remove the cause.** Something in context is suggesting X — a stale example, a rival skill, a
   conflicting doc. Delete it. **Prohibitions decay far faster than absent temptations.** (APEX
   carried a rule naming `gsd-*` as forbidden; deleting the gsd skills deleted the need for the rule.)
2. **Make it structurally impossible.** A hook, a lint, a permission gate, a failing test.
   **Mechanism beats instruction** — Anthropic's own rule is that zero-exception requirements belong
   in hooks, because instructions are advisory and hooks are deterministic.
3. **State it positively.** "Do Y" beats "don't do X" — a negation still puts X in the context.
4. **Only then a rule**, and only after a probe confirms it changes behaviour.

Writing a rule is cheap; carrying it is expensive. That asymmetry is the whole problem.

## Anatomy

Frontmatter — all fields required:

```yaml
skill: apex-<name>
version: <semver>
last_updated: YYYY-MM-DD
sources: [<short names, not URLs>]
staleness_threshold: 14d | 30d
description: >
  <the routing key — see below>
```

**`description` is not a summary — it is a classifier input.** It is the only part of the skill in
context before it loads; the agent reads a list of descriptions and picks one. So:
- Name **concrete triggers** — the verbs and phrases the user actually types.
- Name the **negative boundary**: what this skill is *not*, pointing at the sibling that owns that.
  Ambiguity between two descriptions is the main failure mode, and **mis-routing is worse than not
  loading**.
- It costs tokens every single session. Keep it tight.

**Body: ≤500 lines, hard. Real pressure at ~200.** The cap is a forcing function — it makes someone
justify each section. If a skill sits *exactly* at the cap, the cap is shaping the design rather than
constraining it. That is a smell, and it was true of apex-plan and apex-code for months.

**Split by load frequency, not by topic.** A small always-loaded core (the rules that apply every
time) plus a `references/` tail loaded on demand. Pay for the 100 lines you always need; pay for the
500 only when you actually hit that case.

## The double-write

Every creation or meaningful update lands **both**:

- `~/apex/SKILLS.md` — the index entry.
- `~/apex/SKILL-HISTORY.md` — one row, **prepended** (newest first):
  `Date | Skill | Files | Version | Event | What Changed | Sources`
  Events: `created` · `updated` · `removed`.

There is no registry. It duplicated the index and routed nothing (ADR-036).

## Codex-facing cards (`.agents/skills/`)

Cards live in the **target project's repo**, not here (ADR-031). Their source is **the repo's own
facts** — pinned versions, verify commands, real hazards — never an APEX skill; there are no domain
skills to mirror. Same Iron Law, same gates. Detail → `references/agents-skills-projection.md`.

Most repos need no cards at all. The repo's `AGENTS.md` is usually the whole answer.
