# `.agents/skills/` projection — card anatomy, gates, workflow (ADR-031)

Read when projecting or editing a Codex-facing card. Cards live in the **target project's repo**
(`.agents/skills/<card-name>/`), are committed with it, and are NOT tracked in `SKILLS.md` (project
artifacts, not APEX skills).

**The source is the project, not an APEX skill (ADR-036).** APEX no longer ships domain or stack
skills, so there is nothing to mirror from. A card is written from **this repo's own facts** — its
pinned versions, its verification commands, its real hazards, its established patterns — and is
grounded by reading the repo, not by copying a rulebook.

## What projects (selective — never a mirror)

| Card class | Projects from | Example cards |
|---|---|---|
| Bound-stack | the repo's pinned versions + its Verification Recipe (`status.md` / `AGENTS.md`) + hazards that bit *this repo* | `typed-python`, `tauri2`, `swift-concurrency` |
| Debug / testing | apex-debug's one-hypothesis + regression-test discipline (process, not knowledge) | `debug-discipline`, `test-discipline` |
| Domain hazard | security invariants **specific to this codebase** — where auth comes from, how tenants are scoped, where secrets live | `auth-hazards`, `migration-hazards` |
| Plan-review | Sol's plan-check rubric | `apex-plan-review` |

What does NOT project: planning judgment, orchestration process, and — critically — **anything the
model already knows**: generic hygiene (validation, HTTP codes, naming, DRY, no-silent-errors),
framework best practice, OWASP categories, language idiom. Injecting these degrades output. This is
the same rule that removed APEX's own knowledge layer; apply it here without exception.

Content calibration (ADR-031): repo-specific, version-bound, resolved values, security invariants,
runnable verification; positively phrased; internally consistent with the repo's AGENTS.md.

## Card anatomy

```
.agents/skills/<card-name>/
  SKILL.md
  trigger-eval.csv
  references/          # optional — bulky tables / walkthroughs, on demand
```

`SKILL.md` frontmatter + body:

```markdown
---
name: <card-name>
description: <activation trigger — when Codex should pull this card; this string counts
  against the shared ~8k-char skills-index budget across ALL cards in the repo>
# allow_implicit_invocation: false   # set false for dispatch-prompt-only cards (must never auto-fire)
---
1. Inspect the repo first: <the check that grounds the card in THIS repo's reality —
   read the config / the pattern file / the pinned version before applying anything>
2. <5–10 conditional invariants — "when X, do Y"; repo/version-specific; positively phrased>
3. Verification: <how to discover + run the relevant checks for work this card covers>
```

## The three gates — every card, before it ships

1. **Coder RED baseline (Iron Law, extended).** Run the card's target task with the bare coder
   (`codex exec -m gpt-5.6-sol`, no card) in a scratch/probe repo. Capture what it gets wrong
   verbatim; the card teaches only those gaps. The bare coder already does it → the content does not
   project. **Probe-repo isolation:** the repo must contain no APEX planning docs / ADRs /
   roadmaps (contamination — the baseline-test-isolation rule).
2. **Trigger-eval CSV.** `trigger-eval.csv` rows: `prompt,should_trigger` — ≥3 `true` rows and
   ≥3 negative controls (near-miss prompts that must NOT fire). Run each prompt via
   `codex exec --json` in the card's repo and check the event stream for card retrieval. Any
   false-fire → tighten the `description`, re-run until clean.
3. **Validation checklist.**
   - [ ] frontmatter parses (name + description present)
   - [ ] sum of all card `description` strings in the repo ≤ ~8k chars (the skills-index budget)
   - [ ] zero conflicts with the repo's AGENTS.md text (rewrite, don't stack)
   - [ ] `allow_implicit_invocation` decided deliberately (false for dispatch-only cards)
   - [ ] body ≤ ~100 lines; bulk in `references/`

## Generation + refresh (never hand-maintained twice)

- Regenerate a card whenever its source APEX skill's *projected sections* change; note
  "projection refreshed: <repos>" in the source skill's SKILL-HISTORY row.
- Start-set for a new project: bound-stack card(s) + debug/testing. Add hazard cards when the
  domain enters the roadmap. Never pre-build a full grid.
- Deleting a source skill → delete its cards in consuming repos (flag them in the session close).
  **Live as of 2026-07-14:** the 36 domain skills were deleted (ADR-036). Any consuming repo holding
  a card projected from one of them (e.g. Artemis) must have that card re-grounded in the repo's own
  facts or removed — a card citing a skill that no longer exists is a stale rulebook.
