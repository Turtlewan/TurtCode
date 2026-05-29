---
skill: apex-skill-author
backend: claude
version: 1.0.0
last_updated: 2026-05-29
sources:
  - agentskills.io — skill spec & authoring best practices
  - superpowers:writing-skills — TDD-for-skills methodology
  - docs/research/skill-authoring-best-practices.md
staleness_threshold: 14d
description: >
  Use when creating, editing, or reviewing any APEX skill — SKILL.md or impl.md.
  Triggers: "add a skill", "new skill for X", "update the X skill", "write a
  SKILL.md", a new domain needs a skill, or before changing skill frontmatter,
  registry entries, or the skill index. Use even if the request doesn't say
  "skill" but clearly means authoring one.
---

# Skill Authoring Specialist — Planning Mode

How to create and update APEX skills. Single-file, planning-only — skills are `.md`,
so planning mode (Claude) authors them directly; there is no `impl.md` for this skill.

**Why this skill exists:** a capable agent with repo access already copies the
*structure* of existing skills correctly (frontmatter, sections, even the triple-write).
What it reliably gets wrong is the *judgment*: it skips testing, over-writes length,
defaults to DeepSeek, and writes from training assumptions. This skill targets that gap.

## The Iron Law

**No skill is created or edited without a failing baseline test first.**

If you didn't watch an agent fail at the task without the skill, you don't know what the
skill needs to teach — you're guessing, and you'll document what the model already does
while missing what it gets wrong. This applies to **new skills AND edits**. No exceptions:
not for "obvious" additions, not for "just a section", not for typo passes to content.

The loop (TDD for documentation):

1. **RED** — run the realistic task with a *bare* subagent (no skill). Capture what it gets
   wrong, verbatim. Sandbox its writes so it can't mutate the live registry.
2. **GREEN** — write the *minimal* skill that fixes those specific failures. Re-run the task
   with the skill present; confirm the gaps close.
3. **REFACTOR** — find new loopholes/omissions, add explicit counters, re-test until solid.

Verify GREEN by reading the actual output, not the subagent's self-report.

## When to activate

- Creating a new skill (`/add a skill`, "we need a skill for X")
- Updating any existing `SKILL.md` or `impl.md`
- Changing skill frontmatter, a `registry/domains.md` row, or `SKILLS.md`
- Reviewing whether a skill is well-formed

## Before you author — ask first

1. **Is this even a skill?** If it's mechanical and enforceable (regex, a script, a lint
   rule) → write that instead. If it's a project convention → it belongs in `CLAUDE.md`.
   Skills encode *judgment the model doesn't already have*. A one-off doesn't need a skill.
2. **Do I know this domain's current best practices?** If it's fast-moving or you'd be
   writing from training memory — **REQUIRED SUB-SKILL: invoke `apex-research` first** and
   author from the verified `docs/research/` doc, not assumptions.
3. **Which skill type is it?** (table below — determines how you baseline-test it.)
4. **Does it already exist?** Check `registry/domains.md` and `SKILLS.md` before creating.

## Skill types → baseline-test style

| Type | Examples | Baseline test |
|------|----------|---------------|
| **Discipline** (rules/gates) | apex-code, apex-debug, apex-plan | Pressure scenarios — combine time/sunk-cost/authority pressure; does it comply under stress? |
| **Technique** (how-to) | apex-research, apex-storage | Application scenario — can a bare agent apply it correctly to a new case? |
| **Pattern** (mental model) | apex-system-design | Recognition — does it know *when* the pattern applies, and when not? |
| **Reference** (domain facts) | apex-aws, apex-auth | Retrieval — can a bare agent find and correctly use the right fact? Gap-test common cases. |

## Authoring workflow

```
research? (apex-research if domain unknown) → RED (baseline) → GREEN (write) → REFACTOR → register
```

1. **Research** the domain if needed (§ Before you author, Q2).
2. **RED** — baseline-test per the type table. Sandbox writes to a scratch dir.
3. **Execution gate — ASK THE USER who writes the files:**
   - **Claude direct** (planning) — recommended for judgment-heavy skills; no round-trip.
   - **DeepSeek** — write a `docs/changes/` spec; coding mode executes. Use when the skill
     also needs non-`.md` tooling/code changes.
   - Skills are pure `.md`, so planning *can* author directly — DeepSeek is a choice, not a
     requirement. Do not default to DeepSeek.
4. **GREEN** — write the skill; re-test; verify by reading output.
5. **REFACTOR** — close loopholes.
6. **Register** — the triple-write (below).

## Frontmatter contract

Every skill file starts with:

