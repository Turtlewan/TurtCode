---
skill: apex-skill-author
backend: claude
version: 1.8.0
last_updated: 2026-07-10
sources:
  - agentskills.io — skill spec & authoring best practices
  - superpowers:writing-skills — TDD-for-skills methodology
  - docs/technical/adr/ADR-031-codex-context-propagation.md
  - docs/research/skill-authoring-best-practices.md
  - docs/research/model-specific-skill-authoring.md
  - docs/technical/adr/ADR-005-stack-best-practice-skills.md
  - docs/technical/adr/ADR-006-buildability-layer-verification-inversion.md
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

**Prompt-independence — test at falling strictness (discipline/gate skills especially).**
Absence-of-skill is only the floor. A skill that fires only when the prompt explicitly supports
it is not reliable — the real failure is a prompt that nudges *against* the rule. Run the
GREEN/REFACTOR task across three strictness levels and confirm the skill holds at each:
**supportive** (prompt asks for the right thing) → **neutral** (prompt is silent on it) →
**competing** (prompt pushes the other way — time pressure, "just skip the test", authority, sunk
cost). A rule that survives only the supportive prompt is a FLAG, not a pass; tighten until it
holds under the competing prompt. (Adapted from ECC `skill-comply`'s prompt-independence model.)

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
   author from the verified `docs/research/` doc, not assumptions. For a **stack skill**
   (`apex-<framework>`) this is **unconditional** — see **Stack skills** below.
3. **Which skill type is it?** (table below — determines how you baseline-test it.)
4. **Does it already exist?** Check `registry/domains.md` and `SKILLS.md` before creating.

## Skill types → baseline-test style

| Type | Examples | Baseline test |
|------|----------|---------------|
| **Discipline** (rules/gates) | apex-code, apex-debug, apex-plan | Pressure scenarios — combine time/sunk-cost/authority pressure; does it comply under stress? |
| **Technique** (how-to) | apex-research, apex-storage | Application scenario — can a bare agent apply it correctly to a new case? |
| **Pattern** (mental model) | apex-system-design | Recognition — does it know *when* the pattern applies, and when not? |
| **Reference** (domain facts) | apex-aws, apex-auth | Retrieval — can a bare agent find and correctly use the right fact? Gap-test common cases. |
| **Stack** (framework/lang best-practice) | apex-nextjs, apex-django, apex-fastapi | Build test — stand up a real project, run the `impl.md` `## Verification Recipe`, confirm it executes and converges. Doc-reading is **not** a baseline. (See **Stack skills** below — distinct family.) |

## Authoring workflow

```
research? (apex-research if domain unknown) → RED (baseline) → GREEN (write) → REFACTOR → register
```

1. **Research** the domain if needed (§ Before you author, Q2).
2. **RED** — baseline-test per the type table. Sandbox writes to a scratch dir.
3. **Execution gate — ASK THE USER who writes the files:**
   - **Claude direct** (planning) — recommended for judgment-heavy skills; no round-trip.
   - **Coding mode** — write a `docs/changes/` spec; coding mode (Codex `gpt-5.6-terra`
     primary; Opus on fallback — ADR-027) executes. Use when the skill also needs
     non-`.md` tooling/code changes.
   - Skills are pure `.md`, so planning *can* author directly — coding mode is a choice,
     not a requirement. Do not default to coding mode.
4. **GREEN** — write the skill; re-test; verify by reading output.
5. **REFACTOR** — close loopholes.
6. **Register** — the triple-write (below).

## Frontmatter contract

Every skill file starts with:

```yaml
---
skill: apex-<name>
backend: planning | coding
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
- Legacy values map forward: `claude` → `planning`, `deepseek` → `coding` (ADR-027).

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

## Stack skills — a distinct family

`apex-<stack>` (e.g. `apex-nextjs`, `apex-fastapi`, `apex-django`) — reusable, opinionated
best-practices for one language / framework / tool (ADR-005). A **distinct category** from
capability (`apex-auth`), specialist (`apex-frontend`), and cloud (`apex-aws`) skills. Do not
classify a stack skill as "just another capability/reference skill" — it carries
family-specific conventions a bare agent will miss:

- **Always `SKILL.md` + `impl.md`.** The meat (enforced patterns) lives in `impl.md`; the
  `SKILL.md` is the thinner planning-side "what to weigh." This is the one family where the
  split is non-negotiable, regardless of the SKILL-vs-impl default above.
- **Altitude is emergent — author where the opinions live.** Usually the framework
  (`apex-django`); language-level (`apex-python`) only when there are genuine language-wide
  opinions worth enforcing. Do **not** pre-build a coverage grid of every language × framework.
- **Build threshold (ADR-005):** create one only when **(a)** the stack recurs across projects
  **and (b)** there are patterns the base model gets wrong / should be enforced consistently.
  Otherwise `apex-stack`'s coverage gate records "no skill — proceeding on base knowledge."

### The `## Verification Recipe` (required in every stack `impl.md`)

The single highest-value section a stack skill carries (ADR-006). `apex-code` / `apex-testing`
are stack-agnostic runners that own the *loop*; the stack skill owns the *commands*. Declare the
exact `check / typecheck / lint / test / build` commands for the stack — runnable verbatim. A
human-readable "verification checklist" is **not** a recipe: the runner cannot consume prose.

- **Layered: language ⊂ framework.** Separate language-level commands (`mypy`, `ruff`, `tsc`,
  `cargo check`) from framework-level (`manage.py check`, `next build`). Verifiability is a
  *language* property (static vs dynamic typing), so the language layer carries the buildability
  weight and is where it's bought back — e.g. enforce `mypy --strict` to raise a dynamic
  language's feedback quality toward a typed one's.
- **Composition:** coding mode unions the recipes of every bound `stack_skills` entry
  (`apex-python` + `apex-django` → Python checks **+** Django checks).
- **No npm bias.** State the stack's real commands; never default to `npm run build` / `npx tsc`
  for a non-JS stack.

### Two baked-in rules — do not skip

1. **Stack skills ALWAYS trigger `apex-research`.** Mandatory, not "if unsure." Framework
   versions move monthly — this is the fastest-rotting content in APEX; never author one from
   training memory. Fetching docs via `context7` while authoring is necessary but is **not** the
   research step and is **not** validation.
2. **The Verification Recipe is empirically validated by running it against a real project (the
   pilot) — NOT doc-sourced.** Reading the framework's docs and transcribing commands is the
   failure mode, not the method. Stand up a real project on the stack, run the recipe, and
   confirm the commands exist, execute, and converge (write → check → read error → fix → re-run).
   A recipe that has never been run is unverified — do not ship it.

## Author to the executor's capability floor

Each file is read by a *specific* model, not an abstract capable reader. "Write good
enforcement content" is necessary but not sufficient — tune it to who runs it. This is the
most-skipped judgment in `impl.md` authoring.

- **`impl.md` → the coder (Codex `gpt-5.6-terra`; Opus on fallback — ADR-027).** Both are
  frontier-class, so the old DeepSeek-Flash scaffolding (pre-resolve *every* decision, ≤2 tools
  per step, lockstep checkpointing) is **no longer forced by coder weakness**. What still earns
  its lines:
  - **Defaults, not menus.** State the default outright ("use X; for the OCR case, Y") rather
    than "pick an expiry that fits" — for determinism and consistency across builds, not because
    the coder can't choose. A genuinely *build-changing* decision still belongs in the spec or
    planning, never buried in `impl.md`.
  - **Gotchas are the real value** — domain facts the model lacks (the `users` table soft-deletes;
    this API rate-limits at N; this lib's v3 default changed). These are capability-independent: a
    frontier coder misses them just as a weak one does. Spend `impl.md` lines here, not on
    scaffolding a capable model doesn't need.
- **`SKILL.md` → planning (Claude Opus / Sonnet).** Judgment-framed prose is correct here,
  but **name the scope explicitly**: Opus interprets instructions literally and won't
  generalize a rule across items on its own. Write "apply to every skill / all `impl.md`
  files", not "apply this".

Evidence and the full model matrix: `docs/research/model-specific-skill-authoring.md`.

## `.agents/skills/` projection — Codex-facing cards (ADR-031)

APEX skills are read by Claude hosts; the Codex coder reads a **repo-local `.agents/skills/`**
directory instead (headless pickup proven). Cards are **projected from APEX skills — generated,
never hand-maintained twice** — and **selective**: bound-stack cards, debug/testing cards, domain
hazard cards. Never mirror the full skill set: most APEX content is planning judgment or hygiene
native to GPT-5.6 — unselective projection is noise that degrades output.

Every card passes three gates before it ships:
1. **Terra RED baseline (the Iron Law, extended to the Codex consumer):** run the card's target
   task with *bare Terra* (`codex exec`, no card) in an isolated probe repo. The card earns its
   place only where bare Terra fails.
2. **Trigger-eval CSV:** should-trigger / should-NOT-trigger prompts (negative controls included)
   run via `codex exec --json` — the dominant failure mode is cards firing too eagerly.
3. **Validation checklist:** frontmatter parses, the shared ~8k-char description-index budget
   fits, no conflicts with AGENTS.md text, `allow_implicit_invocation` set deliberately per card.

> Card anatomy, projection sources, CSV format, generation/refresh workflow: read
> `references/agents-skills-projection.md` when projecting or editing a card.

## impl.md loading tiers — author for what coding mode loads per run

`impl.md` is consumed by coding mode (`apex-code`) on **every build run**, so structure **every
`impl.md`** (new and swept) in two tiers by what must load each run.

**Always-load core** — coding mode loads these sections *by section identity*, every run, for each
bound stack skill. Keep them tight; they are a recurring per-run cost:
- **frontmatter**
- **`## Stack assumptions`** *(capability skills only — e.g. `apex-search`, `apex-storage`)* — a
  one-line statement of the stack/runtime each pattern assumes (e.g. "Assumes Postgres + pgvector;
  on SQLite/sqlite-vec swap the vector DDL"). Planning checks it against the bound stack and adapts
  on mismatch — it is **not** a verifier. Stack skills omit it (they *are* the stack).
- **`## NEVER do` / `## ALWAYS do`** — the hard rules the coder must obey while writing.
- **`## Verification Recipe`** *(stack skills)* — the runnable check loop.
- **a compact `## Common errors → fix` table (≤ ~15 rows)** — kept in core because it saves
  verify-fail recovery iterations. A *long* troubleshooting appendix does **not** qualify → on-demand.

Define the core by these **fixed section names, not a manual "always-load" flag** — so coding mode
loads them mechanically and authors can't silently inflate the core by over-tagging.

**On-demand tail** — bulky worked examples, long pattern walk-throughs, and big reference tables go
to **`references/<topic>.md`**, loaded only when a task's work matches an explicit condition stated
inline at the split point: `> Full wiring: read references/db.md when the task touches the database.`

**When to split — default: don't.**
- A **lean** `impl.md` (≈≤150 lines of dense gotchas + recipe, like `apex-python`) stays **whole** —
  splitting tiny files adds indirection for no saving.
- Split only when the file is **bulky** (approaching the 500-line cap) or a single worked example
  exceeds ~40 lines and is *not* a hard rule. **Inline** any snippet ≤ ~10 lines that is the literal
  form of a NEVER/ALWAYS rule — a lookup costs more than the bytes saved.
- Don't over-fragment: group references by topic; one `references/patterns.md` beats five near-empty
  files. A new `references/*.md` earns its existence only when its load-trigger is distinct.

(Coding-mode side of this contract — what `apex-code` actually loads — lives in `apex-code` SKILL.md
§ "Verification — run the stack's recipe".)

## Content rules — what changes behavior

The model ignores what it already knows. Spend lines only on what it doesn't:

- **Gotchas** — concrete, project-specific corrections ("the `users` table soft-deletes —
  always `WHERE deleted_at IS NULL`"). Highest-value content. Keep in SKILL.md, not a ref file.
- **Defaults, not menus** — "Use X; for the OCR case, Y" beats listing four equal options.
- **Procedures over declarations** — teach the approach to a class of problems, not one answer.
- **Output templates** — give the concrete structure; agents pattern-match it better than prose.
- **Dispatch sites get a bounded return contract** — if the skill dispatches a subagent, specify
  what the child *returns*: a fixed structured shape (verdict/status), or for deep/exploratory work
  "write full output to disk, return a ≤1–2k-token summary or pointer". Never let a child return its
  raw transcript into the orchestrator. (The dispatch return-contract invariant — apex-orchestrate / ADR-015.)
- **NEVER/ALWAYS + Hard blocks at the top** — read first, most reliable behavior control.
- **Skill bodies carry instruction, not history.** Keep validation status ("validated 2026-…",
  "unproven, first run is the proving run"), session/probe narrative, ADR *rationale*, and
  deferred-roadmap notes OUT of the loaded body — they cost context every load for zero behavioural
  value and rot into stale misinformation. Route them to their home: status → SKILL-HISTORY; the
  *why* → the ADR; cross-session facts → memory. The body states the standing rule; cite the ADR for
  why. (This "changelog-as-content" creep is the most common bloat mode found in skill audits.)
- **Omit**: explanations of things the model knows (HTTP, SQL), vague directives ("write
  clean code"), and "when to use" prose buried in the body (too late for discovery — that's
  the description's job).

## Length discipline

**Hard cap: 500 lines / 5,000 tokens per `SKILL.md`.** Loaded content stays in context the
whole session — every line is a recurring cost. Over the cap → move detail to a referenced
file with an explicit load condition ("read `references/x.md` when …"). Be concise; APEX
skills may be richer than minimalist skills, but the cap is firm. For `impl.md`, this split is
governed by the two-tier core/references convention — see § impl.md loading tiers.

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
- Never hand-edit a projected `.agents/skills/` card — edit the source APEX skill and regenerate (one home per fact).
- Never leave a *build-changing* judgment call in `impl.md` — resolve it in the spec or planning; `impl.md` states defaults, not open choices.
- Never exceed 500 lines / 5k tokens in a SKILL.md.
- Never author a domain skill from training memory when best practices are stale — research first.
- Never classify a stack skill (`apex-<framework>`) as a plain capability/reference skill — it's a distinct family (always SKILL+impl, always triggers `apex-research`).
- Never ship a stack skill without a runnable `## Verification Recipe` in its `impl.md`, and never ship that recipe doc-sourced — it must be run against a real project first.
- Never put a hard rule (`## NEVER`/`## ALWAYS`), the `## Verification Recipe`, or `## Stack assumptions` into a `references/*.md` file — the always-load core is defined by section identity and must stay in `impl.md`.

## Review checklist

- [ ] Baseline test run (RED) and failures captured before writing
- [ ] Skill type classified; matching test style used
- [ ] Domain researched via apex-research if knowledge could be stale
- [ ] Frontmatter complete, including a trigger-style `description`
- [ ] SKILL vs impl decided deliberately (default planning-only)
- [ ] impl.md authored for the coder (Codex/Opus) — defaults-not-menus, gotchas over scaffolding, no build-changing choices left open; SKILL.md names scope explicitly
- [ ] impl.md tiered: core (frontmatter + `## Stack assumptions` [capability] + NEVER/ALWAYS + Verification Recipe + compact errors) by section identity; bulky patterns in `references/*.md` with load conditions; lean files left whole
- [ ] Content is gotchas/defaults/procedures — not what the model already knows
- [ ] Under 500 lines / 5k tokens
- [ ] Triple-write done (registry + SKILLS.md + SKILL-HISTORY.md)
- [ ] Stack skill (if any): distinct-family conventions applied — SKILL+impl, runnable `## Verification Recipe` present and empirically run (not doc-sourced), `apex-research` triggered
- [ ] Projection (if the edited skill sources a `.agents/skills/` card): card regenerated + the three gates re-run (references/agents-skills-projection.md)
- [ ] Execution gate asked (Claude direct vs coding mode)
- [ ] GREEN verified by reading output; loopholes refactored
