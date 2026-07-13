# `.agents/skills/` projection — card anatomy, gates, workflow (ADR-031)

Read when projecting or editing a Codex-facing card. Cards live in the **target project's repo**
(`.agents/skills/<card-name>/`), are committed with it, and are NOT tracked in
`registry/domains.md` / `SKILLS.md` (project artifacts, not APEX skills). The APEX skill is the
source; the card is generated output.

## What projects (selective — never a mirror)

| Card class | Projects from | Example cards |
|---|---|---|
| Bound-stack | stack impl.md NEVER/ALWAYS + Verification Recipe + version-bound hazards | `typed-python`, `tauri2`, `swift-concurrency` |
| Debug / testing | apex-debug one-hypothesis + regression-test discipline; apex-testing recipe rules | `debug-discipline`, `test-discipline` |
| Domain hazard | security invariants only (auth-source, tenant scoping, secret handling) from apex-security / apex-auth / apex-data impl cores | `auth-hazards`, `migration-hazards` |
| Plan-review | Sol's plan-check rubric — **lands with Phase C**, listed here for shape only | `apex-plan-review` |

What does NOT project: planning judgment, orchestration process, generic hygiene (validation,
HTTP codes, naming, DRY, no-silent-errors — native to GPT-5.6; injecting degrades output).
Content calibration is the same as AGENTS.md § Conventions (ADR-031): repo-specific, version-
bound, resolved values, security invariants, runnable verification; positively phrased;
internally consistent with the repo's AGENTS.md.

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