```yaml
---
skill: apex-<name>
backend: claude | deepseek
version: 1.0.0
last_updated: YYYY-MM-DD
sources:
  - Source Name — url
staleness_threshold: 30d
description: >
  Activation trigger — what task/phrases should load this. (NEW: required.)
---
```

- **`description` is required on every new skill, and added whenever you edit a skill that
  lacks one** (opportunistic backfill — no bulk migration). Write it as an *activation
  trigger* ("Use when…", real user phrases, near-miss exclusions) — **not** a label or a
  workflow summary. A summary makes the agent follow the description and skip the body.
  Front-load the key case; keep under 1024 chars.
- **Why APEX diverges from agentskills.io** (which needs only `name`+`description`):
  `version`/`last_updated`/`sources`/`staleness_threshold` drive the staleness-refresh
  system; `backend` drives mode routing; `skill:` is the APEX id. Deliberate, not drift.

## The triple-write (mandatory — never skip)

A skill isn't "done" until all three are updated. (Agents mirror SKILL.md fine but forget
these — they are the most-skipped step.)

- [ ] `~/.claude/registry/domains.md` — add a row: domain, SKILL path, impl path (or `—`), agent (or `—`), keywords
- [ ] `~/apex/SKILLS.md` — quick-reference row + one-paragraph entry in the right section
- [ ] `~/apex/SKILL-HISTORY.md` — prepend one row (newest first): `Date | Skill | Files | Version | Event | What Changed | Sources`

## SKILL vs impl split

Decide deliberately — do not create `impl.md` by reflex:

- **Planning-only, single `SKILL.md`** — judgment skills (research, planning, design,
  authoring). Default. Avoids the SKILL/impl duplication that causes drift.
- **`SKILL.md` + `impl.md`** — only when there are genuine *coding-mode enforcement*
  patterns: working code, NEVER/ALWAYS rules, verification commands DeepSeek must follow.

If a draft `impl.md` duplicates the SKILL.md template/checklist, that's the signal it
shouldn't exist — fold it back in.

## Content rules — what changes behavior

The model ignores what it already knows. Spend lines only on what it doesn't:

- **Gotchas** — concrete, project-specific corrections ("the `users` table soft-deletes —
  always `WHERE deleted_at IS NULL`"). Highest-value content. Keep in SKILL.md, not a ref file.
- **Defaults, not menus** — "Use X; for the OCR case, Y" beats listing four equal options.
- **Procedures over declarations** — teach the approach to a class of problems, not one answer.
- **Output templates** — give the concrete structure; agents pattern-match it better than prose.
- **NEVER/ALWAYS + Hard blocks at the top** — read first, most reliable behavior control.
- **Omit**: explanations of things the model knows (HTTP, SQL), vague directives ("write
  clean code"), and "when to use" prose buried in the body (too late for discovery — that's
  the description's job).

## Length discipline

**Hard cap: 500 lines / 5,000 tokens per `SKILL.md`.** Loaded content stays in context the
whole session — every line is a recurring cost. Over the cap → move detail to a referenced
file with an explicit load condition ("read `references/x.md` when …"). Be concise; APEX
skills may be richer than minimalist skills, but the cap is firm.

## Updating an existing skill

- Bump `version` (minor for content, patch for typos/formatting).
- Update `last_updated` to today.
- Add `description` if the skill lacks one.
- Prepend a `SKILL-HISTORY.md` row (`updated` / `updated (SKILL)` / `updated (impl)`).
- Run the Iron Law for the edit too — baseline the changed behavior first.

## Hard blocks

- Never create or edit a skill without a baseline test first (the Iron Law).
- Never default skill authoring to DeepSeek — ask via the execution gate.
- Never ship a new skill without the triple-write.
- Never write a `description` that summarizes the workflow instead of triggering on the task.
- Never create `impl.md` that just duplicates SKILL.md.
- Never exceed 500 lines / 5k tokens in a SKILL.md.
- Never author a domain skill from training memory when best practices are stale — research first.

## Review checklist

- [ ] Baseline test run (RED) and failures captured before writing
- [ ] Skill type classified; matching test style used
- [ ] Domain researched via apex-research if knowledge could be stale
- [ ] Frontmatter complete, including a trigger-style `description`
- [ ] SKILL vs impl decided deliberately (default planning-only)
- [ ] Content is gotchas/defaults/procedures — not what the model already knows
- [ ] Under 500 lines / 5k tokens
- [ ] Triple-write done (registry + SKILLS.md + SKILL-HISTORY.md)
- [ ] Execution gate asked (Claude direct vs DeepSeek)
- [ ] GREEN verified by reading output; loopholes refactored
