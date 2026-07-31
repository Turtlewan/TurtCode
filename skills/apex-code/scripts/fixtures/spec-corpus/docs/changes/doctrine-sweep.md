---
spec: doctrine-sweep
status: draft
autonomy_level: L2
risk: high
coder_effort: medium
coder_model: codex
---

# Spec: Doctrine-audit repair sweep (D1–D8 + mechanical categories 1–10)

**Identity:** Repairs the ~55 findings of the 2026-07-29 doctrine audit across the APEX doc surface — 8 ratified decisions (D1–D8) plus 10 mechanical fix categories — one owning task per file.
→ why: see docs/technical/adr/ADR-046-doctrine-audit-resolutions.md (created by Task 1).

## Intent
- **Intent:** Every finding in `docs/research/doctrine-audit-2026-07-29/README.md` is repaired in the live file that carries it, so the doctrine layer stops contradicting itself; ADR-046 records D1–D8 and ADR-045 carries the D1 amendment.
- **Invariants:**
  - No gate is weakened beyond the eight ratified carve-outs (D1–D8). The hard-block list keeps every entry; D2/D4/D5/D8 add scoped carve-outs, they do not delete blocks.
  - Critical paths still require live attended confirmation at every level (D3). A spec's `## Permissions` pre-authorizes NON-critical actions only.
  - Exactly one task owns each file — no file appears in two tasks.
  - Every D-decision edit cites ADR-046 **at the edit site**; mechanical edits cite ADR-046 via their banner/caveat blockquotes and their `SKILL-HISTORY` Sources column — **no per-line citations required**. Skill frontmatter `sources:` gains ADR-045/ADR-046 exactly where a task says so.
- **Non-goals:** No new rules; no behaviour not traceable to a named finding. No skill deletions, no new skills, **no executable LOGIC changes** — the single `apex-build-wave.js` edit alters a worker-prompt **string literal** only, an explicit exception recorded here. No hook/script logic changes, no `docs/audit/` writes, no git operations.

## Assumptions
- `docs/research/doctrine-audit-2026-07-29/README.md` + `sol-findings.json` are the authoritative work list. The one known local edit is the host's 2026-07-29 correction of the D1 row's ratification status (now "owner-ratified 2026-07-29"); it is uncommitted and expected. Any *other* divergence means the work list moved under this spec → impact: Stop
- ADR-046 is the next free ADR number (highest existing is ADR-045) → impact: Caution
- `hooks/apex-session-context.md` classifies critical: `apex-critical-files.ps1` (~lines 188-194) matches the path component `hooks` deterministically (`$normalizedPath -match '(^|/)hooks(/|$)'` → `$category = 'hooks'`), regardless of the file being prose rather than an executable hook. **That gate was satisfied live on 2026-07-29** — the host applied both edits attended, under the owner's confirmation, ahead of this build (D3 honoured by a human decision, not by spec text). **Task 23 therefore does not park: it is verify-only, and the build must not edit this file.** A failing check means the live file drifted after 2026-07-29 → impact: Caution
- `docs/audit/` is refused by the same classifier on a **path match alone** (`'(^|/)docs/audit(/|$)'` → `HARDBLOCK … : audit`, exit 11) with **no append-vs-edit distinction**. D5's append allowance is therefore doctrine ahead of enforcement; this spec changes no script, so the block stays total in practice → impact: Caution
- No file in this spec lives on a path the classifier returns exit 11 for (`docs/audit/`) → impact: Stop
- Each task's files live in exactly ONE tree (`C:/users/user/apex` or `C:/Users/User/.claude`), because `codex exec -C <root>` takes a single root → impact: Stop
- `~/.claude/CLAUDE.md` is **out of scope and stays untouched** — no task, table, or permission row names it. Its Git rule still needs the D1 per-task-worktree-commit clarification, but the auto-mode classifier denies every host and build write to that path, so the owner applies it via the staged-file `!` one-liner at session close. ADR-046 D1 Consequences records it as a queued owner action → impact: Low
- **`C:/Users/User/.claude` IS a git working tree** — verified live 2026-07-29: `git -C C:\Users\User\.claude rev-parse HEAD` → `c48dd1e`, and `git -C C:\Users\User\.claude rev-parse --is-inside-work-tree` → `true`. A review claim that this tree is not under git is false; recorded here so it is not re-litigated. (Its `.gitignore` is a blanket `*` — tracked files are added by name with `git add -f` — which is what makes it *look* untracked to a casual check.) → impact: Low

Simplicity check: yes. Two simpler shapes were considered and rejected. (a) *A single "fix everything" task* — 55 files across 10 categories exceeds any one context, and category-shaped tasks collide on shared files (governance alone carries five decisions). (b) *Splitting this into several specs* — rejected because ADR-046, `SKILL-HISTORY.md`, and the governance SKILL would each have to be shared across specs, violating the file-disjointness rule that makes cross-spec parallelism safe (ADR-029); the build is sequential at `risk: high` anyway, so a split buys no wall-clock; and per-file task ownership already delivers split-equivalent isolation. Accepted as one spec, grouped strictly by file ownership. **The template's >3-files split rule is deliberately overridden for this repair sweep (planning decision, this session): the work is one atomic doctrine layer; split specs would share ADR-046, `SKILL-HISTORY.md`, and the governance SKILL, violating ADR-029 disjointness.**

## Prerequisites
- Specs that must be complete first: none
- Environment setup required: none (pure Markdown + one `.js` comment header; no build step in this repo)

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| C:/users/user/apex/docs/technical/adr/ADR-046-doctrine-audit-resolutions.md | create | Records D1–D8: decision, options considered, ratification date, pointer to the audit dir |
| C:/users/user/apex/docs/technical/adr/ADR-045-four-role-split.md | modify | D1 amendment section (dated, cites Sol run `0e7d2938`) + ADR-046 backlink |
| C:/users/user/apex/docs/technical/adr/ADR-027-codex-primary-opus-fallback-deepseek-archived.md | modify | Amended-by-ADR-045 fallback banner (Sonnet 5, not Opus) + ADR-046 pointer |
| C:/users/user/apex/docs/technical/adr/ADR-028-parallel-codex-dispatch.md | modify | Same banner + cap caveat: default 2 (A2), formula value 3 documented for reference |
| C:/users/user/apex/docs/technical/adr/ADR-029-cross-spec-parallel-build.md | modify | Same banner + same cap caveat |
| C:/users/user/apex/docs/technical/adr/ADR-034-sol-default-coder.md | modify | Same amended-fallback banner only — body prose stays historical (ADR-mutation convention, Task 2) |
| C:/users/user/apex/docs/technical/adr/ADR-036-remove-knowledge-layer.md | modify | Same banner (line 19 "Opus as fallback") |
| C:/users/user/apex/docs/technical/adr/ADR-037-three-context-files.md | modify | Resolve "Codex never reads status.md" vs decision-table "Both (provider-agnostic)" |
| C:/users/user/apex/docs/technical/adr/ADR-038-single-session.md | modify | Same banner (line 51 "Opus as the fallback coder") |
| C:/users/user/apex/docs/technical/adr/ADR-042-critical-file-confirmation-and-achievable-cross-family.md | modify | Same banner (Opus-fallback-build framing) |
| C:/users/user/apex/docs/technical/adr/ADR-030-codex-reasoning-effort-dial.md | modify | Same amended-fallback banner (Opus presented as active fallback) |
| C:/users/user/apex/docs/technical/adr/ADR-031-codex-context-propagation.md | modify | Same amended-fallback banner |
| C:/users/user/apex/docs/technical/adr/ADR-032-gpt56-role-split.md | modify | Same amended-fallback banner |
| C:/users/user/apex/docs/research/artemis-retro-2026-07-29.md | modify | P1 premise note ×2: "Opus-fallback-only by design" → Sonnet 5 (cat 1) |
| C:/users/user/apex/ROADMAP.md | modify | Roles bullet ×2: "Sonnet orchestrates builds" → Opus 5; "(Opus fallback)" → Sonnet 5 (cat 1) |
| C:/users/user/apex/docs/technical/architecture/overview.md | modify | Role list + decision-table row: Opus 5 orchestrator, Sonnet 5 fallback; three host-role D1 annotations |
| C:/users/user/apex/docs/technical/pin-change-sweep.md | modify | Step-4 ADR rule reconciled to the amendment convention (ADR-046) |
| C:/users/user/apex/AGENTS.md | modify | Heading schema → Tasks/fence + Files to Change casing |
| C:/users/user/apex/SKILL-HISTORY.md | modify | One prepended row per meaningfully-updated skill |
| C:/users/user/apex/SKILLS.md | modify | Unconditional: "(Opus on fallback)" → Sonnet 5. Plus description updates if any changed. |
| C:/Users/User/.claude/skills/apex-governance/SKILL.md | modify | Heading carve-out clause; D2 + D3 + D4 + D5 + D6 + D8; sources gain ADR-045/046; version bump |
| C:/Users/User/.claude/skills/apex-governance/levels/L3.md | modify | Pipeline line reworded to ADR-045 roles; deletion line gains the D7 carve-out |
| C:/Users/User/.claude/skills/apex-governance/levels/L4.md | modify | Forbidden list: merge + file/branch deletion gain D2/D7/D8 pointers |
| C:/Users/User/.claude/skills/apex-governance/levels/L5.md | modify | Forbidden list: PR merge + branch deletion gain D2/D8 pointers |
| C:/Users/User/.claude/skills/apex-orchestrate/SKILL.md | modify | Routing table gains the two dispatch steps; sources gain ADR-045/046 |
| C:/Users/User/.claude/skills/apex-orchestrate/templates/spec-template.md | modify | D3 Permissions wording; cap default 2; `coder_model: {codex|sonnet}` |
| C:/Users/User/.claude/skills/apex-orchestrate/templates/status-template.md | modify | Model-routing pointer → hook file; cap default note |
| C:/Users/User/.claude/skills/apex-orchestrate/templates/AGENTS-template.md | modify | Heading schema → Tasks/fence; verify owner; ADR-029 queue rule |
| C:/Users/User/.claude/skills/apex-code/SKILL.md | modify | Cat 1 + 5 + 7 + 8 + 10 fixes; version bump |
| C:/Users/User/.claude/skills/apex-code/references/parallel-codex.md | modify | D8 teardown carve-out; wrapper-mandatory rewrite of the raw recipe |
| C:/Users/User/.claude/skills/apex-code/references/codex-observability.md | modify | Wrapper-mandatory rewrite; Opus→Sonnet 5 at the ladder tail |
| C:/Users/User/.claude/skills/apex-code/references/codex-review.md | modify | Sonnet-5-built framing; advisory-vs-exit-67 reconciliation |
| C:/Users/User/.claude/skills/apex-code/references/dispatch-pack.md | modify | Fallback rows → Sonnet 5; verify owner+cadence; drop bound-stack ref |
| C:/Users/User/.claude/skills/apex-code/references/workflow-dispatch.md | modify | `model` enum `opus` → `sonnet`; Claude-fallback-only framing; single-task dispatch |
| C:/Users/User/.claude/skills/apex-code/references/permissions.md | modify | D3/D4 allow-list mirroring limits; D5 audit-log doctrine-vs-enforcement note |
| C:/Users/User/.claude/skills/apex-plan/SKILL.md | modify | `coder_model: {codex|sonnet}` enum |
| C:/Users/User/.claude/skills/apex-plan/references/model-routing.md | modify | Self-contradiction fixes at ~8-11, 57-64, 94; enum |
| C:/Users/User/.claude/skills/apex-plan/references/sol-plan-check.md | modify | Planning-host label "Opus" → "the host" (lines ~27, ~49) |
| C:/Users/User/.claude/skills/apex-plan/references/design-workflow.md | modify | Three dangling `[[memory]]` links; "Opus on fallback" |
| C:/Users/User/.claude/skills/apex-plan/references/cheap-mockup-workflow.md | modify | Moved-content claim → design-workflow.md |
| C:/Users/User/.claude/skills/apex-plan/references/design-lane-workflow.md | modify | Moved-content claim → design-workflow.md |
| C:/Users/User/.claude/skills/apex-research/SKILL.md | modify | "(Opus)" → "(the host)"; dangling `[[memory]]` link; D4 pointer |
| C:/Users/User/.claude/skills/apex-init/SKILL.md | modify | "Mode: planning" banner removed |
| C:/Users/User/.claude/skills/apex-handoff/SKILL.md | modify | WIP-commit gate: no exception (rejected carve-out, ADR-046 D6); completed-state row fix |
| C:/Users/User/.claude/skills/apex-stack/SKILL.md | modify | impl.md / ADR-template pointers → adr-and-status-procedures.md |
| C:/Users/User/.claude/skills/apex-context-budget/SKILL.md | modify | ADR-036-era bound-stack references |
| C:/Users/User/.claude/skills/apex-coding-principles/SKILL.md | modify | Frontmatter only — version patch bump + last_updated (owns the elaboration.md edit) |
| C:/Users/User/.claude/skills/apex-coding-principles/references/elaboration.md | modify | "domain impl.md files" tail line |
| C:/Users/User/.claude/skills/apex-skill-author/SKILL.md | modify | Frontmatter only — version patch bump + last_updated (owns the projection edit) |
| C:/Users/User/.claude/skills/apex-skill-author/references/agents-skills-projection.md | modify | Projection-source self-contradiction; recipe-home row |
| C:/Users/User/.claude/agents/code-worker.md | modify | D7 — spec-authorized deletes |
| C:/Users/User/.claude/agents/apex-docs-product-agent.md | modify | `## Scope` pointer → `## Intent` |
| C:/Users/User/.claude/agents/apex-docs-technical-agent.md | modify | D6 carve-out + four-section handoff contract rewrite |
| C:/Users/User/.claude/agents/apex-reviewer.md | modify | Opus-built → Sonnet-5-built fallback framing |
| C:/Users/User/.claude/agents/apex-coder.md | modify | Relabelled Claude-fallback-only |
| C:/Users/User/.claude/hooks/apex-session-context.md | verify only | **Pre-executed attended 2026-07-29** (reconciling clause + D1 tightening + Opus-orchestrator row already live). Build reads and checks; writes nothing. |
| C:/Users/User/.claude/workflows/apex-build-wave.js | modify | Header comment: Sonnet 5 fallback, no `APEX_MODE` |

## Tasks

<!-- Path convention for every done-when check: a task runs with its own tree as `-C` root, so
     `Select-String -Path` arguments are written RELATIVE TO THAT ROOT — `agents/<file>.md`,
     `skills/<skill>/SKILL.md`, `skills/<skill>/references/<file>.md`, `hooks/<file>.md`,
     `workflows/<file>.js` for the `~/.claude` tree; `docs/...`, `AGENTS.md`, `SKILL-HISTORY.md`,
     `SKILLS.md`, `ROADMAP.md` for the apex tree. Bare basenames are not runnable. -->

- [ ] **Task 1: Write ADR-046 recording D1–D8** — files: `C:/users/user/apex/docs/technical/adr/ADR-046-doctrine-audit-resolutions.md` (create).
  Mechanism: follow the ADR-045 file shape exactly — `# ADR-046: <title>` H1, then `**Date:** 2026-07-29`, `**Status:** Accepted`, `**Related:** [ADR-045](./ADR-045-four-role-split.md), [ADR-023](./ADR-023-pre-authorise-before-dispatch.md), [ADR-028](./ADR-028-parallel-codex-dispatch.md), [ADR-029](./ADR-029-cross-spec-parallel-build.md), [ADR-042](./ADR-042-critical-file-confirmation-and-achievable-cross-family.md)`, then `## Context`, `## Decision`, `## Consequences` (Good / Bad-accepted / Neutral).
  `## Context` (≤12 lines): four independent reviewers over the full APEX document surface, ~55 deduped findings; root disease = ratification sweeps that stop at the first file, plus schema drift between contracts and consumers. Point at `docs/research/doctrine-audit-2026-07-29/README.md` + `sol-findings.json` (Sol run `fe86b30c`, tree `674fc122fafb`).
  `## Decision`: one `###` subsection per decision, D1–D8, each with **Conflict** (the two texts that disagree), **Options considered**, **Decided** (verbatim outcome below), **Ratified** 2026-07-29.
  **Options-considered rule — do not invent alternatives.** For D6, D7, and D8 the audit's Options column names explicit alternatives; use those. For D1–D5 it does not: derive the two options directly from the Conflict column itself (reading A vs reading B — i.e. "hold text X and amend text Y" vs "hold text Y and amend text X"), then add the sentence `The audit catalogued no further alternatives.` **Never manufacture a third option.**
  Decision text to record verbatim:
  - **D1** — host mechanics = launching/monitoring background subprocesses STRICTLY from the orchestrator's wave plan + returning status/exit codes; task selection, sequencing, routing, verification, retries, and close-out are exclusively orchestrator-owned. Resolved by Sol deliberation run `0e7d2938` (ACCEPTED option A, with the above tightening). Amendment text lands in ADR-045.
    **Verification-ownership split — this exact sentence is reused VERBATIM, as a standalone sentence, everywhere a verify owner is named** (Tasks 7, 10, 12, 17; each of those tasks asserts the full sentence in its done-when, so adjust surrounding grammar to fit the sentence rather than bending the sentence): `The host EXECUTES the recipe as mechanics from the orchestrator's wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows.` The coder never adjudicates its own output (evaluator independence) and the host never adjudicates either.
    **What "host mechanics" INCLUDES — record in D1 Consequences, and reuse wherever the tension appears (Tasks 7, 10, 17):** the host also **executes git operations exactly as directed** — the per-task worktree commit and the path-scoped integration, both taken from the orchestrator's wave plan, and the per-spec commit once the user has approved the drafted message. Those are **executions, not decisions**. The excluded set is unchanged: task selection, sequencing, routing, verify adjudication, retries, and close-out decisions are the orchestrator's. The draft → show → approve → commit exchange is host↔user by nature and stays host-side. **Builders still never commit** — the AGENTS contracts' no-commit rule binds the coder, not the host, and is consistent with this.
    **Which commits the approval gate governs — record this too.** Per-task commits onto transient `codex/<spec>-<task-id>` branches inside isolated worktrees are **build mechanics** under the orchestrator's plan: those branches are throwaway and are torn down post-integration, so they carry no reviewable history. The draft → show → approve → commit gate governs **integration-branch commits** — the per-spec, session-end commits — not worktree task-branch commits.
    **Queued owner action — record in D1 Consequences.** `~/.claude/CLAUDE.md`'s Git rule ("Commit per-spec when a spec completes", with an unconditional draft → show → approve gate) needs the same clarification: the gate governs integration-branch commits, not per-task worktree commits. **This spec does not make that edit** — the classifier blocks every host and build write to that file, so it is **queued as an owner action**, applied via the staged-file `!` one-liner at session close. Record it as an open reconciliation, not as done.
    **INTERIM-EXECUTOR clause — record in D1 Consequences.** Until the build-orchestrator agent contract ships (the queued retro P1–P7 spec set), **the HOST performs the scheduling, routing, and adjudication duties as interim executor.** This is a **recorded transition state, not doctrine**: D1's ownership assignment is the *target* that the P1–P7 set implements. Every document that currently instructs the host to analyze dependencies, choose waves, or route completions is describing the interim state and must say so. **The Claude-fallback path is not a competing owner:** when `apex-coder` groups waves and spawns workers it does so **as a dispatched executor under this same interim arrangement** — the scheduling doctrine is unchanged by which path executes it.
    **Scope note for D1 Consequences — record explicitly:** the build-orchestrator **agent contract** (its prompt, its inputs/outputs, its resume/status loop) is carried by the **queued retro P1–P7 spec set, not by this sweep**. This spec only makes the existing documents agree on who owns what.
  - **D2** — governance gets a carve-out mirroring the `~/.claude/CLAUDE.md` 2026-07-23 owner amendment: merging a named PR is allowed only on explicit approval in a genuine live user message this session that names the specific PR(s). The blanket "git merge permanently forbidden" wording is reconciled to it, not deleted. **This is DOCTRINE-level authorization, not a mechanical bypass:** `~/.claude/hooks/lib/destructive-detect.js` still **intercepts** `git merge` (denying it or requiring confirmation per its own rules); the carve-out says an approved named-PR merge is *permitted*, not that the guard will wave it through.
  - **D3** — a spec's `## Permissions` pre-authorizes NON-critical actions only. Critical paths always require live attended confirmation; AFK parks them. **D6 is the SOLE named exception to this rule**, scoped to exactly three artifacts (see D6). No other unattended critical-path write exists anywhere in APEX. The D3 and D6 subsections must cross-reference each other explicitly.
  - **D4** — user-approved WebFetch domain allows during attended planning (the ADR-023 flow) are NOT self-widening. Background/AFK never edits permissions.
  - **D5** — `docs/audit/`: as **doctrine**, append-only writes by the run's own audit step are **required by doctrine; the enforcement change is pending — until it ships, appends route through the host.** Editing or deleting an existing entry stays permanently forbidden. **Do not write the phrase "required and allowed" anywhere** — that framing claims a live agent permission that does not exist, and the acceptance check forbids it. **Enforcement gap — record it explicitly:** the live classifier `~/.claude/skills/apex-code/scripts/apex-critical-files.ps1` refuses **any** `docs/audit/` path on a path match alone (`'(^|/)docs/audit(/|$)'` → `HARDBLOCK … : audit`, exit 11) with no append-vs-edit distinction. So until a content-aware script change ships, **all** `docs/audit/` writes are blocked in practice, including the run's own appends, and L4+ audit appends route through the host. That script change is a **named follow-up and is NOT in this spec** (this spec changes no script).
  - **D6** — the docs agents are KEPT with an AFK carve-out: they act as the host's pen, and the host reviews their output before session close. Not retired to the host. **This is the sole named exception to D3's host-state critical list, and it is scoped to exactly three artifacts:** (1) the handoff doc, (2) `docs/status.md`, (3) spec archival into `docs/changes/done/`. Nothing else. **Scope limit:** the carve-out covers those three document writes ONLY. It does not touch the commit approval gate, and it grants no other unattended critical-path write.
    **Interim mechanics — record in D6 Consequences.** Under AFK the harness may silently deny a docs-agent's off-list write (`dontAsk` inheritance). Until the permissions follow-up ships (queued retro set), **the HOST performs the three artifacts' writes itself** — they are host bookkeeping (state-keeping) under the session licence clause, so no gate is crossed. The docs agents are the host's pen whenever the harness permits; the host is always a valid writer of its own three artifacts.
  - **D7** — spec-authorized deletes ARE allowed for code-workers: a delete listed in the spec's `## Files to Change` with `Operation: delete` is pre-authorized, on non-critical paths only (per D3).
  - **D8** — scoped teardown allowance: the creator of a worktree/branch may tear it down POST-INTEGRATION, only when **verified integrated**. The governance blanket ban on `git branch -d / -D` gains exactly this carve-out and no other.
    **THIS SUBSECTION IS THE SINGLE CANONICAL HOME OF THE D8 VERIFICATION ALGORITHM.** No other file restates it — Tasks 3 and 7 carry one summary sentence and a citation back here. Write it exactly as follows.
    (a) **WORKTREE REMOVAL requires `git status --porcelain` empty in that worktree.** No alternative, no per-file byte-identity substitute. A scope violation (exit 65) can leave unauthorized writes sitting in the tree, and those may be the only copy. **Remove with `git worktree remove <path>` — WITHOUT `--force`.** Git re-checks for uncommitted content at execution time, so dropping the flag turns the porcelain check into a belt-and-braces pair rather than a single fallible gate. A dirty worktree is surfaced and left alone, never force-removed.
    (b) **BRANCH DELETION additionally requires** the branch's path-scoped diff against the integration branch to be empty: `git diff <branch>..<integration> -- <files>`. **Because integration commits land only after the user approves the per-spec commit, branch deletion NECESSARILY WAITS until that commit has landed.** Worktree removal may precede it, once (a) holds.
    **Deleted files (D7 interop):** a file whose spec Operation is `delete` counts as integrated when it is **ABSENT from both** trees; never run a content comparison against an absent path.
    **Ancestry checks are NOT valid evidence** — integration is path-scoped `git checkout <branch> -- <files>`, never `git merge`, so `git branch --merged` and `git merge-base --is-ancestor` false-negative on correctly-integrated branches.
    **Also DOCTRINE-level, not a mechanical bypass:** `~/.claude/hooks/lib/destructive-detect.js` intercepts `git branch -d/-D` (denying or requiring confirmation per its rules), and intercepts the path-scoped `git checkout <branch> -- <files>` integration form as well. The scoped mechanical allowance is the **queued retro P5(c) hook change, which is out of this spec's scope**; until it ships, a permitted teardown executes via the user's `!` one-liner handback. Record this in the D2 and D8 Consequences.
  `## Consequences` must state:
  - D2/D4/D5/D8 are carve-outs on the hard-block list (scoped, not removals), and D3 is the reconciling rule that makes spec pre-authorisation and the critical-file gate compatible.
  - **D5's doctrine currently outruns its enforcement** (the classifier gap above) — named as a known, tracked follow-up rather than a silent inconsistency.
  - **D6's scope was tested and held:** category 10's alternative of extending the AFK carve-out to cover **WIP commits on pause** was **considered and REJECTED**. D6 authorizes docs-agent *document* writes, not git commits. The commit approval gate (draft → show → approve → commit) stands at every level, attended or not; an unattended run queues the drafted message instead of committing.
  Done when: `Select-String -Path "C:/users/user/apex/docs/technical/adr/ADR-046-doctrine-audit-resolutions.md" -Pattern '### D1','### D2','### D3','### D4','### D5','### D6','### D7','### D8','0e7d2938','doctrine-audit-2026-07-29','apex-critical-files.ps1','merge-base','REJECTED'` returns a match for every pattern.

- [ ] **Task 2: Append the D1 amendment to ADR-045 and fix its banner/backlinks** — files: `C:/users/user/apex/docs/technical/adr/ADR-045-four-role-split.md` (modify). **This task is the sole owner of ADR-045; no other task edits it.**
  **ADR-mutation convention — stated once here, reused by Task 14.** (i) An amendment **appends a dated section**; it never rewrites the original reasoning. (ii) An in-place edit is permitted to **Decision-table cells AND decision-list lines alike**, but ONLY with the **historical value adjacent** — either the A1 form `as drafted this row said X`, or the inline form `X at ship time; live value Y — see amendment`. (iii) Apart from those keyed edits, an older ADR's **body prose stays historical** behind its banner; banners point forward, bodies are not rewritten. (ADR-028/029's cap-default line edits in Task 14 already take form (ii)'s inline variant — they are convention-compliant, not exceptions.)
  Mechanism:
  1. Append a new section at end of file:
     `## Amendment — 2026-07-29: build-dispatch ownership (D1)` with body stating: the **Build orchestrator** row owns task selection, sequencing, routing, verification adjudication, retries, and close-out, exclusively. The **host's** role in a build is *mechanics only*, and the mechanics set is the **clarified** one (keep it aligned with ADR-046 D1 and the live session-context hook, which already carries this wording): launching and monitoring background subprocesses **strictly from the orchestrator's wave plan**; **executing the verify recipe, the per-task worktree commits, the path-scoped integration, and the user-approved per-spec commit exactly as directed**; and returning status and exit codes. The host never chooses which task runs, never re-routes a failure, and never adjudicates a verify result. **Interim state, stated here too:** until the orchestrator's agent contract ships (queued retro P1–P7 set), the host performs those ownership duties as **interim executor** — a recorded transition, not doctrine. `references/parallel-codex.md`'s "the host runs them as concurrent subprocesses" describes exactly that mechanic and is not a competing dispatcher. Cite: *Ratified 2026-07-29; Sol deliberation run `0e7d2938` (option A accepted, with this tightening). Recorded in [ADR-046](./ADR-046-doctrine-audit-resolutions.md).*
  2. In the header block, add `**Amended:** 2026-07-29 — see [ADR-046](./ADR-046-doctrine-audit-resolutions.md) (D1)` on its own line after `**Status:** Accepted`.
  3. Category-1 banner check on this file only: the Coder row (line ~33) already reads "Falls back to a fresh `model: sonnet` worker (Sonnet 5)". Leave that text; append `— see [ADR-046](./ADR-046-doctrine-audit-resolutions.md)` to its parenthetical so the backlink exists here too. **Do not alter the fallback coder anywhere — it stays Sonnet 5.**
  4. **Second amendment section — the owner's orchestrator-model decision.** Append after the D1 amendment: `## Amendment — 2026-07-29: build orchestrator model (owner decision)` with body: the **Build orchestrator** row changes from a `model: sonnet` worker to **Opus 5** — a `model: opus` worker — decided by the owner in a live attended exchange on 2026-07-29. **Across the board**, not risk-gated: every build wave is orchestrated by Opus 5, not only high-risk ones. **Acknowledged trade-off, accepted by the owner:** orchestration now spends the capped Anthropic weekly pool at Opus rates rather than Sonnet rates; the pool-economics argument that originally put a Sonnet worker in this role is knowingly set aside in favour of stronger wave-level judgment. **The fallback CODER is unaffected** — it remains Sonnet 5 (A1, session-79b); this amendment touches the orchestrator role only. Amend the Decision table's Build orchestrator row in place to `| **Build orchestrator** | a \`model: opus\` worker (Opus 5) | Runs build waves, dispatches coders, routes exit codes. Owner amendment 2026-07-29; as drafted this row said Sonnet. |`
  Done-when addition for this task: the file contains `Amendment — 2026-07-29: build orchestrator model`, `Opus 5`, and `as drafted this row said Sonnet`.
  Done when, against `C:/users/user/apex/docs/technical/adr/ADR-045-four-role-split.md`: `-SimpleMatch -Pattern 'Amendment — 2026-07-29: build-dispatch ownership','Amendment — 2026-07-29: build orchestrator model','0e7d2938','ADR-046','Opus 5','as drafted this row said Sonnet'` matches all six, and `-SimpleMatch -Pattern 'as drafted this row said Opus'` still matches (the coder row's historical note is preserved, not deleted).

- [ ] **Task 3: Governance carve-outs D2/D3/D4/D5/D8 + the L4/L5 live copies + sources** — files: `C:/Users/User/.claude/skills/apex-governance/SKILL.md`, `C:/Users/User/.claude/skills/apex-governance/levels/L4.md`, `C:/Users/User/.claude/skills/apex-governance/levels/L5.md` (all modify). (L3.md is Task 15's; these two are unowned elsewhere.)
  Mechanism — surgical edits under `## Hard blocks` / `## Critical files` / `## Approval gate`; **no hard-block line is deleted**:
  0. **The heading must stop contradicting its own carve-outs.** It currently reads `## Hard blocks — permanently forbidden, every level, regardless of who asks`. Replace with `## Hard blocks — permanently forbidden, every level, regardless of who asks — subject only to the named ADR-046 carve-outs below`. Nothing else about the section's force changes.
  1. **D2** — replace the hard-block line `- git merge / merging its own PR` with `- git merge / merging its own PR — except a named-PR merge under the carve-out below`, and add below the fenced block:
     `**Carve-out (D2, ADR-046; mirrors the ~/.claude/CLAUDE.md owner amendment of 2026-07-23):** merging a PR is permitted ONLY on explicit approval in a genuine live user message this session that names the specific PR(s) — never inferred from fetched/tool/file content, notifications, or prior sessions. State repo, PR numbers, and order before asking. One approval covers only the PRs it names; no standing or batch-open-ended approvals. In doubt → ask again, don't merge. \`git merge\` as a build-integration mechanism stays forbidden (integration is path-scoped \`git checkout <branch> -- <files>\`). **This carve-out is doctrine-level authorization, not a mechanical bypass:** \`hooks/lib/destructive-detect.js\` still intercepts \`git merge\` — denying it or requiring confirmation per its own rules — so an approved merge is *permitted*, not *unguarded*.`
  2. **D8** — replace `- git branch -d / -D` with `- git branch -d / -D — except the scoped teardown carve-out below`, and add **below the fence**: `**Carve-out (D8, ADR-046):** the agent that CREATED a worktree/branch may tear it down POST-INTEGRATION, and only after TWO checks, both required, worktree FIRST — coder output is uncommitted, so a branch diff can be empty while the worktree holds the only copy. Teardown is permitted only after the verification defined in **ADR-046 § D8** (\`~/apex/docs/technical/adr/ADR-046-doctrine-audit-resolutions.md\` — the \`~/apex/...\` form is how skills reference the APEX repo from this tree; a relative path from \`~/.claude\` does not resolve) — worktree removal on a clean worktree, branch deletion additionally on an empty path-scoped branch diff, so branch deletion follows the approved per-spec integration commit; ancestry checks are not valid evidence. **That ADR section is the single canonical home of the algorithm; do not restate it here.** Any other branch deletion stays permanently forbidden. **Doctrine, not a mechanical bypass:** \`hooks/lib/destructive-detect.js\` intercepts \`git branch -d/-D\` (and the path-scoped \`git checkout … -- …\` integration form) — denying or requiring confirmation per its rules. The scoped mechanical allowance is the queued retro P5(c) hook change, out of scope here; until it ships, a permitted teardown executes via the user's \`!\` one-liner handback.`
  3. **D5** — replace `- Any modification to docs/audit/` with `- Any modification to existing docs/audit/ entries (editing or deleting a written entry)`, and add: `**Carve-out (D5, ADR-046) — doctrine, ahead of enforcement.** The doctrine: append-only writes by the run's own audit step are what L4+ § Logging requires; the **enforcement change is pending**, and until it ships those appends route through the host. editing or deleting an existing entry stays permanently forbidden. **In practice today the block still applies to appends too:** \`apex-critical-files.ps1\` refuses every \`docs/audit/\` path on a path match alone (exit 11), with no append-vs-edit distinction, so until a content-aware script change ships, an agent does NOT write to \`docs/audit/\` at all — L4+ audit appends route through the host. Do not treat this carve-out as live agent permission.` Then in `## Critical files`, amend the sentence beginning `It has **two tiers**: the` so the TIER-1 description reads `the docs/audit/ entry listed above is TIER-1 — refused outright by path match and never confirmable by any switch, attended or not; D5's append-only exception is doctrine pending a content-aware classifier change;`.
  3b. **D6** — immediately after the D3 clause added in item 5 below, add: `**Exception (D6, ADR-046) — the host's pen.** During AFK, the docs agents' writes to exactly three artifacts — the handoff doc, \`docs/status.md\`, and spec archival into \`docs/changes/done/\` — are performed by the agents and REVIEWED BY THE HOST before session close; they are host state-keeping executed by a worker, not the worker taking host authority (ADR-045). **This is the sole exception to the rule above, and it extends to nothing else.** It does **not** touch the commit approval gate — no agent commits without the draft → show → approve exchange, at any level. **Interim mechanics:** under AFK the harness may silently deny a docs-agent's off-list write (\`dontAsk\` inheritance); until the permissions follow-up ships (queued retro set), the **HOST performs the three artifacts' writes itself** — they are host bookkeeping (state-keeping) under the session licence clause, so no gate is crossed. The docs agents are the host's pen whenever the harness permits; the host is always a valid writer of its own three artifacts.`
  4. **D4** — the carve-out prose goes **BELOW the fenced hard-block list, alongside the other carve-outs — never inside the fence.** Key it to its bullet by amending the fenced line `- ANY action that disables, bypasses, or widens its own controls` to `- ANY action that disables, bypasses, or widens its own controls — except the attended-planning carve-out below`, then add below the fence: `**Carve-out (D4, ADR-046):** adding a \`WebFetch(domain:<host>)\` entry to \`permissions.allow\` during ATTENDED planning, for a domain the user approved, under the ADR-023 pre-authorise-before-dispatch flow, is not self-widening. A background or AFK run NEVER edits permissions — no exception.` (Same placement rule applies to the D2, D5, and D8 carve-outs in items 1–3: fence carries only the keyed bullet text; prose sits below.)
  5. **D3** — in `## Approval gate`, replace the sentence `Everything listed is pre-authorised for the run; anything not listed is **blocked and logged, never executed**.` with `Everything listed that is **non-critical** is pre-authorised for the run; anything not listed is **blocked and logged, never executed**. **A spec cannot pre-authorise a critical path (D3, ADR-046)** — a listed critical action still needs a live attended confirmation, and an unattended/AFK run **parks** it. This is the reconciling rule for "an authorising spec does not settle it" above. Sole exception: the docs agents' three host's-pen artifacts — D6, below.`
  5d. **Commit-exchange scope, in all three governance files.** In `SKILL.md` the commit-discipline paragraph (~line 63) reads `**Commit discipline:** the levels govern *autonomous* commits. The per-spec workflow (prompt → draft message → user approves → commit) is a *user-approved* action, permitted at **every** level L2+. "No commits" at L2/L3 means: never without that exchange.` Append: ` **Which commits (ADR-046 D1):** the exchange governs **integration-branch** commits — the per-spec ones. Transient \`codex/<spec>-<task-id>\` worktree commits made during a parallel build are **build mechanics** under the wave plan: those branches are throwaway and torn down post-integration, so they carry no reviewable history and need no exchange.` Add the same clarification to `L4.md`'s allowed line `- git commit with drafted message — user approves message before commit executes` (append ` — integration-branch commits; transient worktree task-branch commits are build mechanics, ADR-046 D1`) and to its `## Approval gate` block as a one-line note under `Commit message approval:`.
  5f. **D5 producer restriction on the L4/L5 audit lines.** Both files carry an identical `## Audit` section whose body reads `Full session audit log required: docs/audit/YYYY-MM-DD.log`. Append to each: ` **Who writes it (D5, ADR-046):** append-only is the sanctioned mode and editing or deleting an existing entry is permanently forbidden — but the live classifier refuses every \`docs/audit/\` path on a path match alone, so **the agent does not write this file**. Until the classifier follow-up ships, these appends route through the host.`
  5e. **L5 heading carve-out acknowledgement.** `L5.md`'s heading reads `## Forbidden (hard blocks — cannot be overridden)`. Replace with `## Forbidden (hard blocks — cannot be overridden) — subject only to the named ADR-046 carve-outs below`, matching the main governance heading treatment.
  5b. **Cat 1 coverage inside this file** — line ~164 currently reads `- **Opus built** (the fallback) → **Codex** reviews, headless and read-only.` Replace with `- **Claude-fallback built** (Sonnet 5 — A1/ADR-045) → **Codex** reviews, headless and read-only.` Also amend line ~166's `Codex quota-out leads Opus to build` → `Codex quota-out leads the Claude fallback to build`, and line ~175's `usually Codex quota is out, which is *why* Opus was building` → `usually Codex quota is out, which is *why* the Claude fallback was building`. Leave lines ~40, ~156, and ~162 (the AFK end-gate and the high-risk reviewer) — those are deliberate Opus roles.
  5c. **The live level files repeat the blocks and must carry the same pointers** (a carve-out recorded only in SKILL.md leaves L4/L5 contradicting it).
    `levels/L4.md`, `## Forbidden` list — `- git merge` → `- git merge — except the named-PR carve-out (D2, ADR-046; apex-governance § Hard blocks)`; `- Deleting files or git branches` → `- Deleting files or git branches — except a spec-listed \`Operation: delete\` on a non-critical path (D7, ADR-046) and post-integration teardown of a branch you created (D8, ADR-046 § D8); see apex-governance § Hard blocks`. **Both L4 lines must cite ADR-046** — the merge line alone is not enough for the ≥2-hits check.
    `levels/L5.md`, `## Forbidden (hard blocks — cannot be overridden)` list — `- Merge any PR` → `- Merge any PR — except a named PR under live user approval this session (D2, ADR-046; apex-governance § Hard blocks)`; `- Delete any branch` → `- Delete any branch — except post-integration teardown of a branch you created, both D8 checks passed (ADR-046; apex-governance § Hard blocks)`. **And the commit clarification, which L5 does not inherit explicitly** — its `## Allowed` list opens `- All L4 actions`; append ` (including the L4 commit gate: it governs **integration-branch** commits; transient \`codex/<spec>-<task-id>\` worktree commits are build mechanics — ADR-046 D1)`. Leave every other line in both files untouched.
  6. Frontmatter (SKILL.md): add `  - docs/technical/adr/ADR-045-four-role-split.md` and `  - docs/technical/adr/ADR-046-doctrine-audit-resolutions.md` to `sources:`; bump `version:` `2.2.1` → `2.3.0`; `last_updated: 2026-07-29`.
  Done when, all seven: (i) `Select-String` on the governance SKILL for `'Carve-out \(D2'`, `'Carve-out \(D4'`, `'Carve-out \(D5'`, `'Carve-out \(D8'`, `'D3, ADR-046'`, `'D6, ADR-046'`, `'apex-critical-files.ps1'`, `'~/apex/docs/technical/adr/ADR-046-doctrine-audit-resolutions.md'` matches all eight. (The D8 algorithm strings are NOT asserted here — ADR-046 is their only home.) (ii) The fenced hard-block list still contains 9 bullet lines. (iii) **Bullet-count alone is insufficient — assert one distinctive substring per original block survives**, in the fence: `'push to main/master'`, `'force-push or history rewrite'`, `'merging its own PR'`, `'DROP TABLE'`, `'git branch -d'`, `'production secrets'`, `'docs/audit/'`, `'widens its own controls'`, `'Deploying to production'`, `'Weakening a security control'` — every one must still match. (iv) `Select-String -Pattern '^- Any modification to docs/audit/$'` returns zero hits, and the four carve-out prose blocks all sit **outside** the fence (no line between the fence delimiters begins `**Carve-out`). (v) The `## Hard blocks` heading contains `subject only to the named ADR-046 carve-outs below`. (vi) `L4.md` and `L5.md` each match `ADR-046` at least twice, and neither still carries a bare `- git merge`, `- Deleting files or git branches`, `- Merge any PR`, or `- Delete any branch` line. (vii) Neither this file nor any file this task touches matches `are required and allowed`.

- [ ] **Task 4: spec-template — D3 wording, cap default, coder_model enum** — files: `C:/Users/User/.claude/skills/apex-orchestrate/templates/spec-template.md` (modify).
  Mechanism:
  1. **D3** — under `## Permissions`, replace the two lines `The following actions will run autonomously during build.` / `Approving this spec approves all of them.` with: `The following NON-CRITICAL actions will run autonomously during build. Approving this spec approves all of them.` plus **two** further lines, kept as separate clauses:
     - `Critical paths — .env · migrations · auth/authz/crypto · CI config · dependency manifests and lockfiles · infra-as-code · secrets/keys/certs · host-state (docs/status.md, root AGENTS.md, root CLAUDE.md, docs/changes/, docs/handoff/, the run ledger) · the permission settings and the hooks — are NEVER pre-authorised by this section. They need a live attended confirmation at build time, and an AFK run parks them (D3, ADR-046; apex-governance is canonical). (Sole exception: the docs agents' three host's-pen artifacts — the handoff, docs/status.md, and spec archival — under D6.)`
     - `docs/audit/ is different and stricter: TIER-1, refused outright on a path match. No confirmation authorises a write there — not attended, not by any switch, not by this section. (D5's append-only exception is doctrine pending a content-aware classifier change; it is not a live permission.)`
  2. **Cat 3** — replace the `coder_model` comment block (lines 9–11) so it reads: `# coder_model: codex        # optional — pin this WHOLE spec to one coder. Enum {codex|sonnet}, full` / `#                              stop. Absent → codex (the default); sonnet pins the whole spec to the` / `#                              Claude fallback coder (Sonnet 5 — A1, session-79b; ADR-045).` — **no \`opus\` escape hatch: nothing in the build path implements one, so do not document it.**
  3. **Cat 2** — the `max_parallel_codex` tail spans **two** comment lines (20-21) with the continuation marker between them: `#                              (ADR-028). 1 = sequential. Absent → status.md default (auto-sized` / `#                              min(4, floor(cores/2)−1), fallback 3). Machine-protection, not a quota cap.` Replace both with `#                              (ADR-028). 1 = sequential. Absent → **2** (A2, session-79b; ADR-028 as` / `#                              amended). Formula min(4, floor(cores/2)−1) documented for reference only.` / `#                              Machine-protection, not a quota cap.`
  4. **Cat 1** — in the `cross_model_review` comment, replace `Codex-built → Opus reviews; Opus-built → Codex reviews` with `Codex-built → Claude reviews; Claude-fallback-built (Sonnet 5) → Codex reviews`. **And line ~8 of the same comment**, which currently reads `#                              Runs via headless \`codex exec\` on any host (ADR-027). Advisory only.` — three things are wrong: reviews are **cross-family** (ADR-032/034), the Claude side runs as an `apex-reviewer` **subagent, not `codex exec`**, and a Codex review's **BLOCK verdict routes exit 67**, which is a hard stop, not advisory. Replace with `#                              Cross-family (ADR-032/034): the Claude side is an \`apex-reviewer\`` / `#                              subagent; the Codex side is headless \`codex exec\`. Findings are` / `#                              advisory, but a Codex BLOCK verdict routes exit 67 — a hard stop.` In the `## Wave plan` comment, **also make the ownership match apex-plan's reworded rule (item 3 of Task 8): the emitted plan is a PROPOSAL — dependencies binding, grouping advisory, final selection and sequencing orchestrator-owned (ADR-046 D1).** Replace `Under ADR-027 the coder is Codex by default for every task (Opus is the manual fallback,` / `handled at build time by apex-code) — emit the normal untagged wave plan; don't tag ▸opus` with `Under ADR-027 as amended (A1/ADR-045) the coder is Codex by default for every task (Sonnet 5 is the` / `fallback, reached only via the three fallback triggers and handled at build time by apex-code) — emit` / `the normal untagged wave plan; don't tag ▸sonnet`. **Do not write "manual fallback"** — trigger 3 (terminal verify-failure routing) is automatic, so "manual" contradicts the canonical trigger list.
  Done when, against `C:/Users/User/.claude/skills/apex-orchestrate/templates/spec-template.md`: `-Pattern 'Opus','opus'` returns **zero** hits — the enum is `{codex|sonnet}` with no exception clause, so no casing of the word survives anywhere in the file; and `-SimpleMatch -Pattern 'codex|sonnet','Absent → **2**','NEVER pre-authorised','TIER-1, refused outright','apex-reviewer','exit 67'` matches all six.

- [ ] **Task 5: code-worker D7 + docs-product-agent scope pointer** — files: `C:/Users/User/.claude/agents/code-worker.md`, `C:/Users/User/.claude/agents/apex-docs-product-agent.md` (both modify).
  Mechanism:
  - `code-worker.md`, **stale verify contract** (~line 40): Step 3 currently reads `Run each command listed in the spec's ## Commands section that applies to your task.` No such spec section exists — the recipe's single home is AGENTS.md (ADR-037). Replace with `Run the repo's \`AGENTS.md\` → \`## Verify commands\` recipe (its single home, ADR-037) for the parts that apply to your task. If the spec's \`## Permissions\` → Commands table lists additional exact commands, run those too.`
  - `code-worker.md`: replace the conservative-choice bullet `- Never delete anything — log a flag instead` with `- Delete a file ONLY when the spec's \`## Files to Change\` lists it with \`Operation: delete\` and its path is non-critical (D7, ADR-046). Any other deletion: don't — log a flag instead.` Leave the `## Hard blocks` list intact (it blocks *branch* deletion, not file deletion).
  - `apex-docs-product-agent.md`: in Step 3, replace `Read the spec's ## Scope section.` with `Read the spec's \`## Intent\` block (intent / invariants / non-goals) — the current spec template carries no Scope section.` **The replacement must not restate the retired heading**, or Task 5's own zero-hit check can never pass. Additionally, in Step 2, add after the CHANGELOG instruction: `**Scope: the spec's \`## Files to Change\` and nothing else.** Add inline documentation ONLY to files listed there. If CHANGELOG.md or README.md is not listed, record the intended edit in your return summary and skip the write — the scope lock is whole-build (apex-code § Pre-flight). The same applies to any other unlisted file, **including workflow \`.js\` exports** such as \`apex-build-wave.js\`'s \`meta\` block: unlisted means \`skipped_off_scope\`, never a write.` and add **two** fields to the Step 4 return shape: `"status": "completed | completed_with_skips | failed"` and `"skipped_off_scope": ["paths not in the spec's Files to Change"]`. The `status` field is what the technical docs agent's report consumes.
  Done when: `Select-String -Path agents/code-worker.md -Pattern 'Never delete anything'` returns zero hits and `-Pattern 'Operation: delete'` matches; `Select-String -Path agents/apex-docs-product-agent.md -Pattern '## Scope'` returns zero hits and `-Pattern 'skipped_off_scope'` matches.

- [ ] **Task 6: apex-docs-technical-agent — D6 carve-out + handoff-contract rewrite** — files: `C:/Users/User/.claude/agents/apex-docs-technical-agent.md` (modify).
  Mechanism:
  1. After the opening line `You are the apex-docs-technical-agent...`, insert the D6 clause: `**Role boundary (D6, ADR-046).** Handoff, \`docs/status.md\`, and spec archival are host-owned state-keeping (ADR-045). You act as the **host's pen**: you draft these artifacts as the final build step, and the host reviews your output before the session closes. You never decide what state is — you record what the build reported.`
  2. `## Inputs`: add `- docs_product_summary: output from apex-docs-product-agent (inline docs / CHANGELOG / README status)` so the declared inputs match Step 2's requirement. **And generalize the build-summary source** — line ~14 currently reads `- coder_summary: output from apex-coder (files changed, decisions, blocked actions)`, which names a fallback-only agent as if it were the universal producer. Replace with `- coder_summary: the build path's own summary (files changed, decisions, blocked actions). On the default Codex path **the host, as interim executor (ADR-046 D1), assembles it from the wrapper's \`.final\` completion reports**, composition — **two separate inputs, do not conflate them.** \`coder_summary\` is built from the wrapper's \`.final\` fields only: \`deviations\` → its \`decisions\`; \`blocker\` → its \`blocked_actions\`; \`unresolved\` carried through as its own list. \`reviewer_findings\` is **not** a wrapper field — it arrives separately, as this agent's other declared input from \`apex-reviewer\`. The handoff sections then draw as follows: **Decisions Made** ← \`coder_summary.decisions\`; **Blocked Actions** ← \`coder_summary.blocked_actions\`; **Specialist Flags** ← \`reviewer_findings\` ∪ \`coder_summary.unresolved\` (de-duplicated — the reviewer's findings and the coder's own open questions are different evidence). There is no Files Changed section in the handoff, so \`changed_files\` maps to nothing — do not carry it. **Do NOT ingest \`<final>.concerns.md\` anywhere** — the wrapper writes that file from exactly those three fields (\`blocker\` + \`unresolved\` + \`deviations\`), so reading it as well duplicates every entry. Any field the wrapper schema does not carry is filled \`none\` — never invented. \`apex-coder\` produces this summary only on the Claude fallback path.`
  3. Step 2 — replace the **nine**-bullet fill list (What Was Built · Specs Completed · Files Changed · Documentation Status · Current State · Specialist Flags · Decisions Made · Blocked Actions · What's Next) wholesale with the **four-section contract** matching `~/.claude/skills/apex-orchestrate/templates/handoff-from-coding.md`: **Decisions Made** (all from `coder_summary.decisions`; tag build-time architectural choices `[arch]`), **Specialist Flags** (from `reviewer_findings`, ALL severities including low; AFK runs add the end-gate table per apex-handoff), **Blocked Actions** (from `coder_summary.blocked_actions`), **What's Next (discoveries)** (only what the build learned). Add explicitly: `Write "none" where a section is empty. **Add no sections beyond the template's four** — the H1, the session-metadata line, and the read-once preamble are template chrome and stay. The retired build-inventory sections are gone, and their facts have other homes: what changed → git log; which specs finished → docs/changes/done/; build status and in-progress position → status.md In-Flight. The template forbids repeating them (apex-handoff § one home per fact).` **Name the retired sections only indirectly like this** — restating their headings verbatim would defeat this task's own zero-hit check.
  4. (Subsumed by mechanism 3's wholesale replacement — stated separately only to pin the exact legacy text being retired, so the coder can confirm it is gone.) The ADR-006-era Current State bullet must not survive: `- Current State: run the bound stack's \`## Verification Recipe\` (from \`stack_skills\` in status.md, per ADR-006) and report actual results. If no stack skill is bound, report what the spec's \`## Commands to run\` produced. Never assume \`npm\`.` (superseded by ADR-037 — AGENTS.md is the recipe's single home, and the handoff carries no build status).
  5. **No overview.md step. The promise is RETIRED, not relocated.** This agent writes exactly three artifacts — handoff, `docs/status.md`, spec archival — and records nothing about `overview.md`. (Task 10 deletes the apex-code:378 promise that named this agent as its executor; the audit's category 5 explicitly permitted "delete the promise". `overview.md` is maintained by whoever's spec lists it, at spec-authoring time.) **Do not add an overview step, an overview report line, or an overview skip-note.**
  6. Step 5 (Report) consumes the product agent's status: append `Docs: {status from docs_product_summary — completed | completed_with_skips | failed}.` — this makes the `docs_product_summary` input load-bearing instead of a dead field.
  Done when: `Select-String -Path agents/apex-docs-technical-agent.md -Pattern 'stack_skills','ADR-006','What Was Built','Specs Completed','Documentation Status'` returns **zero** hits; `-Pattern 'D6, ADR-046','docs_product_summary','Blocked Actions','What''s Next','completed_with_skips'` matches all five; and `-SimpleMatch -Pattern 'overview.md'` returns **zero** hits (the promise is retired, not relocated — this agent must carry no overview step, report line, or skip-note).

- [ ] **Task 7: parallel-codex — D8 teardown + wrapper-mandatory rewrite** — files: `C:/Users/User/.claude/skills/apex-code/references/parallel-codex.md` (modify).
  Mechanism:
  1. **Cat 6** — replace the fenced raw recipe (the `printf '%s' "<task prompt>" | codex exec -p apex-coder ...` block) with a wrapper invocation, and delete the sentence that presents it as the dispatch command. New fence:
     ```powershell
     # -Authorized paths are WORKTREE-RELATIVE, never absolute
     & "$env:USERPROFILE\.claude\skills\apex-code\scripts\codex-dispatch.ps1" `
       -Spec <spec> -Task <task-id> -Phase build -Worktree <worktree> -BaseSha <sha> `
       -SpecSourcePath <abs path to the spec> `
       -Prompt "<the dispatch pack>" `
       -Authorized @('src/a.py','tests/test_a.py') `
       -Effort <coder_effort>
     ```
     **Nothing may follow a continuation backtick** — a trailing comment breaks the line continuation, so `-Effort` would execute as its own statement. Keep comments on their own lines, above the invocation.
     **`-Authorized` takes worktree-RELATIVE paths.** `codex-scope-check.ps1` compares them against `git status` output, which is repo-relative and only slash-normalized. An absolute path can never match, so every legitimate write reads as unauthorized and the dispatch dies on exit 65 (or exit 66 when nothing matches). Convert each of the task's `## Files to Change` absolutes by stripping the tree prefix — `C:/Users/User/.claude/skills/apex-x/SKILL.md` → `skills/apex-x/SKILL.md`.
     Add below it: `**Never hand-roll a raw pipe into \`codex exec\`** — \`hooks/codex-dispatch-guard.js\` hard-blocks a raw \`codex exec\` in Bash and PowerShell, and the raw path has no ledger, no watchdog, no \`-Adopt\`, and does not read the verdict. The wrapper owns the \`--json\`/\`-o\`/log split; the log path it prints is what the user tails. Full observability contract → \`references/codex-observability.md\`.` **The warning must not name the shell builtin it is warning about**, or this task's own zero-hit check can never pass.
  2. **D1 consistency** — amend the opening paragraph sentence `The host runs them as **concurrent background \`codex exec\` subprocesses** (Bash \`run_in_background\`)` to append: ` — **as mechanics only**: launching and monitoring the subprocesses strictly from the build orchestrator's wave plan and returning status/exit codes to it. Task selection, sequencing, routing, verification, retries, and close-out stay orchestrator-owned (ADR-045 as amended 2026-07-29; ADR-046 D1).`
  3. **D8** — replace the `## Teardown` first sentence `\`git worktree remove --force <path>\`, then delete the branch.` with: `Teardown is permitted **only** under the D8 carve-out (ADR-046) — you created this worktree/branch, integration is complete, and **both** checks below pass. Teardown is permitted only after the verification defined in **ADR-046 § D8** (\`~/apex/docs/technical/adr/ADR-046-doctrine-audit-resolutions.md\`): \`git worktree remove <path>\` requires a clean worktree, and \`git branch -D codex/<spec>-<task-id>\` additionally requires an empty path-scoped branch diff, so branch deletion follows the approved per-spec integration commit. Ancestry checks are not valid evidence. **ADR-046 § D8 is the single canonical home of that algorithm — read it there; it is deliberately not restated here.** Any non-empty result, or any other branch, is a hard block. **And this is doctrine-level authorization, not a mechanical bypass:** \`hooks/lib/destructive-detect.js\` intercepts \`git branch -d/-D\` — and the path-scoped \`git checkout … -- …\` integration form — denying it or requiring confirmation per its own rules. The scoped mechanical allowance is the queued retro P5(c) hook change, out of scope here; until it ships, a permitted teardown executes via the user's \`!\` one-liner handback.`
  3h. **Branch identity — spec-qualify it.** The `## Isolation = git-worktree-per-task` line reads `For each parallel task: \`git worktree add <path> -b codex/<task-id>\` from HEAD, then pipe the same prompt`. Numeric task ids repeat across specs, and the cross-spec pool runs tasks from several specs at once, so a bare id collides. Replace `-b codex/<task-id>` with `-b codex/<spec>-<task-id>` and update **every** `codex/<task-id>` occurrence in this file (the teardown and integration steps included) to `codex/<spec>-<task-id>`.
  3g. **Stale slot count (~line 60).** The cross-spec cap paragraph reads `Three ready Codex tasks from three different specs fill the same 3 slots that` / `three tasks from one spec would.` The pool is 2 by default now — replace `the same 3 slots` with `the same slots (default 2)`, keeping the rest of the sentence.
  3f. **Stale cap-default pointer.** Line ~13 currently reads `behaviour; status.md carries the project default)`. After Task 16 there is no such status.md field. Replace the parenthetical tail with `behaviour). The default is **2** (A2; ADR-028 as amended); a spec's \`max_parallel_codex\` frontmatter is the only override.`
  3e. **Failure/fallback role residue.** Lines ~46-47 read `back the remaining sub-wave tasks to Sonnet 5 (sequential — A1/ADR-045; Opus keeps spec-author + high-risk` / `reviewer roles only).` Replace `Opus keeps spec-author + high-risk` / `reviewer roles only` with `Opus keeps the spec-author, build-orchestrator, and high-risk-reviewer roles`. **That three-role list is the spec-wide convention** — Tasks 10 and 14 use the identical phrasing at their own sites.
  3c. **Dangling pointer (sol finding).** The `## Teardown` tail currently reads `clear them with the codex-exec cleanup trick (SKILL.md § Windows sandbox artifact ownership) before retrying.` That section no longer exists in the apex-code SKILL. Read the SKILL, confirm the surviving home (currently the **Windows sandbox** bullet under § Codex dispatch — the coder subprocess must not create `node_modules`/`.venv`, because the sandbox SID then owns them and a host-run verify hits a locked tree), and **retarget the pointer to that section by its real current name**. If no section covers it, inline the fact in one sentence instead of pointing at nothing.
  3d. **Missing integration step — the branch-tip gap.** `## Integrate` opens `Tasks in a wave write disjoint files, so bring each task's changes into the main tree with` / `\`git checkout codex/<spec>-<task-id> -- <that task's files>\`.` — **quoted as it will read after item 3h's rename**; the current live text still says `codex/<task-id>`, so match on the live form when you make the edit. That reads the **branch tip**, but coder output is **uncommitted** in the worktree, so as written it integrates nothing. Insert the missing step immediately before it: `**First commit the worktree to its task branch.** Coder output is uncommitted; \`git checkout <branch> -- <files>\` reads the branch TIP, so an uncommitted worktree integrates as a no-op. After the task's own verify passes, the integrator stages **path-scoped** with \`git add -- <this task's authorized paths, worktree-relative>\` (run **inside that worktree**; explicitly listed paths DO stage newly created files, so no \`-A\` is needed — and \`-A\` would absorb out-of-scope residue, defeating the D8 porcelain check). **If the worktree's gitignore excludes those paths** — as \`~/.claude\`'s blanket \`*\` does — use \`git add -f -- <paths>\`; force-add **only the name-listed authorized files**, never a directory or a glob. Then commit to \`codex/<spec>-<task-id>\` with message \`build(<spec>): task <task-id>\`. Only then integrate path-scoped into the main tree. **Deletions cannot be integrated this way (D7):** \`git checkout <branch> -- <path>\` cannot remove a file that is absent at the branch tip, so for every file the spec marks \`Operation: delete\` the integrator stages the removal on the integration branch directly with \`git rm <path>\` instead. The integrator here is the **host, acting as mechanics** under the wave plan (ADR-046 D1): executing the staging, the commit, and the path-scoped checkout exactly as directed is *within* host mechanics; deciding which tasks integrate, in what order, or whether a result passes is not. Builders still never commit — this commit is the host's, not the coder's.`
  4. **Cat 7 cadence + D1 ownership** — in `## Integrate`, replace `Then run the spec's Verification Recipe **once on the integrated main tree** as the authoritative gate` with `Then run the recipe (AGENTS.md → \`## Verify commands\`) **on the integrated main tree** — this integrated-wave pass is the authoritative one. It does not replace the per-task pass each coder ran inside its own worktree; both cadences apply (per task in isolation during build, once integrated at integration). Ownership is split (ADR-046 D1). The host EXECUTES the recipe as mechanics from the orchestrator's wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows.` — **the final sentence must appear verbatim, exactly as written here.**
  Done when, against `C:/Users/User/.claude/skills/apex-code/references/parallel-codex.md`: `-Pattern 'printf','Windows sandbox artifact ownership','status.md carries the project default'` returns **zero** hits; `-SimpleMatch -Pattern 'codex-dispatch.ps1','ADR-046 § D8','both cadences apply','destructive-detect.js','retro P5(c)','First commit the worktree to its task branch','git add -- ','git add -f -- ','git rm','build-orchestrator','git worktree remove <path>','WORKTREE-RELATIVE'` matches all twelve, and `-SimpleMatch -Pattern 'git add -A'` returns **zero** hits; no line in any prescribed fence has text after a continuation backtick; and `-SimpleMatch -Pattern 'The host EXECUTES the recipe as mechanics from the orchestrator''s wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows.'` matches the full sentence. (The D8 algorithm strings are NOT asserted here — ADR-046 is their only home.)

- [ ] **Task 8: model-routing + apex-plan SKILL + sol-plan-check — cat 1 self-contradictions + cat 3 enum + host label** — files: `C:/Users/User/.claude/skills/apex-plan/references/model-routing.md`, `C:/Users/User/.claude/skills/apex-plan/SKILL.md`, `C:/Users/User/.claude/skills/apex-plan/references/sol-plan-check.md` (all modify).
  Mechanism — `model-routing.md`:
  1. Lines ~8–11: replace `Under ADR-027 the menu is` / `\`{codex, opus}\` and routing **collapses**: Codex is the default coder for every task; Opus is reached` / `only as the **manual fallback** when Codex quota is exhausted. There is no per-task cost/complexity` / `routing — both coders are frontier-class and Opus is not a proactive choice.` with: `Under ADR-027 as amended (A1, session-79b; ADR-045) the menu is \`{codex, sonnet}\` and routing **collapses**: Codex is the default coder for every task; **Sonnet 5** is reached only through the three fallback triggers (quota-out/unavailable · whole-spec \`coder_model: sonnet\` pin · terminal verify-failure routing by the executor). There is no per-task cost/complexity routing, and the fallback is not a proactive choice. Opus keeps the spec-author, build-orchestrator, and high-risk-reviewer roles — it is not a coder.`
  2. Lines ~57–64 (`## Per-task selection`): delete `— apex-code's` / `Opus builds the task inline as a fresh worker in this session.` and replace with `— apex-code builds the task inline as a fresh \`model: sonnet\` worker in this session.` Replace the third bullet `- A whole-spec \`coder_model: opus\` frontmatter can pin a spec to Opus up front (e.g. when you already` / `know Codex quota is gone) — bypasses Codex entirely.` with `- A whole-spec \`coder_model: sonnet\` frontmatter can pin a spec to the Claude fallback up front (e.g. when you already know Codex quota is gone) — bypasses Codex entirely. The enum is exactly \`{codex|sonnet}\`; there is no \`opus\` value.` Also `do not route proactively to Opus` → `do not route proactively to the Claude fallback`.
  3. Line ~94: replace `- Opus-built task (the fallback) → **Codex** reviews (\`codex exec\`) — but Opus builds only because Codex` / `quota is out, ...` with `- Claude-fallback-built task (Sonnet 5) → **Codex** reviews (\`codex exec\`) — but the fallback most commonly fires on quota-out (one of the three triggers), so this usually degrades to single-model + human flag (apex-governance § Cross-model review).`
  4. Line ~105: `hand a frozen-contract slice to Opus (or vice-versa during fallback)` → `hand a frozen-contract slice to the Claude fallback coder (or vice-versa)`.
  5. Line ~86 (`barely touches the scarce Opus pool`) → `barely touches the scarce Anthropic Max pool`. Line ~78 already reads "the Claude fallback (Sonnet 5)" — leave it.
  6b. **The fallback-trigger list — THREE triggers, worded identically at every site.** This exact list is the spec-wide convention (Tasks 8, 12, and 13 all use it verbatim): `The Claude fallback (Sonnet 5) fires on exactly three triggers: (1) Codex quota-out or unavailability; (2) a whole-spec \`coder_model: sonnet\` pin; (3) terminal verify-failure routing by the executor (the orchestrator, or the host as interim executor). Nothing else reaches it.` Insert it in `model-routing.md` § *Per-task selection*, replacing any one- or two-trigger phrasing there.
  6. **Stale field name.** Line ~8's load condition reads `Loaded on demand when a project's \`coder_models\` menu has >1 entry.` There is no plural `coder_models` field on status.md (the spec template's own note removes it). Replace with `Loaded on demand when a build could take more than one coder — i.e. before setting a spec's \`coder_model\` frontmatter, or at a quota-out fallback decision.`
  `apex-plan/SKILL.md`: line ~155 — replace `\`coder_model: {codex|opus}\` pins a whole spec` with `\`coder_model: {codex|sonnet}\` pins a whole spec` — the enum is exactly those two values; **do not add an `opus` exception clause.** Bump `version` `2.1.2` → **`2.2.0`** — a **minor** bump, not a patch: this task changes the skill's contract from *drafting the spec itself* to *dispatching the spec author*. Set `last_updated: 2026-07-29`.
  `apex-plan/SKILL.md`, § *Wave plan* (~line 150) — **wave ownership conflicts with D1.** It currently reads `**\`## Wave plan\`** (specs with ≥3 tasks): group tasks into waves from the *stated* dependencies —` / `\`Wave 1: [1, 2] | Wave 2: [3]\`. You are the stronger reasoner; do the analysis here so the build` / `executes it verbatim with zero inference. Independence you can't establish → sequential.` Replace with `**\`## Wave plan\`** (specs with ≥3 tasks): derive a **PROPOSED** wave plan from the *stated* dependencies — \`Wave 1: [1, 2] | Wave 2: [3]\`. The **dependencies are binding**; the **grouping is advisory**. Final task selection and sequencing are **orchestrator-owned** (ADR-046 D1; interim: the host performs them as executor until that agent contract ships). Do the analysis here so the executor has a defensible starting point, not so it is spared judgement. Independence you can't establish → sequential.`
  `apex-plan/SKILL.md`, § *Writing the spec* — the four-role wiring gap (sol BLOCK: nothing dispatches the required spec author). Current text reads `Template: \`~/.claude/skills/apex-orchestrate/templates/spec-template.md\`.` / `Write to **\`docs/drafts/{short-name}.md\`** first — never straight to \`docs/changes/\`.` Replace the second line with: `**You do not draft it yourself (ADR-045).** Resolve the open decisions, then dispatch a \`model: opus\` spec-author worker with the plan, the template path, and the target path \`docs/drafts/{short-name}.md\` — never straight to \`docs/changes/\`. The author drafts; you review its draft against the rules below and the readiness gate. The rest of this section is the contract you hand the author and grade against.`
  `sol-plan-check.md` — the planning host is Fable 5, not Opus (ADR-045); same class as the ratified apex-research relabel. Line ~27: replace `- **Input = spec + repo evidence only.** Never Opus's self-review notes, reviewer findings, or` with `- **Input = spec + repo evidence only.** Never the spec AUTHOR's or the host's self-review notes, reviewer findings, or` — the exclusion must name the actual author, which under ADR-045 is the `model: opus` spec-author worker, not the host. Line ~49: replace `1. Opus answers each finding into the *same* Sol conversation — **amend** (accept; change the` with `1. The host answers each finding into the *same* Sol conversation — **amend** (accept; change the`.
  Done when: `Select-String -Path skills/apex-plan/references/model-routing.md -Pattern 'Opus is reached','coder_model: opus','Opus-built task','Opus builds the task inline'` returns **zero** hits; `Select-String -Path skills/apex-plan/references/sol-plan-check.md -CaseSensitive -Pattern 'Opus'` returns **zero** hits; `Select-String -Path skills/apex-plan/SKILL.md -SimpleMatch -Pattern 'codex|sonnet','spec-author worker','ADR-045','PROPOSED','grouping is advisory'` matches all five, and `-SimpleMatch -Pattern 'executes it verbatim with zero inference'` returns **zero** hits; `Select-String -Path skills/apex-plan/references/model-routing.md -SimpleMatch -Pattern 'coder_models','the fallback fires only because'` returns **zero** hits and `-SimpleMatch -Pattern 'one of the three triggers'` matches.

- [ ] **Task 9: apex-orchestrate SKILL — four-role wiring + sources** — files: `C:/Users/User/.claude/skills/apex-orchestrate/SKILL.md` (modify).
  Mechanism:
  1. In the `## 3. Route` table, replace the row `| build · implement · execute · start build | **apex-code** |` with `| build · implement · execute · start build | **apex-code**. **Now:** the host runs the build as **interim executor** (ADR-046 D1) — performing the scheduling, routing, and adjudication duties itself, per \`apex-code/references/parallel-codex.md\`, until the contract below exists. **Target:** dispatch a \`model: opus\` build orchestrator (Opus 5 — owner amendment 2026-07-29, was Sonnet) that owns scheduling, routing, and adjudication (ADR-045), activating when the **build-orchestrator agent contract** ships (queued retro P1–P7 set). |`, and the row `| plan · design · architect · spec · "let's build" · what if | **apex-plan** |` with `| plan · design · architect · spec · "let's build" · what if | **apex-plan** — then **dispatch a \`model: opus\` spec author** to draft the spec/ADR from your plan (author contract: \`apex-orchestrate/templates/spec-template.md\` + apex-plan § Writing the spec; ADR-045); the host does not author it itself |`. **The build row must document BOTH states explicitly — never route live traffic to an agent that does not exist yet.**
  2. Add two lines under the table. First: `Both dispatches are the ADR-045 role split, tightened by ADR-046 D1: the host reasons and plans, workers build. The host's build-time mechanics are launching and monitoring subprocesses from the orchestrator's wave plan, executing the git operations that plan directs, and returning status/exit codes — never task selection, sequencing, routing, verify adjudication, retries, or close-out.` Second, the transitional note — **these two rows describe the TARGET state**: `**Transitional (2026-07-29):** until the build-orchestrator agent contract ships (queued retro P1–P7 spec set), a build executes per \`apex-code/references/parallel-codex.md\` with the host performing the mechanics directly. Route as above; the dispatch step lands with that contract.`
  3. Frontmatter: add `  - docs/technical/adr/ADR-045-four-role-split.md` and `  - docs/technical/adr/ADR-046-doctrine-audit-resolutions.md` to `sources:`; bump `version` `2.0.1` → `2.1.0`; `last_updated: 2026-07-29`.
  Done when, against `C:/Users/User/.claude/skills/apex-orchestrate/SKILL.md`: `-SimpleMatch -Pattern 'model: opus','spec author','build-orchestrator agent contract','interim executor','owner amendment 2026-07-29','ADR-046-doctrine-audit-resolutions'` matches all six, and `-SimpleMatch -Pattern 'model: sonnet'` returns **zero** hits. (The fallback-coder line at § 4, `Coder: Codex gpt-5.6-sol (Sonnet 5 fallback)`, is untouched and must still match — it names Sonnet 5 without the `model:` prefix.)

- [ ] **Task 10: apex-code SKILL — cats 1, 5, 7, 8, 10** — files: `C:/Users/User/.claude/skills/apex-code/SKILL.md` (modify).
  Mechanism:
  1. **Cat 7 — verify owner + cadence (D1-aligned).** In `## Verify`, replace `Run the recipe **per task**, not once at the end. **The host runs it — never the coder subprocess judging its own output** (evaluator independence).` with: `**Two cadences, both required, and the ownership is split three ways.** (a) *During build:* the coder runs the recipe inside its own isolated worktree, per task, and iterates to green — that is its job under AGENTS.md and the dispatch pack. (b) *Authoritative pass:* the recipe is re-run after the task's changes are in the integration tree — per task for a sequential build, once on the integrated wave for a parallel one (\`references/parallel-codex.md\`). Ownership is split (ADR-046 D1). The host EXECUTES the recipe as mechanics from the orchestrator's wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows. The coder's own pass never satisfies the gate: **the coder does not judge its own output**, and neither the host nor the coder adjudicates (evaluator independence). Executing the recipe, the per-task worktree commit, the path-scoped integration, and the approved per-spec commit are all **host mechanics** — executions taken from the wave plan, not decisions about it.` — **that ownership sentence must appear verbatim, exactly as written here.**
  2. **Cat 7 — impl.md load moves to pre-flight.** Delete the line `Load \`~/.claude/skills/apex-coding-principles/impl.md\` before writing code.` from `## Verify` and add it to `## Pre-flight` as a bullet: `- **Load \`~/.claude/skills/apex-coding-principles/impl.md\`** now — before any dispatch or write, not at verify time.`
  3. **Cat 7 — exit-72 recovery. Replace the WHOLE passage, both sentences** — a replacement starting at the second `absent that` leaves the first fallback ("fall back to the spec's `## Commands to run`") intact and self-contradictory. `## Verify` currently opens: `The recipe is the repo's **\`AGENTS.md\` → \`## Verify commands\`** (ADR-037). Absent one, fall back to` / `the spec's \`## Commands to run\`; absent that, run the obvious per-ecosystem checks, log the gap, and` / `**write a recipe into AGENTS.md so the next build has one**.` Replace all three lines with `The recipe is the repo's **\`AGENTS.md\` → \`## Verify commands\`** (ADR-037), and that is its only home — there is no spec-side fallback section. Absent a recipe, the pre-dispatch pre-flight refuses the build with **exit 72** before launch — you cannot write the recipe from inside a build. Recovery: **the HOST authors \`## Verify commands\` into AGENTS.md attended** (root AGENTS.md is critical host state — live confirmation required, AFK parks), then re-dispatches. \`-SkipBaselineCheck\` is the bootstrap escape and is host-authorized only.`
  4. **Cat 8 — review-vs-writes race. The audit's original fix, and nothing more.** Two edits only.
     **(a) The ordering rule.** In `## Post-build`, replace step 1's `**In parallel:**` heading with `**Serialized — the reviewer first:**`, and require that `apex-docs-product-agent` is **dispatched only AFTER `apex-reviewer` has returned its verdict**. Text to add: `\`apex-docs-product-agent\` writes inline documentation into source files, so running it alongside an open review moves the tree under the reviewer and VOIDs the verdict (§ Pin the tree before you open a gate). Dispatch it only after the reviewer has returned.`
     **(b) One documentation sentence, scoping what the digest binding actually covers.** Add: `**Known limit — digest binding.** The wrapper-ledger digest binding that \`apex-family-gate.ps1\` enforces covers **wrapper-launched reviews of a task worktree as the coder left it**. How that binding should extend to integrated-tree reviews and to reviews after the documentation writes is **UNRESOLVED**, and is owned by the queued retro spec set (\`~/apex/docs/research/artemis-retro-2026-07-29.md\`, items P1–P7). Do not infer a rule for those cases from this one.`
     **Deliberately NOT in this spec (descoped 2026-07-30, owner decision — rides with the retro P1–P7 set):** any complete post-build step ordering; any two-bindings exposition; any claim about wrapper-launched reviews preceding the integration commit; any requirement that the handoff enumerate post-review writes; and any host re-verify-after-docs step. **Do not add them back.**
  4b. **D6 is a SCOPE-LOCK exception too, not only a critical-file one.** Add to `## Post-build`: `The docs agents' three host's-pen artifacts — the handoff, \`docs/status.md\`, and spec archival into \`docs/changes/done/\` — are **permitted post-build writes outside \`## Files to Change\`** (D6, ADR-046); they do **not** need to be listed there. **Exactly those three. Nothing else is exempt** — any other write outside the lock is flagged, not applied.`
  4c. **Add the missing host-review step to the executable flow** — D6's covering control is currently promised nowhere. After the docs agents, add a numbered step: `**Host review of docs-agent output.** Before the session closes, the host reads what the docs agents wrote and either **accepts** it, or **rejects it and re-dispatches the agent with the findings so the agent REVISES its own artifacts in place**. All three artifacts are rewritable files, so revision is **idempotent by construction** — a re-dispatch overwrites the handoff and \`docs/status.md\` rather than appending. The one exception is the archival file move: once done it **stands and is not redone**; a re-dispatch skips it. **The host never edits the agents' output itself** — that would be a mechanical edit (ADR-046 D1). This is the control that makes the D6 AFK carve-out safe; without it the carve-out is unbacked.`
  5. **Cat 5 — DELETE the overview promise.** Step 6 currently reads `6. \`apex-docs-technical-agent\` -- writes the handoff, archives the spec to \`docs/changes/done/\`, and` / `   folds the shipped capability into \`overview.md\` as one line (merge-on-archive, ADR-014).` **Delete the overview clause**, leaving `6. \`apex-docs-technical-agent\` -- writes the handoff and archives the spec to \`docs/changes/done/\`.` The promise had no executor and the audit's category 5 permitted deleting it; Task 6 correspondingly adds no overview step. `overview.md` is maintained by whichever spec lists it.
  6. **Cat 10 — scope-lock vs fork.** In `## Pre-flight`, append to the scope-lock bullet: `A fork that needs to build "in the real place" (§ Forks) does **not** widen the lock by prose — prose cannot change the wrapper's \`-Authorized\` list, so a write there still trips exit 65. **The HOST amends the spec's \`## Files to Change\` and re-dispatches the task with the updated \`-Authorized\` list**, recording why in the decisions table and the handoff. The lock is never widened in-flight; it is re-issued.`
  6c. **Broken wrapper fence (~lines 107-114) — the same continuation-backtick defect.** The live dispatch example puts trailing comments after continuation backticks on two lines: `  -SpecSourcePath <abs path> \`                    # host always passes the spec's real home on cross-tree builds` and `  -Authorized @('src/a.py','tests/test_a.py') \`   # the spec's ## Files to change, VERBATIM`. **A backtick followed by a comment does not continue the line**, so `-Effort` (itself trailing `# default medium`) executes as a separate statement. Rewrite the fence with every comment on its own line and the wrapper called by absolute path — and correct the `-Authorized` note, which currently says "VERBATIM" but must say worktree-relative:
     ```powershell
     # -SpecSourcePath: the spec's real home, required on cross-tree builds
     # -Authorized: the task's Files-to-Change paths, WORKTREE-RELATIVE (never absolute)
     # -Effort: omit at medium
     & "$env:USERPROFILE\.claude\skills\apex-code\scripts\codex-dispatch.ps1" `
       -Spec <spec> -Task <task> -Phase build -Worktree <repo-root> -BaseSha <sha> `
       -SpecSourcePath <abs path> `
       -Prompt "<the dispatch pack>" `
       -Authorized @('src/a.py','tests/test_a.py') `
       -Effort <coder_effort>
     ```
  6b. **Cat 3 — the live enum's opus escape hatch.** Line ~226 currently ends `relaunch (ADR-038). Whole-spec pin: \`coder_model: {codex|sonnet}\` (A1; \`opus\` remains accepted for a deliberate exception, logged).` Nothing implements that path. Replace the parenthetical with `(A1). The enum is exactly those two values.` — leaving `relaunch (ADR-038). Whole-spec pin: \`coder_model: {codex|sonnet}\` (A1). The enum is exactly those two values.`
  7. **Cat 1** — line ~240: `→ **Opus** (fresh worker)` → `→ **Sonnet 5** (fresh \`model: sonnet\` worker — A1/ADR-045)`. Line ~225 carries two clauses in one sentence; **exactly one changes.** Change the roles clause `Opus keeps spec-author and high-risk reviewer roles` → `Opus keeps the spec-author, build-orchestrator, and high-risk-reviewer roles` (same three-role phrasing as Tasks 7 and 14). Leave the fallback-coder clause in that sentence exactly as it stands — it already reads Sonnet 5, which is correct. Line ~314: `**Opus built -> Codex reviews**` → `**Claude-fallback built (Sonnet 5) -> Codex reviews**`. Leave lines 322–323 unchanged (the AFK end-gate is deliberately Opus, ADR-034).
  7a. **Interim-executor framing where the skill tells the host to schedule.** The `## Wave analysis` section (heading at line ~55) instructs the reader to compute wave parallelism, log the plan, and route completions — duties ADR-046 D1 assigns to the orchestrator. Add one line directly under that heading: `**Who does this (ADR-046 D1).** Wave grouping, dispatch sequencing, and completion routing are **orchestrator-owned**. Until the build-orchestrator agent contract ships (queued retro P1–P7 set), the **host performs them as interim executor** — a recorded transition state, not doctrine. The instructions below describe that interim execution.`
  7b. **D6 at the Layer-A gate.** The Host-state authoring paragraph (line ~96) currently ends `Authorizing any of them -- including bare directory grants \`docs/changes\` or \`docs/handoff\` -- requires attended \`-CriticalFilesConfirmed\`; an unattended/AFK dispatch that tries to authorize one refuses with exit **76** by design: **PARK** the task.` Append: ` **Sole exception (D6, ADR-046):** the docs agents' three host's-pen artifacts — the handoff doc, \`docs/status.md\`, and spec archival into \`docs/changes/done/\` — are written by the docs agents during an AFK close-out and reviewed by the host before session close. That exception covers those three artifacts and nothing else; every other host-state authorization still parks. **Interim mechanics:** under AFK the harness may silently deny a docs-agent's off-list write (\`dontAsk\` inheritance); until the permissions follow-up ships (queued retro set), the **HOST performs the three artifacts' writes itself** — they are host bookkeeping (state-keeping) under the session licence clause, so no gate is crossed. The docs agents are the host's pen whenever the harness permits; the host is always a valid writer of its own three artifacts.`
  8. Frontmatter: add `  - docs/technical/adr/ADR-045-four-role-split.md`, `  - docs/technical/adr/ADR-046-doctrine-audit-resolutions.md` to `sources:`; bump `version` `2.12.1` → `2.13.0`; `last_updated: 2026-07-29`. **Line budget:** hard cap 500 **physical** lines; this file already sits near it, so keep the net change **neutral or negative** where the wording allows (the AGENTS.md rule for the two at-cap skills).
  Done when, against `C:/Users/User/.claude/skills/apex-code/SKILL.md`: `-SimpleMatch -Pattern 'Run the recipe **per task**, not once at the end','write a recipe into AGENTS.md so the next build has one','**In parallel:**','Serialized — docs first'` returns **zero** hits; `-SimpleMatch -Pattern 'Serialized — the reviewer first','only after the reviewer has returned','Known limit — digest binding','artemis-retro-2026-07-29.md','Host review of docs-agent output','permitted post-build writes outside','re-issued','Sole exception (D6, ADR-046)','Two cadences','interim executor'` matches all ten, and `-SimpleMatch -Pattern 'same tree by construction','passes by construction','outside the wrapper ledger','never family-gate-bound','enumerates every post-review write'` returns **zero** hits (all descoped 2026-07-30); `-SimpleMatch -Pattern 'The host EXECUTES the recipe as mechanics from the orchestrator''s wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows.'` matches the full sentence; and `@(Get-Content <that path>).Count -le 500` is true (physical line count — `Measure-Object -Line` undercounts and must not be used).

- [ ] **Task 11: codex-observability + codex-review + permissions — wrapper-mandatory, blocking semantics, D3/D4/D5 consumers** — files: `C:/Users/User/.claude/skills/apex-code/references/codex-observability.md`, `C:/Users/User/.claude/skills/apex-code/references/codex-review.md`, `C:/Users/User/.claude/skills/apex-code/references/permissions.md` (all modify).
  Mechanism:
  - `codex-observability.md`: replace the `## Recipe` fenced raw `printf '%s' "<dispatch pack>" | codex exec …` block with the wrapper invocation in the **absolute-path form so it works from any cwd** — `& "$env:USERPROFILE\.claude\skills\apex-code\scripts\codex-dispatch.ps1"` followed by the same parameter shape as Task 7 — **including its comment placement: nothing after a continuation backtick, all comments on their own lines above the invocation, `-Authorized` worktree-relative** — and replace the sentence `Run the dispatch **backgrounded** (Bash \`run_in_background\`), splitting Codex's output two ways:` with `Dispatch through the wrapper — **always**. \`hooks/codex-dispatch-guard.js\` hard-blocks a raw \`codex exec\`, so no hand-rolled pipe is a runnable path. The wrapper applies the \`--json\` event stream + \`-o <final>\` split and writes the log outside the target repo. **It does not background the child** — the wrapper blocks on \`WaitForExit\` until Codex finishes; if you want the dispatch off the foreground, background the **wrapper invocation** itself.` Keep every flag explanation (`-c model_reasoning_effort`, `--json`, `-o`, log path) as a description of the wrapper's behaviour. Line ~44: `the only rung between \`max\` and the scarce Opus pool` → `the only rung between \`max\` and the Claude fallback (Sonnet 5)`.
  - `codex-observability.md`, **§ Durable dispatcher** (line ~94) contradicts the wrapper-always rewrite. It currently reads `For AFK/unattended builds, \`scripts/codex-dispatch.ps1\` replaces the raw \`codex exec\` invocation` / `above — same flags, same dispatch pack, same \`--json\` log and \`-o\` \`.final\` schema output — but` / `adds three things a long unattended run needs that a one-shot foreground/backgrounded call does` / `not: a guaranteed stdin close, a durable run record, and crash recovery.` Replace the opening clause with: `\`scripts/codex-dispatch.ps1\` is the **only** dispatch path, attended or not — a hook denies the alternative. Beyond the flags, the dispatch pack, the \`--json\` log and the \`-o\` \`.final\` schema output, it adds three things any run needs and a long unattended one cannot do without:` and keep the three-item list and the **Why** paragraph as-is. Also retitle the section heading `## Durable dispatcher (ADR-033 A4)` → `## What the wrapper adds (ADR-033 A4)` so it no longer reads as an AFK-only variant.
  - `codex-review.md`: line 4 — `the **independent reviewer for Opus-built (fallback) code**` → `the **independent reviewer for Claude-fallback-built code (Sonnet 5)**`; line 6 — `Note: Opus builds only when Codex quota is exhausted` → `Note: the Claude fallback builds only via the three fallback triggers (see model-routing)`. Line 5–6 — replace `it is **advisory** — it never blocks the pipeline and never edits code.` with `it **never edits code**, and its *findings* are advisory — but its **verdict routes**: \`BLOCK\` → exit 67, which is a HARD STOP on the pipeline (do not commit, do not build a dependent spec). **The BUILD ORCHESTRATOR adjudicates a build-side review BLOCK and routes it** (ADR-046 D1); the host relays it to the user only when the call needs human judgment. It is not auto-dismissable and not merely a suggestion. \`FLAG\` → exit 68, carried into the review.` Also fix the stale cross-reference `(§ Cross-model review graceful-degrade)` at line ~52. **Anchor verified against the live file:** `apex-code/SKILL.md` has no `Cross-model review` heading — its headings are `## Session start`, `## Pre-flight`, `## Wave analysis`, `## Codex dispatch — the coder`, `## Verify`, `## Forks — when the spec is wrong`, `## Post-build`, `## Autonomy, permissions, hard blocks`, `## Pause`, `## Decisions log`, and the cross-family review content lives as **numbered step 2 under `## Post-build`**. Retarget to the section heading only: exactly `(apex-code § Post-build)`. No step number — step numbering inside that section is unstable and would rot. **And line ~11**, which currently reads `A raw \`printf … | codex exec …\` is **hard-blocked** by \`hooks/codex-dispatch-guard.js\` and will be` / `denied.` — reword to `A hand-rolled pipe into \`codex exec\` is **hard-blocked** by \`hooks/codex-dispatch-guard.js\` and will be denied.` (the wrapper invocation it already documents at lines ~19-28 stays as the replacement path).
  - `permissions.md` — two live contradictions with the ratified decisions, both ground-quoted.
    **(a) D3 + D4, line ~13.** The `## \`dontAsk\` build-mode policy` opener reads `\`dontAsk\` enforces permissions at the harness level (no classifier), so mirror the spec's` / `\`## Permissions\` into \`permissions.allow\` (\`.claude/settings.local.json\` or \`~/.claude/settings.json\`)` / `before the build:`. Replace with: `\`dontAsk\` enforces permissions at the harness level (no classifier), so the spec's \`## Permissions\` must be mirrored into \`permissions.allow\` (\`.claude/settings.local.json\` or \`~/.claude/settings.json\`) **before** the build. **Two limits, both ratified (ADR-046):** the spec pre-authorises **NON-critical** actions only — a critical path is never mirrored in, and an unattended run **parks** it rather than allow-listing it (D3). And the allow-list edit itself is a **permission action**: it happens **attended, on user approval, before dispatch** (the ADR-023 flow, carved out of the self-widening block by D4). A background or AFK run **never** edits permissions. Mirror this list:`
    **(b) D5, line ~34.** The audit-log section opens `At L4+, append every action to \`docs/audit/YYYY-MM-DD.log\`:`. Replace with: `At L4+ every action is recorded to \`docs/audit/YYYY-MM-DD.log\` in the shape below. **Doctrine ahead of enforcement (D5, ADR-046):** append-only is the sanctioned mode and editing or deleting an existing entry is permanently forbidden — but the live classifier \`apex-critical-files.ps1\` refuses **every** \`docs/audit/\` path on a path match alone (exit 11), with no append-vs-edit distinction. **So the agent does not write this file.** Until a content-aware classifier change ships, these appends route through the **host**.`
  Done when: `Select-String` over `C:/Users/User/.claude/skills/apex-code/references/codex-observability.md` and `C:/Users/User/.claude/skills/apex-code/references/codex-review.md` for `'printf'` returns **zero** hits; `codex-review.md` for `'never blocks the pipeline','§ Cross-model review graceful-degrade'` returns zero and for `'exit 67, which is a HARD STOP','BUILD ORCHESTRATOR adjudicates','(apex-code § Post-build)','three fallback triggers'` matches all four; `codex-observability.md` for `'For AFK/unattended builds','backgrounds the child'` returns **zero** and for `'the \*\*only\*\* dispatch path','WaitForExit'` matches both; and `C:/Users/User/.claude/skills/apex-code/references/permissions.md` for `'D3','D4','D5, ADR-046','never edits permissions','route through the \*\*host\*\*'` matches all five while `'At L4\+, append every action'` returns **zero** hits.

- [ ] **Task 12: dispatch-pack + workflow-dispatch — fallback rows, verify owner, bound-stack ref** — files: `C:/Users/User/.claude/skills/apex-code/references/dispatch-pack.md`, `C:/Users/User/.claude/skills/apex-code/references/workflow-dispatch.md` (both modify).
  Mechanism:
  - `dispatch-pack.md`: line ~92 `wait for quota reset (re-dispatch Codex) vs Opus fallback now` → `... vs Claude fallback (Sonnet 5) now`. Line ~94 `→ Opus fallback per SKILL.md § Model fallback` → `→ Claude fallback (Sonnet 5) per SKILL.md § Fallback`. Line ~34 (Hazard selection): `the loaded impl cores (apex-coding-principles + bound stack NEVER/ALWAYS)` → `the loaded \`apex-coding-principles/impl.md\` core NEVER/ALWAYS (there are no bound stack skills — ADR-036)`. **Cat 7 verify owner:** in the autonomy clause paragraph, add after the fence: `The coder runs the recipe **inside its own worktree** and iterates to green — that is what this clause instructs. It is not the authoritative pass, and it is not an adjudication. On the integration tree the ownership is split (ADR-046 D1; apex-code § Verify). The host EXECUTES the recipe as mechanics from the orchestrator's wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows. Both cadences are required; neither replaces the other.` — **the ownership sentence must appear verbatim, exactly as written here.**
  **D1 routing ownership, line ~85 and its table.** The heading currently reads `## Completion routing (host reads exit code + \`.final\` JSON)` and the table's third column is headed `Host action`. Replace the heading with `## Completion routing (orchestrator-owned; the host reads the exit code + \`.final\` JSON and reports them)` and the column header `Host action` with `Orchestrator routing`. Add one line under the table: `The host reads the signal and hands it up; **which rung fires — re-dispatch, effort bump, fork, park — is the orchestrator's call**, not the host's (ADR-046 D1). **Interim:** until the build-orchestrator agent contract ships, the host performs that routing itself as **interim executor** — a recorded transition state, not doctrine.`
  - `workflow-dispatch.md`: in the `args` fence, `"model": "opus"` → `"model": "sonnet"`. Replace the quoted note `> \`model\` carries **only \`opus\`** (the fallback). Codex — the default coder — is **NOT** dispatched` / `> here: it runs as a sequential \`codex exec\` subprocess in-session (ADR-027). The workflow / parallel` / `> fan-out path applies only to the Opus-fallback builds.` with `> \`model\` carries **only \`sonnet\`** — the Claude fallback coder (Sonnet 5; A1/ADR-045). Codex — the default coder — is **NOT** dispatched here: it runs as a \`codex exec\` subprocess in-session (ADR-027). This workflow / parallel fan-out path applies only to Claude-fallback builds. The Claude fallback (Sonnet 5) fires on exactly three triggers: (1) Codex quota-out or unavailability; (2) a whole-spec \`coder_model: sonnet\` pin; (3) terminal verify-failure routing by the executor (the orchestrator, or the host as interim executor). Nothing else reaches it.` Also retarget the two stale section pointers: `the Worker return contract` → `the worker return contract (SKILL.md § Codex dispatch — the wrapper's exit codes)`, and `§ Wave domain review` → `§ Post-build`. **And line ~33**, which currently reads `4. Single-task waves still execute directly (no workflow, no agent), exactly as the inline rule.` — replace with `4. A single-task wave skips the workflow (no fan-out to orchestrate) but still **dispatches**: one \`model: sonnet\` worker, exactly as the inline rule. The host never writes the task itself (ADR-045).`
  Done when: `Select-String` over `C:/Users/User/.claude/skills/apex-code/references/dispatch-pack.md` and `C:/Users/User/.claude/skills/apex-code/references/workflow-dispatch.md` for `'Opus','opus'` returns **zero** hits; `workflow-dispatch.md` for `'no workflow, no agent'` returns **zero** hits and for `'ADR-045'` matches; `dispatch-pack.md` for `'Orchestrator routing'` matches and for `'Host action'` returns **zero** hits; and `dispatch-pack.md` with `-SimpleMatch -Pattern 'The host EXECUTES the recipe as mechanics from the orchestrator''s wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows.'` matches the full sentence.

- [ ] **Task 13: build-wave workflow + reviewer + coder agent — fallback relabelling** — files: `C:/Users/User/.claude/workflows/apex-build-wave.js`, `C:/Users/User/.claude/agents/apex-reviewer.md`, `C:/Users/User/.claude/agents/apex-coder.md` (all modify). Comment/prose only — no executable logic changes.
  Mechanism:
  - `apex-build-wave.js` header comment: replace `//                     model — optional per-task coder override. Under ADR-027 the only value that` / `//                     reaches this field is 'opus' (the fallback coder, run in the APEX_MODE=coding` / `//                     host). Omit → the session default.` with `//                     model — optional per-task coder override. Under ADR-027 as amended (A1/ADR-045)` / `//                     the only value that reaches this field is 'sonnet' (the Claude fallback coder,` / `//                     Sonnet 5, run in the one session — there is no mode split any more, ADR-038).` / `//                     Omit → the session default.` **The replacement must not name the retired environment variable**, or this task's own zero-hit check can never pass. Replace the trailing `This workflow / the` / `parallel fan-out path is therefore used only for Opus-fallback builds.` with `... used only for Claude-fallback (Sonnet 5) builds.` **And the worker-prompt verify line (~57)**, which currently reads `` `exactly this task and nothing more; run the spec's applicable commands; verify the`, `` — replace with `` `exactly this task and nothing more; run the repo's AGENTS.md ## Verify commands recipe; verify the`, `` so the fallback path names the same recipe home as every other path (ADR-037).
  - `apex-reviewer.md` line 10: replace `cross-family for a Codex (openai) build, but same-family for an Opus-built change. On the Opus-fallback path,` with `cross-family for a Codex (openai) build, but same-family for a Claude-fallback-built change (Sonnet 5). On the Claude-fallback path,`.
  - `apex-coder.md`: add a line under the frontmatter, before `You are the apex-coder.`: `**Claude-fallback path only.** The default coder is Codex \`gpt-5.6-sol\`, dispatched per task as a \`codex exec\` subprocess by the \`model: opus\` build orchestrator (Opus 5 — ADR-045 as amended 2026-07-29). This agent and its \`code-worker\` children run **only** on the Claude fallback, which fires on exactly three triggers: (1) Codex quota-out or unavailability; (2) a whole-spec \`coder_model: sonnet\` pin; (3) terminal verify-failure routing by the executor (the orchestrator, or the host as interim executor). Nothing else reaches it.` **Two different roles in one sentence — keep them straight:** the *orchestrator* is Opus 5; the *fallback coder* stays Sonnet 5 (`coder_model: sonnet`, `code-worker` pinned `model: sonnet`). Do not change the fallback-coder side. It has no \`Bash\` tool by design — it plans and spawns; workers write.` Then change `You do NOT write code directly — only code-worker agents write files.` to `On this path you do NOT write code directly — only \`code-worker\` agents write files.` **And the frontmatter `description:`** currently reads `Analyses a spec's task dependencies, groups tasks into parallel waves, spawns code-worker agents in parallel per wave, and returns a complete task summary.` — it gives no hint this is fallback-only, so the router can pick it over the default Codex path. Replace with a **quoted** scalar — an unquoted YAML value cannot begin with `*`, so bold markup there breaks the frontmatter parse: `description: "Claude-fallback path ONLY (Sonnet 5) — dispatched when Codex is quota-out/unavailable, when a spec pins coder_model: sonnet, or on terminal verify-failure routing. Not the default coder."` (All three fallback triggers are named; the quoting is load-bearing.) **Task 22's SKILLS.md description sweep must pick this up** — the agent table row at `SKILLS.md:60` (`| **apex-coder** | apex-code | Dependency analysis, wave grouping, parallel dispatch |`) needs the same fallback-only qualifier. **And one interim note on its scheduling duties** — Steps 2-4 (lines ~24-56) have this agent build the dependency graph, apply the worker cap, and sequence waves, which ADR-046 D1 assigns to the build orchestrator: add under `## Step 2: Build dependency graph` → `**Ownership (ADR-046 D1).** On the fallback path this agent **executes** wave analysis and worker spawning **as dispatched**. Ownership of the scheduling doctrine is unchanged: orchestrator-owned is the target, with the host as interim executor until the build-orchestrator agent contract ships. This agent is not a competing owner.`
  Done when, against `C:/Users/User/.claude/workflows/apex-build-wave.js`, `C:/Users/User/.claude/agents/apex-reviewer.md`, and `C:/Users/User/.claude/agents/apex-coder.md`: `-Pattern 'Opus (built|builds|fallback)','Opus-built','Opus-fallback','APEX_MODE'` returns **zero** hits (the plain word "Opus" is now legitimate in `apex-coder.md` — it names the orchestrator — so do NOT sweep for it bare); `-SimpleMatch -Pattern 'Claude-fallback path ONLY (Sonnet 5)','terminal verify-failure routing','model: opus'` matches in `apex-coder.md`, and its `description:` value is a **double-quoted** scalar (the line matches `^description: "`); and `apex-build-wave.js` still carries `'sonnet'` as its only model value (fallback coder, unchanged).

- [ ] **Task 14: ADR backlinks + cap caveats + inline cap-3 text + ADR-037 self-contradiction + retro P1 premise** — files (all modify): `ADR-027-codex-primary-opus-fallback-deepseek-archived.md`, `ADR-028-parallel-codex-dispatch.md`, `ADR-029-cross-spec-parallel-build.md`, `ADR-034-sol-default-coder.md`, `ADR-036-remove-knowledge-layer.md`, `ADR-037-three-context-files.md`, `ADR-038-single-session.md`, `ADR-042-critical-file-confirmation-and-achievable-cross-family.md` — written in full so the per-task scope extractor sees them: `C:/users/user/apex/docs/technical/adr/ADR-027-codex-primary-opus-fallback-deepseek-archived.md`, `C:/users/user/apex/docs/technical/adr/ADR-028-parallel-codex-dispatch.md`, `C:/users/user/apex/docs/technical/adr/ADR-029-cross-spec-parallel-build.md`, `C:/users/user/apex/docs/technical/adr/ADR-034-sol-default-coder.md`, `C:/users/user/apex/docs/technical/adr/ADR-036-remove-knowledge-layer.md`, `C:/users/user/apex/docs/technical/adr/ADR-037-three-context-files.md`, `C:/users/user/apex/docs/technical/adr/ADR-038-single-session.md`, `C:/users/user/apex/docs/technical/adr/ADR-042-critical-file-confirmation-and-achievable-cross-family.md`, `C:/users/user/apex/docs/technical/adr/ADR-030-codex-reasoning-effort-dial.md`, `C:/users/user/apex/docs/technical/adr/ADR-031-codex-context-propagation.md`, `C:/users/user/apex/docs/technical/adr/ADR-032-gpt56-role-split.md`, `C:/users/user/apex/docs/research/artemis-retro-2026-07-29.md`, `C:/users/user/apex/ROADMAP.md`, `C:/users/user/apex/docs/technical/architecture/overview.md`, `C:/users/user/apex/docs/technical/pin-change-sweep.md`. **Does NOT touch ADR-045 (Task 2 owns it).**
  Mechanism — **apply Task 2's ADR-mutation convention throughout:** banners are appended; older bodies stay historical; and a Decision-table **cell** or decision-list **line** may be edited only with the historical value adjacent. Step 3's ADR-037 reader-cell edit takes the `as drafted this row said X` form; step 2b's ADR-028/029 cap-default line edits take the `X at ship time; live value Y — see amendment` form. **Both are convention-compliant, not exceptions.**
  1. **Cat 1 banner** — insert, immediately after each file's title/status header block, one blockquote (adapt the wording to each file's existing banner voice, do not delete existing banners):
     `> **Fallback coder amended by [ADR-045](./ADR-045-four-role-split.md) (2026-07-19, A1 session-79b):** the Claude fallback coder is **Sonnet 5** (a fresh \`model: sonnet\` worker), **not Opus**. Opus holds the spec-author, build-orchestrator (owner amendment 2026-07-29), and high-risk-reviewer roles — not the coder role. Every "Opus fallback" / "Opus builds inline" statement below is historical. Sweep recorded in [ADR-046](./ADR-046-doctrine-audit-resolutions.md).`
     Apply to **ten** ADRs: ADR-027, ADR-028, ADR-029, ADR-030, ADR-031, ADR-032, ADR-034, ADR-036, ADR-038, ADR-042. (ADR-030 lines ~5/36/48-49, ADR-031 ~42-44, and ADR-032 ~5/78/89 all still present Opus as the *active* fallback with no banner — same treatment, same banner text.) Leave the body text historical — do not rewrite the decisions.
  2. **Cat 2 cap caveat** — add to ADR-028 (after its decision item 2) and ADR-029 (after its decision item 5): `> **Amended (A2, session-79b, 2026-07-19; recorded in [ADR-046](./ADR-046-doctrine-audit-resolutions.md)):** the live default is **2**, not 3. Two full waves ran sequentially with zero wall-clock pressure. The formula \`max(1, min(4, floor(cores/2) − 1))\` (= 3 on this host) stays documented for reference; the shipped default is 2.`
  2b. **Cat 2 — the inline default-3 body text must change too** (a trailing caveat cannot satisfy the zero-hits sweep). **These are in-place line edits, so Task 2's ADR-mutation convention applies: each carries its historical note adjacent, in the same sentence.** ADR-028 line ~32 currently reads `(8 physical / 16 logical cores). Auto-sized from cores; default to **3** when core detection is` — replace `default to **3** when core detection is` with `defaulted to **3** at ship time when core detection was` and continue the sentence into `unavailable; live default **2** — see the A2 amendment below.` (Note the past tense "defaulted to", so the zero-hit pattern `default to **3**` cannot match.) ADR-029: line ~10 reads `` `codex exec` subprocesses bounded by `max_parallel_codex` (3 on this host). It does not widen the `` and line ~56 reads `their tasks all contend for the one machine-protection budget (3 here); without this rule the host` — in both, replace the parenthetical with `(3 at ship time; live default 2 — see the A2 amendment)`. Do not alter ADR-028's other uses of the digit 3 (the wall-clock example at line ~53 and worktree bound at ~55 are unrelated). **Record in the task's decisions note that these three edits are convention-compliant: line edits with the historical value preserved adjacent.**
  3. **Cat 10 — ADR-037 self-contradiction** — in the decision table, change the `<repo>/docs/status.md` "Read by" cell from `Both (provider-agnostic)` to `**Claude only** — Codex never reads it` and add one line under the table: `"Provider-agnostic" in earlier drafts meant the *format* is not Claude-specific, not that Codex reads it. Codex reads AGENTS.md and never status.md (§ Context). **As drafted this row said "Both (provider-agnostic)".** Clarified 2026-07-29 — [ADR-046](./ADR-046-doctrine-audit-resolutions.md).`
  4. **Cat 1 — retro P1 premise note. TWO occurrences; fix both.** (i) Line ~41, in the P1(b) paragraph: `workflow. NOT routed through \`apex-build-wave\` (that` / `workflow is Opus-fallback-only by design — its workers implement directly and never dispatch` / `Codex; Sol BLOCK verified against apex-build-wave.js:18-21).` — replace `that workflow is Opus-fallback-only by design` with `that workflow is Claude-fallback-only by design (the fallback coder is Sonnet 5 — A1/ADR-045; it was Opus when this note was written)`. Leave the `apex-build-wave.js:18-21` citation intact. (ii) Line ~172: `verified vs apex-build-wave.js (Opus-fallback-only); host-native background path instead. BLOCK` — replace `(Opus-fallback-only)` with `(Claude-fallback-only — Sonnet 5 per A1/ADR-045)`. Leave the rest of the row intact.
  5. **Cat 1 — ROADMAP, both stale role claims in one bullet.** `C:/users/user/apex/ROADMAP.md` lines ~17-19 read `- **Roles, not sessions** ([ADR-045](docs/technical/adr/ADR-045-four-role-split.md)): Fable host` / `  reasons/plans, Opus drafts specs/ADRs, Sonnet orchestrates builds, Codex \`gpt-5.6-sol\` codes` / `  per-task (Opus fallback), review is cross-family both directions.` Two edits: `Sonnet orchestrates builds` → `Opus 5 orchestrates builds` (owner amendment 2026-07-29), and `per-task (Opus fallback)` → `per-task (Sonnet 5 fallback)`. "Opus drafts specs/ADRs" is correct — leave it.
  6. **Cat 1 — the architecture Overview.** `pin-change-sweep.md` names `docs/technical/architecture/overview.md` as the **first stop for any role change**, so it must not lag the amendment. In `C:/users/user/apex/docs/technical/architecture/overview.md`: line ~40 reads `- **Build orchestrator (Sonnet)** — a \`model: sonnet\` worker runs waves and routes exit codes.` → replace with `- **Build orchestrator (Opus 5)** — a \`model: opus\` worker runs waves and routes exit codes (owner amendment 2026-07-29; was Sonnet).` Lines ~42-43 read `  own quota). Verify-fail escalation climbs the reasoning-effort dial (\`…→max→ultra\`), then` / `  falls back to **Opus** (fresh \`model: opus\` worker) if Codex quota is exhausted.` → replace the second line with `  falls back to **Sonnet 5** (fresh \`model: sonnet\` worker) if Codex quota is exhausted.` Line ~77's decision-table row `| Codex is the primary coder (per-task \`codex exec\` subprocess), Opus the inline fallback; DeepSeek archived |` → replace `Opus the inline fallback` with `Sonnet 5 the fallback`. Leave the ADR links intact.
  6b. **Cat 4 — the same file's three host-role claims, all pre-D1.** Annotate each with the interim-executor note, wording consistent with ADR-046 D1. (i) Line ~19-20 reads `2. **Plan** — judgment work (turning a request into a complete, unambiguous spec; writing` / `   ADRs; design and research) is done by the host.` → append ` The host reasons and decides; a \`model: opus\` spec-author worker drafts the spec and ADR text from that plan (ADR-045).` (ii) Lines ~36-38 read `- **Host (Fable)** — reasons, plans, and challenges. Dispatches every worker below; makes no` / `  mechanical edits and writes no code, but owns the project's state-keeping (status.md,` / `  handoff, memory).` → append ` Build-time mechanics — launching and monitoring subprocesses from the orchestrator's wave plan, executing the git operations it directs, and returning status — are the host's; scheduling, routing, and verify adjudication are orchestrator-owned, performed by the host as **interim executor** until that agent contract ships (ADR-046 D1).` (iii) Line ~72's decision row `| One session, no modes — host plans/builds/verifies; role split replaces the backend split |` → replace `host plans/builds/verifies` with `host plans, executes verify mechanics from the orchestrator's plan, and reviews; the orchestrator adjudicates; workers build (ADR-046 D1)` — the citation sits at the edit site, per the Intent invariant, and the execute-vs-adjudicate split must be explicit.
  6c. **`pin-change-sweep.md` — reconcile its ADR rule to the amendment convention.** Its step 4 (~lines 20-23) reads `4. **ADR banners and status headers** — for a model pin, update the banner of every ADR that states` / `   the old model as present-tense. For a doctrine change, back-write a supersession/status header` / `   into every ADR the change retires. **Never edit ADR decision prose** — a decision is correct at` / `   its date; only the metadata header/banner is editable.` As written it forbids the very edits Task 14 performs. Append one sentence: ` **Exception — the amendment convention (ADR-046):** a Decision-table cell or decision-list line MAY be edited in place when an amendment supersedes its value, provided the historical value stays adjacent (\`as drafted this row said X\`, or \`X at ship time; live value Y — see amendment\`) and a dated amendment section records the change. Everything else in the decision prose stays historical.`
  Done when, with `$adrDir = C:/users/user/apex/docs/technical/adr`: `-Pattern 'ADR-046-doctrine-audit-resolutions'` matches in each of `$adrDir/ADR-027-codex-primary-opus-fallback-deepseek-archived.md`, `$adrDir/ADR-028-parallel-codex-dispatch.md`, `$adrDir/ADR-029-cross-spec-parallel-build.md`, `$adrDir/ADR-034-sol-default-coder.md`, `$adrDir/ADR-036-remove-knowledge-layer.md`, `$adrDir/ADR-038-single-session.md`, `$adrDir/ADR-042-critical-file-confirmation-and-achievable-cross-family.md`; `-Pattern 'the shipped default is 2'` matches in both `$adrDir/ADR-028-parallel-codex-dispatch.md` and `$adrDir/ADR-029-cross-spec-parallel-build.md`; `-Pattern 'default to \*\*3\*\* when core detection'` on `$adrDir/ADR-028-parallel-codex-dispatch.md` returns **zero** hits; `-Pattern '\(3 on this host\)','\(3 here\)'` on `$adrDir/ADR-029-cross-spec-parallel-build.md` returns **zero** hits; `-Pattern '\|\s*Both \(provider-agnostic\)\s*\|'` on `$adrDir/ADR-037-three-context-files.md` returns zero hits — **anchor the regex to the table-row form**, since the required historical note quotes the retired phrase in prose and must not trip the check; and `-Pattern 'Opus-fallback-only'` on `C:/users/user/apex/docs/research/artemis-retro-2026-07-29.md` returns **zero** hits while `-Pattern 'Claude-fallback-only'` matches **twice**.

- [ ] **Task 15: L3 + apex-research** — files: `C:/Users/User/.claude/skills/apex-governance/levels/L3.md`, `C:/Users/User/.claude/skills/apex-research/SKILL.md` (both modify).
  Mechanism:
  - `L3.md`: replace `- Full AFK build pipeline (apex-coder → code-workers → reviewer → docs agents)` with `- Full AFK build pipeline: \`model: opus\` build orchestrator (Opus 5 — owner amendment 2026-07-29) → per-task Codex \`codex exec\` coders (\`apex-coder\` → \`code-worker\` only on the Claude fallback, Sonnet 5) → reviewer → docs agents (ADR-045) **(target state, ADR-045 as amended; interim: the host executes the pipeline from the orchestrator's wave plan until the agent contract ships — ADR-046 D1)**`. **Orchestrator = Opus 5; fallback coder = Sonnet 5. Do not conflate them.** Replace the forbidden bullet `- File deletions` with `- File deletions — **except** a delete listed in the spec's \`## Files to Change\` with \`Operation: delete\` on a non-critical path, which is pre-authorised (D7, ADR-046)`. And append to the forbidden bullet `- git add + git commit` (line ~9): ` — this is the **integration-branch** commit gate; transient \`codex/<spec>-<task-id>\` worktree commits during a parallel build are build mechanics under the wave plan and are not gated here (ADR-046 D1)`.
  - `apex-research/SKILL.md`: line ~32 — `| **1. Plan** | you, in-context (Opus) |` → `| **1. Plan** | you, in-context (the host) |`. Line ~59 — replace the dangling `([[background-agents-no-interactive-approval]])` link with the inlined fact: `(a dispatched agent has no interactive approval channel — the denial is silent)`. In the numbered resolution list, append to item 1: `This is not self-widening: a user-approved domain allow during **attended** planning is carved out of the hard block (D4, ADR-046). A background or AFK run never edits permissions.` Bump `version` patch and `last_updated: 2026-07-29`.
  Done when: `Select-String -Path skills/apex-research/SKILL.md -Pattern 'background-agents-no-interactive-approval','in-context \(Opus\)'` returns **zero** hits and `-Pattern 'D4, ADR-046'` matches; `Select-String -Path skills/apex-governance/levels/L3.md -SimpleMatch -Pattern 'D7, ADR-046','model: opus','target state, ADR-045 as amended','ADR-046 D1'` matches all four, and `-SimpleMatch -Pattern 'model: sonnet'` returns **zero** hits.

- [ ] **Task 16: status-template + apex-init** — files: `C:/Users/User/.claude/skills/apex-orchestrate/templates/status-template.md`, `C:/Users/User/.claude/skills/apex-init/SKILL.md` (both modify).
  Mechanism:
  - `status-template.md`: replace `> Build/execution contract → \`AGENTS.md\`. Model routing → \`~/.claude/CLAUDE.md\`. See ADR-037.` with `> Build/execution contract → \`AGENTS.md\`. Model routing → \`~/.claude/hooks/apex-session-context.md\` (hook-injected). See ADR-037.` **Do not add a "not in CLAUDE.md" clause** — it would re-match this task's own zero-hit pattern. Add one line after `autonomy_level: L2`: `<!-- Build knobs are spec frontmatter, not status fields: coder_model {codex|sonnet}, max_parallel_codex (default 2 — A2/ADR-028 as amended). This file carries no coder_models or max_parallel_codex field. -->`
  - `apex-init/SKILL.md`, edit 1: replace `Running at L2 | Profile: balanced | Mode: planning` with `Running at L2 | Coder: Codex gpt-5.6-sol (Sonnet 5 fallback)` — there are no session modes (ADR-038).
  - `apex-init/SKILL.md`, edit 2 (ADR-037 contradiction): the § *Persistent artifacts* text currently reads `Each session starts fresh. Without persistent artifacts,` / `context is lost between sessions. These four files survive every session boundary` / `and are loaded by every new agent before it acts:`. Replace the third line with `and are read **on demand**, not preloaded — no agent loads all four before it acts (ADR-037):`. Then annotate the four bullets so each names its real reader: `**PROJECT.md** — vision statement (what and who) — read on demand during planning`; `**REQUIREMENTS.md** — scope boundaries (in-scope / out-of-scope) — read on demand during planning`; `**ROADMAP.md** — phase breakdown (filled once planning begins) — read on demand during planning`; `**docs/status.md** — live state — read by the **host** at session start; **Codex never reads it** (the coder's contract is \`AGENTS.md\`, ADR-037)`.
  - `apex-init/SKILL.md`, edit 3 (**the same claim appears a SECOND time** in the Step 4 confirmation banner — fix both sites): lines ~148-149 currently read `  PROJECT.md        ← vision — loaded by every new agent` / `  REQUIREMENTS.md   ← scope boundaries — loaded by every new agent`. Replace the trailing clause on both with `— read on demand during planning`.
  - `apex-init/SKILL.md`: bump `version` patch, `last_updated: 2026-07-29`.
  Done when: `Select-String -Path skills/apex-init/SKILL.md -Pattern 'Mode: planning','loaded by every new agent before it acts'` returns **zero** hits and `-Pattern 'ADR-037','Codex never reads it'` matches both; `Select-String -Path skills/apex-orchestrate/templates/status-template.md -Pattern 'apex-session-context.md'` matches and `-Pattern 'Model routing.*CLAUDE\.md'` returns **zero** hits.

- [ ] **Task 17: AGENTS-template — heading schema, verify owner, queue rule** — files: `C:/Users/User/.claude/skills/apex-orchestrate/templates/AGENTS-template.md` (modify).
  Mechanism:
  1. Step 1: `Implement \`## Exact changes\` precisely — signatures, file contents, edit locations.` → `Implement each \`## Tasks\` item precisely — the task text names its exact files, mechanism, and done-when.`
  2. Step 3: `**Run the spec's \`## Commands to run\`** and make every \`## Acceptance criteria\` item pass.` → `**Run this file's \`## Verify commands\`** (the recipe's single home, ADR-037) and make every \`## Acceptance Criteria\` item pass. You run it inside your own worktree and iterate to green. That is not the authoritative pass and not a verdict. The host EXECUTES the recipe as mechanics from the orchestrator's wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows.` — **that final sentence must appear verbatim, exactly as written here.**
  3. Step 2: `only create/modify files in the spec's \`## Files to change\`` → `only create/modify files in the spec's \`## Files to Change\``.
  5. **Archive-writer fix (D6 coverage).** Item 4 of the queue section reads `4. **After a spec passes, move it to \`docs/changes/done/\`** (a file move, not a commit).` The coder must not archive — spec archival is one of the three host's-pen artifacts. Replace with `4. **Never move or archive a spec.** Spec archival into \`docs/changes/done/\` is the \`apex-docs-technical-agent\`'s host's-pen write, or the host's directly (D6, ADR-046). Report that the spec passed; the close-out does the move.`
  4. `## Building a queue of specs` item 2: replace `**One spec fully at a time** — implement → run the verify recipe → green — before starting the next.` with `**Scheduling is the orchestrator's call (ADR-029).** Specs that are both dependency-independent (\`## Prerequisites\`) and file-disjoint (\`## Files to Change\`) may build concurrently, up to \`max_parallel_codex\` (default 2). **Third condition (ADR-029 supervision gate):** a **high-risk** spec — `risk: high`, or auth / security / data — runs **foreground and sequential even when it is dependency-independent and file-disjoint**; it never joins the pool. Anything else is one spec at a time. Either way: implement → run the verify recipe → green, and **integrate → verify → commit strictly sequentially, in dependency order**. **That commit is not yours** — the \`## Hard rules\` no-commit rule above still binds you absolutely. Integration and commits are executed host-side from the orchestrator's plan (ADR-046 D1); you build and verify in the tree you are given and leave it dirty.`
  Done when, against `C:/Users/User/.claude/skills/apex-orchestrate/templates/AGENTS-template.md`: `-Pattern '## Exact changes','## Commands to run','One spec fully at a time'` returns **zero** hits; `-Pattern 'ADR-029'` matches; and `-SimpleMatch -Pattern 'The host EXECUTES the recipe as mechanics from the orchestrator''s wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows.'` matches the full sentence.

- [ ] **Task 18: apex repo AGENTS.md — heading schema + queue rule** — files: `C:/users/user/apex/AGENTS.md` (modify). Root `AGENTS.md` is host-state/critical: if the classifier flags it, **PARK** for live attended confirmation (D3).
  Mechanism: same two schema corrections as Task 17, in this file's own voice:
  1. `1. **Read the whole spec first.** Implement \`## Exact changes\` precisely.` → `1. **Read the whole spec first.** Implement each \`## Tasks\` item precisely — the task text names its exact files and mechanism.`
  2. `3. **Run the spec's \`## Commands to run\`** and make every \`## Acceptance criteria\` item pass.` → `3. **Run this file's \`## Verify commands\`** (below — the recipe's single home, ADR-037) and make every \`## Acceptance Criteria\` item pass.`
  3. `2. **Surgical scope:** create or modify only files in the spec's \`## Files to change\`.` → `... in the spec's \`## Files to Change\`.`
  4. **Archive-writer fix (D6 coverage).** Item 5 reads `5. **After a spec passes, move it to \`docs/changes/done/\`** (a file move, not a commit).` Replace with `5. **Never move or archive a spec.** Spec archival into \`docs/changes/done/\` is the \`apex-docs-technical-agent\`'s host's-pen write, or the host's directly (D6, ADR-046). Report that the spec passed; the close-out does the move.`
  Done when: `Select-String -Path C:/users/user/apex/AGENTS.md -Pattern '## Exact changes','## Commands to run'` returns **zero** hits; `-Pattern 'Verify commands.{0,4}\(below','## Files to Change'` matches both. (Do **not** assert zero hits on `## Files to change` — edit 3 is a casing fix and Select-String is case-insensitive, so that pattern can never reach zero.)

- [ ] **Task 19: apex-handoff — completed state + WIP-commit gate** — files: `C:/Users/User/.claude/skills/apex-handoff/SKILL.md` (modify).
  Mechanism:
  1. In the one-home-per-fact table, replace the row `| Which specs finished | status.md + \`docs/changes/done/\` |` with `| Which specs finished | \`docs/changes/done/\` + \`git log\` — **never status.md** (a finished row is DELETED there, ADR-037) |`.
  2. Replace the WIP-commit line `WIP commits: when pausing mid-build, commit with message \`wip: {spec-name} — task {n}/{total}\` so the checkpoint is in git even if docs/ is lost.` with: `WIP commits: when pausing mid-build, a checkpoint commit \`wip: {spec-name} — task {n}/{total}\` puts the work in git even if docs/ is lost. **The standing approval gate applies, with no exception** — draft the message, show it, get approval, then commit (CLAUDE.md; apex-governance § Commit discipline). **An unattended run does NOT commit.** It records the drafted commit message in the status.md In-Flight row's existing **Next** column and queues it for the next attended exchange. D6's AFK carve-out covers the docs agents' *document* writes only — it does not reach git commits (ADR-046 D6 Consequences).`
  3. **Retire the phantom Uncommitted column.** This file canonically declares one that the status template does not have. The section (~line 112) reads `## Commit status values (status.md In-Flight \`Uncommitted\` column)` / (blank) / `The handoff carries no file table — git is the changelog. Uncommitted risk lives in the` / `status.md In-Flight row:` followed by a two-row `| Status | Meaning |` table. The template's real columns are `What | State | File | Next`. Retitle the section `## Commit status values (recorded in the In-Flight row's \`Next\` column)` and replace the two prose lines with `The handoff carries no file table — git is the changelog. Uncommitted risk, and any drafted-but-unapproved commit message, are recorded in the existing \`Next\` column of the status.md In-Flight row. **There is no \`Uncommitted\` column** — the template's columns are \`What | State | File | Next\`.` Keep the status-value table as the vocabulary for that cell.
  4. Bump `version` `1.6.1` → `1.7.0`; `last_updated: 2026-07-29`.
  Done when: `Select-String -Path skills/apex-handoff/SKILL.md -Pattern 'status.md \+ .docs/changes/done'` returns **zero** hits; `-CaseSensitive -Pattern 'An unattended run does NOT commit'` matches; `-Pattern 'no exception','queues it for the next attended exchange'` matches both; and `-Pattern 'AFK carve-out.{0,40}may take the WIP commit'` returns **zero** hits.

- [ ] **Task 20: stale-pointer repairs (cats 9 + 10)** — files (all modify): `C:/Users/User/.claude/skills/apex-plan/references/design-workflow.md`, `C:/Users/User/.claude/skills/apex-plan/references/cheap-mockup-workflow.md`, `C:/Users/User/.claude/skills/apex-plan/references/design-lane-workflow.md`, `C:/Users/User/.claude/skills/apex-stack/SKILL.md`, `C:/Users/User/.claude/skills/apex-context-budget/SKILL.md`, `C:/Users/User/.claude/skills/apex-coding-principles/SKILL.md`, `C:/Users/User/.claude/skills/apex-coding-principles/references/elaboration.md`.
  Mechanism:
  - `design-workflow.md`: **four** `[[…]]` links across the file target memory files that no longer exist — inline the fact, drop the link. Lines ~80-81 span a break and currently read `**Path B — pull one library style.** Fixed-aesthetic style skills are **not** auto-loaded (they` / `collide and tax compliance — [[design-style-on-demand]]); they live shelved in`. Replace only the link, keeping the existing clause intact and **not duplicating "they collide and tax compliance"**: the second line becomes `collide and tax compliance — that is exactly why the shelf exists); they live shelved in`. Line ~91 `Opt-in, never reflexive ([[no-reflexive-ui-render-prompt]]).` → `Opt-in, never reflexive.` — **delete the parenthetical outright**, the sentence already carries the rule. Line ~144 `([[cursor-coedit-flow]])` → `(Cursor co-editing: your edit lands as a live diff in the file the user has open, and the render pane updates in the same window)`. Line ~190 `**Opt-in only** — never auto-run, never auto-offered` / `([[no-reflexive-ui-render-prompt]]).` → replace the link with the inline fact: `(never offer a design lane unprompted — the user invokes it).` Line ~159: `The coder (Codex \`gpt-5.6-sol\`; Opus on fallback)` → `The coder (Codex \`gpt-5.6-sol\`; Sonnet 5 on fallback)`. Leave line ~181's `model: opus` reviewer pin (a deliberate Opus role).
  - `cheap-mockup-workflow.md` line ~3: `SKILL.md carries the two-loop rule + the SwiftUI hard gate; this file carries` → `\`design-workflow.md\` carries the two-loop rule + the SwiftUI hard gate; this file carries`.
  - `design-lane-workflow.md` line ~4: `SKILL.md carries the opt-in trigger, the pick-by-stack table, and the two principles` → `\`design-workflow.md\` carries the opt-in trigger, the pick-by-stack table, and the two principles`.
  - `apex-stack/SKILL.md`, **exit-72 contradiction (~line 135):** the recipe-home paragraph currently ends `\`apex-code\` reads AGENTS.md before dispatching; absent a recipe, it falls back to the spec's` / `\`## Commands to run\`.` There is no such spec section, and a recipe-less repo is refused with **exit 72** before launch. Replace those two lines with `\`apex-code\` reads AGENTS.md before dispatching. **Absent a recipe there is no fallback:** the pre-dispatch pre-flight refuses the build with **exit 72** before anything launches, and the host authors the recipe attended before re-dispatching (apex-code § Verify).`
  - `apex-stack/SKILL.md`: `Record it in ADR-001 (template in impl.md).` → `Record it in ADR-001 (template + procedure in \`~/.claude/skills/apex-plan/references/adr-and-status-procedures.md\`).` And `The impl.md warns the coder to verify current npm names.` → `Verify current package names against the registry before pinning; the knowledge layer that used to carry this warning was removed (ADR-036).` Bump `version` patch, `last_updated: 2026-07-29`.
  - `apex-context-budget/SKILL.md`, **the two classification rows that still assume a domain-skill layer (~lines 79-80).** They read `| **Sometimes** | A specialist SKILL.md matched by this project's domains; an \`impl.md\` core for a bound stack skill | Fine on-demand; trim only if a recurring per-run cost |` and `| **Rarely** | Skills no project domain matches; \`references/*.md\` tails; agents never dispatched here | Leave latent (no always-on cost) or flag for lazy-load |`. There are no specialist or domain-matched skills post-ADR-036. Replace the two Criteria cells with `A workflow SKILL.md this session actually routes to; \`apex-coding-principles/impl.md\`'s core — the only impl load a build takes (the knowledge layer was removed, ADR-036)` and `Workflow skills this session never routes to; \`references/*.md\` tails; agents never dispatched here` respectively, keeping both Action cells as they are.
  - `apex-context-budget/SKILL.md`: `- **NEVER** count a whole \`impl.md\` as always-on cost — only its core sections load per run, and only for *bound* stack skills.` → `- **NEVER** count a whole \`impl.md\` as always-on cost — only \`apex-coding-principles/impl.md\`'s core loads per run, and only when a build is writing code.` Bump `version` patch, `last_updated: 2026-07-29`.
  - `elaboration.md`: `This protocol is canonical here. Do not duplicate it into domain impl.md files.` → `This protocol is canonical here. Do not duplicate it anywhere else — the knowledge layer was removed (ADR-036).`
  **In both files the replacement must not restate the swept phrase** ("bound stack skill" / "domain impl.md") — say "the knowledge layer was removed (ADR-036)" instead, or this task's own zero-hit checks can never pass. The same rule applies to the apex-stack edit below.
  - `apex-coding-principles/SKILL.md`: **frontmatter only** — the `version:` line becomes exactly `version: 1.1.2` (from 1.1.1), and `last_updated: 2026-07-29`. This task owns the `elaboration.md` change, so it owns the skill's version bump (Task 22 records the row).
  Done when, over all seven owned files — `C:/Users/User/.claude/skills/apex-plan/references/design-workflow.md`, `C:/Users/User/.claude/skills/apex-plan/references/cheap-mockup-workflow.md`, `C:/Users/User/.claude/skills/apex-plan/references/design-lane-workflow.md`, `C:/Users/User/.claude/skills/apex-stack/SKILL.md`, `C:/Users/User/.claude/skills/apex-context-budget/SKILL.md`, `C:/Users/User/.claude/skills/apex-coding-principles/SKILL.md`, `C:/Users/User/.claude/skills/apex-coding-principles/references/elaboration.md` — `-Pattern '\[\['` returns **zero** hits; `-Pattern 'Opus on fallback'` on `design-workflow.md` returns zero hits; `-Pattern 'SKILL\.md carries'` on the two design references returns **zero** hits; `-SimpleMatch -Pattern 'bound stack skill','template in impl.md','domain impl.md',"matched by this project's domains",'no project domain matches'` across `skills/apex-stack/SKILL.md`, `skills/apex-context-budget/SKILL.md`, and `skills/apex-coding-principles/references/elaboration.md` returns zero hits; `-SimpleMatch -Pattern 'the only impl load a build takes'` on `skills/apex-context-budget/SKILL.md` matches; and `-Pattern 'version: 1.1.2'` on `apex-coding-principles/SKILL.md` matches.

- [ ] **Task 21: agents-skills-projection — projection source + recipe home** — files: `C:/Users/User/.claude/skills/apex-skill-author/references/agents-skills-projection.md`, `C:/Users/User/.claude/skills/apex-skill-author/SKILL.md` (both modify).
  Mechanism:
  1. Resolve the self-contradiction: replace the `## Generation + refresh` first bullet `- Regenerate a card whenever its source APEX skill's *projected sections* change; note "projection refreshed: <repos>" in the source skill's SKILL-HISTORY row.` with `- A card has **no source APEX skill** — its source is the repo (ADR-036). Regenerate it when the **repo's own facts** change: a pinned version bump, a changed verify recipe, a new hazard. Note "card refreshed: <repos>" in the session close, not in a skill's SKILL-HISTORY row.` Replace the third bullet `- Deleting a source skill → delete its cards in consuming repos (flag them in the session close).` with `- A card that still cites a deleted APEX skill is a stale rulebook → re-ground it in the repo's own facts, or delete it (flag in the session close).` Keep the "Live as of 2026-07-14" note.
  2. Recipe-home row: in the `## What projects` table, `the repo's pinned versions + its Verification Recipe (\`status.md\` / \`AGENTS.md\`)` → `the repo's pinned versions + its Verification Recipe (\`AGENTS.md\` → \`## Verify commands\` — its single home, ADR-037; never status.md)`.
  3. `apex-skill-author/SKILL.md`: **frontmatter only** — the `version:` line becomes exactly `version: 2.0.3` (from 2.0.2), and `last_updated: 2026-07-29`. This task owns the reference change, so it owns the skill's version bump (Task 22 records the row).
  Done when: `Select-String -Path skills/apex-skill-author/references/agents-skills-projection.md -Pattern 'projected sections','status.md . AGENTS.md'` returns **zero** hits; `-Pattern 'no source APEX skill','its single home, ADR-037'` matches both; `Select-String -Path skills/apex-skill-author/SKILL.md -Pattern 'version: 2.0.3'` matches.

- [ ] **Task 22: bookkeeping — SKILL-HISTORY rows + SKILLS descriptions** — files: `C:/users/user/apex/SKILL-HISTORY.md`, `C:/users/user/apex/SKILLS.md` (both modify). **Runs last (Wave 3): it records what Tasks 3–21 actually changed.**
  Mechanism:
  - `SKILL-HISTORY.md`: **prepend** (newest first, directly under the intro block) one row per meaningfully-updated skill, schema `| Date | Skill | Files | Version | Event | What Changed | Sources |`, `Date` = 2026-07-29, `Event` = `updated`, `Sources` = `docs/technical/adr/ADR-046-doctrine-audit-resolutions.md · docs/research/doctrine-audit-2026-07-29/README.md`. Rows required, with these version outcomes:
    - **minor bumps (contract changed):** `apex-governance` 2.2.1 → **2.3.0** (D2/D3/D4/D5/D8 carve-outs + L3), `apex-code` 2.12.1 → **2.13.0** (verify owner+cadence, exit-72 recovery, review serialization, scope-lock/fork, impl.md load move), `apex-handoff` 1.6.1 → **1.7.0** (WIP-commit gate + completed-state home), `apex-orchestrate` 2.0.1 → **2.1.0** (routing-table dispatch steps — including the owner's 2026-07-29 amendment making the build orchestrator a `model: opus` worker, Opus 5, across the board — plus spec-template/status-template/AGENTS-template schema changes).
    - **`apex-plan` 2.1.2 → 2.2.0 (minor)** — its contract changes from *drafting the spec itself* to *dispatching the spec author* (Task 8, which performs the bump). Record 2.2.0 here.
    - **patch bumps (wording only):** `apex-research`, `apex-init`, `apex-stack`, `apex-context-budget`, `apex-skill-author`, `apex-coding-principles` — each to the next patch of its current version.
    - **The rule, stated once:** a **contract change → minor**; **wording/pointer repair → patch**.
    - Agents and non-skill artifacts (`code-worker`, `apex-coder`, `apex-reviewer`, `apex-docs-technical-agent`, `apex-docs-product-agent`, `workflows/apex-build-wave.js`) carry no version field — fold them into the `apex-code` and `apex-orchestrate` rows' `Files` columns, naming each path.
    - **`hooks/apex-session-context.md` was pre-executed, not agent-written.** Name it in the `Files` column with the qualifier `apex-session-context.md — pre-executed attended by the host (D3 live confirmation), verified in-build`. Do **not** record it as parked, and do **not** record it as an agent edit.
  - `SKILLS.md` — **two unconditional edits plus a conditional sweep.** Unconditional #2: Task 13 relabels `apex-coder` fallback-only, so the agent-table row at line ~60 — `| **apex-coder** | apex-code | Dependency analysis, wave grouping, parallel dispatch |` — must match; replace its Job cell with `Dependency analysis, wave grouping, parallel dispatch — **Claude-fallback path only**`. Unconditional #1 (cat 1): line ~13 currently reads `DeepSeek, a weak coder that needed rails. The coder is now Codex \`gpt-5.6-sol\` (Opus on fallback),` — replace `(Opus on fallback)` with `(Sonnet 5 on fallback)`. Conditional: also update a skill's one-line description **if** Tasks 3–21/23 changed that skill's frontmatter `description:` string; if none did, change nothing further and say so in the return summary.
  Done when, all three:
  (a) `Select-String -Path C:/users/user/apex/SKILL-HISTORY.md -Pattern 'ADR-046-doctrine-audit-resolutions'` returns ≥1 hit whose row names each of: apex-governance, apex-code, apex-handoff, apex-orchestrate, apex-plan, apex-research, apex-init, apex-stack, apex-context-budget, apex-skill-author, apex-coding-principles.
  (b) **Ordering is a LineNumber comparison, not an eyeball.** The current newest row (line ~6) is identified by the literal text `all 14 apex-* skills + brandkit/design-motion-principles`. Require: `(Select-String -Path SKILL-HISTORY.md -Pattern 'ADR-046-doctrine-audit-resolutions' | Select-Object -First 1).LineNumber` is **less than** `(Select-String -Path SKILL-HISTORY.md -Pattern 'all 14 apex-\* skills \+ brandkit/design-motion-principles' | Select-Object -First 1).LineNumber`.
  (c) Every new row's first column reads `2026-07-29`. (Do **not** assert an exact row-count delta — a single row may legitimately cover several artifacts, and agents/hooks/workflows are folded into the apex-code and apex-orchestrate rows.)

- [ ] **Task 23: session-context reconciling clause — VERIFY ONLY** — files: `C:/Users/User/.claude/hooks/apex-session-context.md` (**read only — no edit**).
  Mechanism: **PRE-EXECUTED attended 2026-07-29** (live owner confirmation; D3 satisfied — the critical-path gate was cleared by a human, not by this spec). Both insertions are already in the live file: the "harness fact, not a licence" paragraph after the `## Session model (ADR-038)` section, and the D1 tightening line under the `## Model routing (ADR-045)` table, which carries the round-3 git-mechanics clarification (`executing the git operations it directs (worktree commit, path-scoped integration, the user-approved per-spec commit)`). Both were written in the file's own **ASCII double-dash (`--`) style**, not em-dashes.
  **The build makes NO edit to this file.** Run the done-when checks only and report pass/fail; a failure means the live file drifted since 2026-07-29 and must be surfaced, not repaired in-build.
  The live file's `## Model routing (ADR-045)` table also already carries the owner's 2026-07-29 orchestrator amendment — row 32 reads `| Build orchestrator | Opus 5 -- a \`model: opus\` worker runs waves, dispatches coders, routes exit codes (owner amendment 2026-07-29; was Sonnet) |`. That is live and correct; **the build does not touch it either.**
  Done when, against `C:/Users/User/.claude/hooks/apex-session-context.md` (phrases re-grounded against the live text as it now stands): `-SimpleMatch -Pattern 'not a licence','ADR-046 D1','orchestrator-owned','executing the git operations it','owner amendment 2026-07-29; was Sonnet'` matches all five, and `-SimpleMatch -Pattern 'Build orchestrator | Sonnet'` returns **zero** hits.

## Wave plan
Wave 1: [task 1, task 2] | Wave 2: [task 3, task 4, task 5, task 6, task 7, task 8, task 9, task 10, task 11, task 12, task 13, task 14, task 15, task 16, task 17, task 18, task 19, task 20, task 21, task 23 ▸verify-only] | Wave 3: [task 22]

`risk: high` builds run sequentially in the foreground per the parallel-codex supervision gate — the waves express **dependency order**, not a parallelism promise. **Task 23 is verify-only** — pre-executed attended on 2026-07-29, so the build reads and checks it but writes nothing. Task 18 is critical-path and still requires live attended confirmation.

## Permissions

The following NON-CRITICAL actions will run autonomously during build.
Approving this spec approves all of them.
Critical paths are NEVER pre-authorised here (D3, ADR-046). `C:/Users/User/.claude/hooks/apex-session-context.md` classifies critical (deterministic `hooks` path match) and was therefore **pre-executed attended on 2026-07-29 under live owner confirmation** — the build needs **read access only** to it (Task 23 is verify-only; it appears under Verify below, not under Modify). `C:/users/user/apex/AGENTS.md` is host-state critical, so **Task 18 parks under AFK** and needs a live attended confirmation. No `docs/audit/` path appears anywhere in this spec.

### File Operations
| Action | Paths |
|--------|-------|
| Create | C:/users/user/apex/docs/technical/adr/ADR-046-doctrine-audit-resolutions.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-045-four-role-split.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-027-codex-primary-opus-fallback-deepseek-archived.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-028-parallel-codex-dispatch.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-029-cross-spec-parallel-build.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-034-sol-default-coder.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-036-remove-knowledge-layer.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-037-three-context-files.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-038-single-session.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-042-critical-file-confirmation-and-achievable-cross-family.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-030-codex-reasoning-effort-dial.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-031-codex-context-propagation.md |
| Modify | C:/users/user/apex/docs/technical/adr/ADR-032-gpt56-role-split.md |
| Modify | C:/users/user/apex/docs/research/artemis-retro-2026-07-29.md |
| Modify | C:/users/user/apex/ROADMAP.md |
| Modify | C:/users/user/apex/docs/technical/architecture/overview.md |
| Modify | C:/users/user/apex/docs/technical/pin-change-sweep.md |
| Modify | C:/users/user/apex/AGENTS.md |
| Modify | C:/users/user/apex/SKILL-HISTORY.md |
| Modify | C:/users/user/apex/SKILLS.md |
| Modify | C:/Users/User/.claude/skills/apex-governance/SKILL.md |
| Modify | C:/Users/User/.claude/skills/apex-governance/levels/L3.md |
| Modify | C:/Users/User/.claude/skills/apex-governance/levels/L4.md |
| Modify | C:/Users/User/.claude/skills/apex-governance/levels/L5.md |
| Modify | C:/Users/User/.claude/skills/apex-orchestrate/SKILL.md |
| Modify | C:/Users/User/.claude/skills/apex-orchestrate/templates/spec-template.md |
| Modify | C:/Users/User/.claude/skills/apex-orchestrate/templates/status-template.md |
| Modify | C:/Users/User/.claude/skills/apex-orchestrate/templates/AGENTS-template.md |
| Modify | C:/Users/User/.claude/skills/apex-code/SKILL.md |
| Modify | C:/Users/User/.claude/skills/apex-code/references/parallel-codex.md |
| Modify | C:/Users/User/.claude/skills/apex-code/references/codex-observability.md |
| Modify | C:/Users/User/.claude/skills/apex-code/references/codex-review.md |
| Modify | C:/Users/User/.claude/skills/apex-code/references/dispatch-pack.md |
| Modify | C:/Users/User/.claude/skills/apex-code/references/workflow-dispatch.md |
| Modify | C:/Users/User/.claude/skills/apex-code/references/permissions.md |
| Modify | C:/Users/User/.claude/skills/apex-plan/SKILL.md |
| Modify | C:/Users/User/.claude/skills/apex-plan/references/model-routing.md |
| Modify | C:/Users/User/.claude/skills/apex-plan/references/sol-plan-check.md |
| Modify | C:/Users/User/.claude/skills/apex-plan/references/design-workflow.md |
| Modify | C:/Users/User/.claude/skills/apex-plan/references/cheap-mockup-workflow.md |
| Modify | C:/Users/User/.claude/skills/apex-plan/references/design-lane-workflow.md |
| Modify | C:/Users/User/.claude/skills/apex-research/SKILL.md |
| Modify | C:/Users/User/.claude/skills/apex-init/SKILL.md |
| Modify | C:/Users/User/.claude/skills/apex-handoff/SKILL.md |
| Modify | C:/Users/User/.claude/skills/apex-stack/SKILL.md |
| Modify | C:/Users/User/.claude/skills/apex-context-budget/SKILL.md |
| Modify | C:/Users/User/.claude/skills/apex-coding-principles/SKILL.md |
| Modify | C:/Users/User/.claude/skills/apex-coding-principles/references/elaboration.md |
| Modify | C:/Users/User/.claude/skills/apex-skill-author/SKILL.md |
| Modify | C:/Users/User/.claude/skills/apex-skill-author/references/agents-skills-projection.md |
| Modify | C:/Users/User/.claude/agents/code-worker.md |
| Modify | C:/Users/User/.claude/agents/apex-docs-product-agent.md |
| Modify | C:/Users/User/.claude/agents/apex-docs-technical-agent.md |
| Modify | C:/Users/User/.claude/agents/apex-reviewer.md |
| Modify | C:/Users/User/.claude/agents/apex-coder.md |
| Verify only (pre-executed attended) | C:/Users/User/.claude/hooks/apex-session-context.md |
| Modify | C:/Users/User/.claude/workflows/apex-build-wave.js |
| Delete | (none) |

### Commands
| Command | Purpose |
|---------|---------|
| `Select-String -Path <file> -Pattern <regex>` | Per-task done-when grep assertions + acceptance criteria |
| `Get-ChildItem -Path <dir> -Recurse -Include *.md,*.js -File` | Enumerate the swept tree for the cross-tree sweep assertions |
| `@(Get-Content <file>).Count` | Line-cap check, physical lines (SKILL.md ≤500, status template ≤100). `Measure-Object -Line` undercounts and is NOT authorized. |
| Both trees' AGENTS.md verify recipes | Enumerated verbatim in the fence below — this spec authorizes exactly those commands |
| `git status` · `git diff` · `git rev-parse` | Read-only verification of both trees (no staging, no commit, no branch operations) |

The authorized verify recipes, enumerated (apex tree first, then the `~/.claude` tree):

```bash
# apex tree — AGENTS.md ## Verify commands
wc -l ~/.claude/skills/apex-*/SKILL.md | sort -rn | head -3     # no skill over its 500-line cap
grep -roE '~/\.claude/skills/apex-[a-z-]+' ~/.claude/skills/ | sort -u   # no dangling pointers
wc -l docs/status.md          # <=100
wc -l ~/.claude/CLAUDE.md     # <=200
wc -c AGENTS.md               # <=32768
```

```powershell
# ~/.claude tree — AGENTS.md ## Verify commands
node --check hooks/destructive-command-guard.js
node --check hooks/lib/destructive-detect.js
python hooks/destructive-guard-test.py
powershell.exe -NoProfile -File skills/apex-code/scripts/baseline-check-test.ps1
powershell.exe -NoProfile -File skills/apex-code/scripts/spec-validate-test.ps1
powershell.exe -NoProfile -File skills/apex-code/scripts/dispatch-preflight-test.ps1
```

### Git Operations
| Operation | Scope |
|-----------|-------|
| (none) | This spec performs no git operations. The host commits after review, per-spec, on approval. |

### Environment Access
| Variable | Purpose |
|----------|---------|
| `USERPROFILE` | Resolve the `~/.claude` tree on Windows |

### Network
| Action | Purpose |
|--------|---------|
| (none) | No network access. No package installation. |

## Specialist Context
### Security
This spec rewrites governance hard-block wording. The security-bearing invariant: **no hard-block line is removed.** D2, D4, D5, and D8 add named, scoped carve-outs beneath the existing list; D3 narrows what a spec may pre-authorize (a tightening, not a loosening). If a task cannot make an edit without deleting a block line, it is blocked — surface it, do not improvise.

### Performance
(none)

### Accessibility
(none)

## Documentation
| Doc type | File | Action |
|----------|------|--------|
| ADR | C:/users/user/apex/docs/technical/adr/ADR-046-doctrine-audit-resolutions.md | Write (Task 1) |
| ADR | C:/users/user/apex/docs/technical/adr/ADR-045-four-role-split.md | Amend (Task 2) |
| Skill history | C:/users/user/apex/SKILL-HISTORY.md | Add rows (Task 22) |
| Skill index | C:/users/user/apex/SKILLS.md | Update descriptions if changed (Task 22) |
| Changelog | (none) | This repo has no CHANGELOG for the skill system |

## Acceptance Criteria

- [ ] **Task 1** — ADR-046-doctrine-audit-resolutions.md exists and records all eight decisions with their options, the Sol deliberation id, the D5 enforcement gap, the two-check D8 definition with the ancestry exclusion, the D1 verification-ownership split, and the rejected WIP-commit carve-out. Options for D1–D5 are derived from the Conflict column, never invented.

```powershell
$adr = "C:\users\user\apex\docs\technical\adr\ADR-046-doctrine-audit-resolutions.md"
$eight = (Select-String -Path $adr -Pattern '^### D[1-8]').Count -eq 8
$terms = '0e7d2938','doctrine-audit-2026-07-29','apex-critical-files.ps1','merge-base',
         'git status --porcelain','REJECTED','catalogued no further alternatives',
         'destructive-detect.js','retro P5(c)','P1–P7',
         'The host EXECUTES the recipe as mechanics'
$miss = $terms | Where-Object { (Select-String -Path $adr -SimpleMatch -Pattern $_).Count -lt 1 }
if ($eight -and -not $miss) { 'PASS' } else { 'FAIL'; $miss }
```

- [ ] **Task 2** — ADR-045-four-role-split.md carries the dated D1 amendment, its deliberation citation, and a backlink to ADR-046; the historical Opus note is preserved, not deleted.

```powershell
$a45 = "C:\users\user\apex\docs\technical\adr\ADR-045-four-role-split.md"
$miss = 'Amendment — 2026-07-29','0e7d2938','ADR-046','as drafted this row said Opus' |
  Where-Object { (Select-String -Path $a45 -SimpleMatch -Pattern $_).Count -lt 1 }
if (-not $miss) { 'PASS' } else { 'FAIL'; $miss }
```

- [ ] **Task 3** — the apex-governance SKILL carries all four hard-block carve-outs plus the D3 and D6 clauses; every original hard block still has a distinctive substring present (bullet-count alone is not sufficient evidence); the carve-out prose sits below the fence, not inside it; and the stale fallback-reviewer line is corrected.

```powershell
$gov = "$env:USERPROFILE\.claude\skills\apex-governance\SKILL.md"
$need = 'Carve-out (D2','Carve-out (D4','Carve-out (D5','Carve-out (D8','D3, ADR-046',
        'D6, ADR-046','apex-critical-files.ps1','destructive-detect.js',
        'ADR-046-doctrine-audit-resolutions'
$blocks = 'push to main/master','force-push or history rewrite','merging its own PR','DROP TABLE',
          'git branch -d','production secrets','docs/audit/','widens its own controls',
          'Deploying to production','Weakening a security control'
$missNeed = $need | Where-Object { (Select-String -Path $gov -SimpleMatch -Pattern $_).Count -lt 1 }

# --- hard-block preservation: extract the FENCED region under ## Hard blocks and assert INSIDE it ---
$g0 = Get-Content $gov
$hb = ($g0 | Select-String -Pattern '^## Hard blocks').LineNumber          # 1-based
$fenceLines = @()
for ($i = $hb; $i -lt $g0.Count; $i++) { if ($g0[$i] -match '^```') { $fenceLines += $i; if ($fenceLines.Count -eq 2) { break } } }
$fenced = $g0[($fenceLines[0]+1)..($fenceLines[1]-1)]
$bulletCount = @($fenced | Where-Object { $_ -match '^- ' }).Count          # pinned baseline: 9
$missBlocks  = $blocks | Where-Object { $b = $_; -not ($fenced | Where-Object { $_.Contains($b) }) }
$fenceOk = ($bulletCount -ge 9) -and (-not $missBlocks)
$oldAudit = (Select-String -Path $gov -Pattern '^- Any modification to docs/audit/$').Count -eq 0
$oldOpus  = (Select-String -Path $gov -CaseSensitive -SimpleMatch -Pattern 'Opus built').Count -eq 0
$heading  = (Select-String -Path $gov -SimpleMatch `
              -Pattern 'subject only to the named ADR-046 carve-outs below').Count -ge 1
# the live level copies must carry the same carve-out pointers
$l4 = "$env:USERPROFILE\.claude\skills\apex-governance\levels\L4.md"
$l5 = "$env:USERPROFILE\.claude\skills\apex-governance\levels\L5.md"
$lvl = (Select-String -Path $l4 -SimpleMatch -Pattern 'ADR-046').Count -ge 3 -and
       (Select-String -Path $l5 -SimpleMatch -Pattern 'ADR-046').Count -ge 3 -and
       (Select-String -Path $l4,$l5 -Pattern '^- git merge$','^- Deleting files or git branches$',
          '^- Merge any PR$','^- Delete any branch$').Count -eq 0 -and
       # D5 producer restriction present in BOTH audit sections
       (Select-String -Path $l4 -SimpleMatch -Pattern 'route through the host').Count -ge 1 -and
       (Select-String -Path $l5 -SimpleMatch -Pattern 'route through the host').Count -ge 1 -and
       # L5 heading carries the carve-out acknowledgement
       (Select-String -Path $l5 -SimpleMatch `
          -Pattern 'subject only to the named ADR-046 carve-outs below').Count -ge 1 -and
       # L5 spells out the inherited commit gate's scope (it does not inherit it implicitly)
       (Select-String -Path $l5 -SimpleMatch -Pattern 'including the L4 commit gate').Count -ge 1
# carve-out prose sits OUTSIDE the fence: no fenced line may begin with **Carve-out
$g = Get-Content $gov; $inFence = $false; $bad = 0
foreach ($ln in $g) {
  if ($ln -match '^```') { $inFence = -not $inFence; continue }
  if ($inFence -and $ln -match '^\*\*Carve-out') { $bad++ }
}
if (-not $missNeed -and $fenceOk -and $oldAudit -and $oldOpus -and $bad -eq 0 -and
    $heading -and $lvl) { 'PASS' } else { 'FAIL'; $missNeed; $missBlocks; "bullets=$bulletCount" }
```

- [ ] **Task 1** and **Task 3** — D5's enforcement gap is recorded, not papered over: both files name the classifier script, and neither claims agent-side audit-log appends are permitted today.

```powershell
$d5 = @("C:\users\user\apex\docs\technical\adr\ADR-046-doctrine-audit-resolutions.md",
        "$env:USERPROFILE\.claude\skills\apex-governance\SKILL.md",
        "$env:USERPROFILE\.claude\skills\apex-code\references\permissions.md")
$named = $d5 | Where-Object { (Select-String -Path $_ -SimpleMatch -Pattern 'apex-critical-files.ps1').Count -lt 1 }
# the retired over-claiming phrasings, which no shipped file may contain:
$over  = (Select-String -Path $d5 -SimpleMatch `
            -Pattern 'appends are REQUIRED','are required and allowed','permitted and are what').Count
$doct  = $d5 | Where-Object { (Select-String -Path $_ -SimpleMatch -Pattern 'route through the host').Count -lt 1 -and
                              (Select-String -Path $_ -SimpleMatch -Pattern 'route through the **host**').Count -lt 1 }
if (-not $named -and $over -eq 0 -and -not $doct) { 'PASS' } else { 'FAIL'; $named; $doct }
```

- [ ] **Task 1**, **Task 3**, and **Task 7** — the D8 verification algorithm exists in **exactly one** place (ADR-046 § D8), with the worktree/branch split, the wait-for-approved-commit consequence, the delete-Operation rule, and the ancestry exclusion. The two consumers carry a summary sentence and a citation, **not** a second copy.

```powershell
$adr = "C:\users\user\apex\docs\technical\adr\ADR-046-doctrine-audit-resolutions.md"
$gov = "$env:USERPROFILE\.claude\skills\apex-governance\SKILL.md"
$pc  = "$env:USERPROFILE\.claude\skills\apex-code\references\parallel-codex.md"

# canonical copy carries the whole algorithm
$canon = 'git status --porcelain','git diff <branch>..<integration>','NECESSARILY WAITS',
         'ABSENT from both','merge-base --is-ancestor','single canonical home' |
  Where-Object { (Select-String -Path $adr -SimpleMatch -Pattern $_).Count -lt 1 }

# consumers cite it and do NOT restate the algorithm
$cite = 'ADR-046','D8' | Where-Object {
  (Select-String -Path $gov -SimpleMatch -Pattern $_).Count -lt 1 -or
  (Select-String -Path $pc  -SimpleMatch -Pattern $_).Count -lt 1 }
$dup  = (Select-String -Path $gov,$pc -SimpleMatch `
           -Pattern 'git status --porcelain','NECESSARILY WAITS','ABSENT from both').Count
# guard honesty survives in both consumers
$guard = 'destructive-detect.js','retro P5(c)' | Where-Object {
  (Select-String -Path $gov -SimpleMatch -Pattern $_).Count -lt 1 -or
  (Select-String -Path $pc  -SimpleMatch -Pattern $_).Count -lt 1 }
if (-not $canon -and -not $cite -and -not $guard -and $dup -eq 0) { 'PASS' }
else { 'FAIL'; $canon; $cite; $guard; "dup=$dup" }
```

- [ ] **Task 1**, **Task 3**, and **Task 4** — D6 is stated as the SOLE exception to D3 and is scoped to exactly the three host's-pen artifacts; no other unattended critical-path write is introduced anywhere.

```powershell
$adr = "C:\users\user\apex\docs\technical\adr\ADR-046-doctrine-audit-resolutions.md"
$consumers = @("$env:USERPROFILE\.claude\skills\apex-governance\SKILL.md",
               "$env:USERPROFILE\.claude\skills\apex-code\SKILL.md",
               "$env:USERPROFILE\.claude\skills\apex-orchestrate\templates\spec-template.md")

# the three artifacts, asserted INDIVIDUALLY inside ADR-046's D6 section
$a = Get-Content $adr
$s = ($a | Select-String -Pattern '^### D6').LineNumber
$e = ($a | Select-String -Pattern '^### D7').LineNumber
$d6sec = $a[$s..($e-2)] -join "`n"
$missArtifact = 'handoff','docs/status.md','docs/changes/done/' |
  Where-Object { -not $d6sec.Contains($_) }

# the exception-scope sentence, per-file (not aggregate)
$missConsumer = $consumers | Where-Object {
  (Select-String -Path $_ -Pattern 'sole exception','Sole exception').Count -lt 1 }

if (-not $missArtifact -and -not $missConsumer) { 'PASS' }
else { 'FAIL'; $missArtifact; $missConsumer }
```

- [ ] **Task 1**, **Task 7**, **Task 10**, **Task 12**, and **Task 17** — the D1 verification-ownership sentence appears **verbatim** in every one of the five sites where a verify owner is named. Also **Task 12**: the completion-routing table is orchestrator-owned, and **Task 9**'s route rows name the orchestrator and author contracts.

```powershell
$D1 = 'The host EXECUTES the recipe as mechanics from the orchestrator''s wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows.'
$sites = @(
  "C:\users\user\apex\docs\technical\adr\ADR-046-doctrine-audit-resolutions.md",
  "$env:USERPROFILE\.claude\skills\apex-code\references\parallel-codex.md",
  "$env:USERPROFILE\.claude\skills\apex-code\SKILL.md",
  "$env:USERPROFILE\.claude\skills\apex-code\references\dispatch-pack.md",
  "$env:USERPROFILE\.claude\skills\apex-orchestrate\templates\AGENTS-template.md")
$per = $sites | ForEach-Object { (Select-String -Path $_ -SimpleMatch -Pattern $D1).Count }
$dp  = "$env:USERPROFILE\.claude\skills\apex-code\references\dispatch-pack.md"
$rt  = (Select-String -Path $dp -Pattern 'Orchestrator routing').Count -ge 1 -and
       (Select-String -Path $dp -Pattern 'Host action').Count -eq 0
$or  = (Select-String -Path "$env:USERPROFILE\.claude\skills\apex-orchestrate\SKILL.md" `
        -SimpleMatch -Pattern 'build-orchestrator agent contract','author contract').Count -ge 2
if (($per | Where-Object { $_ -lt 1 }).Count -eq 0 -and $rt -and $or) { 'PASS' } else { 'FAIL' }
```

- [ ] **Task 8** — the planning skill no longer tells its reader to draft the spec itself; it dispatches the spec-author worker (the four-role wiring gap).

```powershell
$pl  = "$env:USERPROFILE\.claude\skills\apex-plan\SKILL.md"
$spc = "$env:USERPROFILE\.claude\skills\apex-plan\references\sol-plan-check.md"
$mr  = "$env:USERPROFILE\.claude\skills\apex-plan\references\model-routing.md"
$wired = ('spec-author worker','ADR-045' |
  Where-Object { (Select-String -Path $pl -SimpleMatch -Pattern $_).Count -lt 1 }).Count -eq 0
$noOpus = (Select-String -Path $spc -CaseSensitive -SimpleMatch -Pattern 'Opus').Count -eq 0
$author = (Select-String -Path $spc -SimpleMatch -Pattern "spec AUTHOR's").Count -ge 1
$field  = (Select-String -Path $mr -SimpleMatch -Pattern 'coder_models').Count -eq 0
if ($wired -and $noOpus -and $author -and $field) { 'PASS' } else { 'FAIL' }
```

- [ ] **Task 19** — the commit approval gate survived intact: no AFK bypass wording exists, and the unattended path queues the drafted message instead of committing.

```powershell
$ho = "$env:USERPROFILE\.claude\skills\apex-handoff\SKILL.md"
$bypass = (Select-String -Path $ho -Pattern 'AFK carve-out.{0,40}may take the WIP commit',
             'commit without the live exchange','status.md \+ .docs/changes/done').Count -eq 0
# the phantom column is retired: no `Uncommitted` column may be declared
$noPhantom = (Select-String -Path $ho -SimpleMatch -Pattern 'In-Flight `Uncommitted` column').Count -eq 0 -and
             (Select-String -Path $ho -SimpleMatch -Pattern 'There is no `Uncommitted` column').Count -ge 1
$gate   = (Select-String -Path $ho -CaseSensitive -SimpleMatch `
             -Pattern 'An unattended run does NOT commit').Count -ge 1
if ($bypass -and $gate -and $noPhantom) { 'PASS' } else { 'FAIL' }
```

- [ ] **Task 14** — the older ADRs warn the reader, the inline cap-3 body text is gone from ADR-028-parallel-codex-dispatch.md and ADR-029-cross-spec-parallel-build.md, ADR-037-three-context-files.md no longer says status.md is read by both, and **both** stale retro premise occurrences are corrected.

```powershell
$adrDir = "C:\users\user\apex\docs\technical\adr"
$a28 = "$adrDir\ADR-028-parallel-codex-dispatch.md"
$a29 = "$adrDir\ADR-029-cross-spec-parallel-build.md"
$a37 = "$adrDir\ADR-037-three-context-files.md"
$retro = "C:\users\user\apex\docs\research\artemis-retro-2026-07-29.md"
$stale = (Select-String -Path $a28 -Pattern 'default to \*\*3\*\* when core detection').Count +
         (Select-String -Path $a29 -Pattern '\(3 on this host\)','\(3 here\)').Count +
         # anchored to the TABLE ROW: the required historical note quotes the retired
         # phrase in prose, which must NOT count as residue
         (Select-String -Path $a37 -Pattern '\|\s*Both \(provider-agnostic\)\s*\|').Count +
         (Select-String -Path $retro -SimpleMatch -Pattern 'Opus-fallback-only').Count
$caveat = ((Select-String -Path $a28,$a29 -SimpleMatch -Pattern 'the shipped default is 2').Count -ge 2)
$fixed  = (Select-String -Path $retro -SimpleMatch -Pattern 'Claude-fallback-only').Count -ge 2
# the role-sweep edits in the non-ADR consumers
$rm2 = (Select-String -Path "C:\users\user\apex\ROADMAP.md" -SimpleMatch `
          -Pattern 'Opus 5 orchestrates builds').Count -ge 1
$ov  = "C:\users\user\apex\docs\technical\architecture\overview.md"
$ov2 = (Select-String -Path $ov -SimpleMatch -Pattern 'Build orchestrator (Opus 5)','interim executor',
          'the orchestrator adjudicates','ADR-046 D1').Count -ge 4
$pcs = (Select-String -Path "C:\users\user\apex\docs\technical\pin-change-sweep.md" -SimpleMatch `
          -Pattern 'the amendment convention (ADR-046)').Count -ge 1
if ($stale -eq 0 -and $caveat -and $fixed -and $rm2 -and $ov2 -and $pcs) { 'PASS' } else { 'FAIL' }
```

- [ ] **Task 4**, **Task 8**, **Task 10**, **Task 11**, **Task 12**, **Task 13**, **Task 15**, and **Task 20** — no stale Opus-as-fallback-coder claim survives anywhere in the swept trees. The parked design doc REVIEW-ENSEMBLE-DESIGN.md is out of scope and excluded.

```powershell
# -CaseSensitive is REQUIRED: the ADR-027 filename is lowercase (...opus-fallback-deepseek...)
# and appears in many sources: lines, which would otherwise false-positive this sweep.
$hits = Get-ChildItem "$env:USERPROFILE\.claude\skills","$env:USERPROFILE\.claude\agents",`
  "$env:USERPROFILE\.claude\hooks","$env:USERPROFILE\.claude\workflows" `
  -Recurse -Include *.md,*.js -File |
  Where-Object { $_.Name -ne 'REVIEW-ENSEMBLE-DESIGN.md' } |
  Select-String -CaseSensitive `
    -Pattern 'Opus (built|builds|fallback)','Opus-built','Opus-fallback','fall(s|back)? .{0,12}to Opus'
if (@($hits).Count -eq 0) { 'PASS' } else { 'FAIL'; $hits }
```

- [ ] **Task 4** and **Task 8** — the coder_model enum reads exactly `{codex|sonnet}` everywhere it is declared, with **no `opus` exception clause anywhere** (nothing in the build path implements one).

```powershell
$enumFiles = @("$env:USERPROFILE\.claude\skills\apex-orchestrate\templates\spec-template.md",
               "$env:USERPROFILE\.claude\skills\apex-plan\SKILL.md",
               "$env:USERPROFILE\.claude\skills\apex-plan\references\model-routing.md",
               "$env:USERPROFILE\.claude\skills\apex-code\SKILL.md")
$old = (Select-String -Path $enumFiles -Pattern 'coder_model: \{codex\|opus\}').Count
$new = ("$env:USERPROFILE\.claude\skills\apex-orchestrate\templates\spec-template.md",
        "$env:USERPROFILE\.claude\skills\apex-plan\SKILL.md" |
   Where-Object { (Select-String -Path $_ -Pattern 'codex\|sonnet').Count -lt 1 }).Count -eq 0
# no opus escape hatch documented anywhere in the enum's declaring files
$noEsc = (Select-String -Path $enumFiles -Pattern 'deliberate exception','logged exception',
            'deliberate, logged').Count -eq 0
if ($old -eq 0 -and $new -and $noEsc) { 'PASS' } else { 'FAIL' }
```

- [ ] **Task 4**, **Task 7**, and **Task 14** — the parallel cap default reads 2 everywhere it is stated, in skills and in the ADRs.

```powershell
$capFiles = @("$env:USERPROFILE\.claude\skills\apex-orchestrate\templates\spec-template.md",
              "$env:USERPROFILE\.claude\skills\apex-code\references\parallel-codex.md",
              "$env:USERPROFILE\.claude\skills\apex-code\SKILL.md",
              "C:\users\user\apex\docs\technical\adr\ADR-028-parallel-codex-dispatch.md",
              "C:\users\user\apex\docs\technical\adr\ADR-029-cross-spec-parallel-build.md")
$capStale = (Select-String -Path $capFiles `
  -Pattern 'fallback 3','default to \*\*3\*\*','\(3 on this host\)','\(3 here\)').Count
if ($capStale -eq 0) { 'PASS' } else { 'FAIL' }
```

- [ ] **Task 15** and **Task 20** — no dangling double-bracket memory link remains anywhere under the skills tree, **and every `~/.claude/skills/apex-*` cross-reference resolves to a file or directory that exists** (the apex-tree verify recipe's "no dangling pointers" check, made to actually verify rather than merely list).

```powershell
$skills = "$env:USERPROFILE\.claude\skills"

# (a) no dangling [[memory]] links
$links = Get-ChildItem $skills -Recurse -Include *.md -File |
  Select-String -Pattern '\[\[[a-z0-9-]+\]\]'

# (b) every skill/reference pointer resolves — extract, dedupe, Test-Path each
$refs = Get-ChildItem $skills -Recurse -Include *.md -File |
  Select-String -Pattern '~/\.claude/(skills|agents|hooks|workflows)/[A-Za-z0-9._/-]+' -AllMatches |
  ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } |
  Sort-Object -Unique
$missing = foreach ($r in $refs) {
  $abs = $r -replace '^~/', ($env:USERPROFILE -replace '\\','/') + '/'
  if (-not (Test-Path -LiteralPath $abs)) { $r }
}

if (@($links).Count -eq 0 -and -not $missing) { 'PASS' }
else { 'FAIL'; $links; 'unresolved pointers:'; $missing }
```

- [ ] **Task 7** and **Task 11** — no raw codex exec recipe is presented as a command to run; all three reference files show the wrapper invocation, the wrapper is stated as the only path attended or not, and the dangling sandbox-ownership pointer is retargeted.

```powershell
$refs = "$env:USERPROFILE\.claude\skills\apex-code\references"
$all3 = "$refs\parallel-codex.md","$refs\codex-observability.md","$refs\codex-review.md"
$noRaw   = (Select-String -Path $all3 -Pattern 'printf').Count -eq 0
$wrapper = ($all3 | ForEach-Object { (Select-String -Path $_ -Pattern 'codex-dispatch.ps1').Count } |
             Where-Object { $_ -lt 1 }).Count -eq 0
$obs = "$refs\codex-observability.md"
$always  = (Select-String -Path $obs -Pattern 'For AFK/unattended builds').Count -eq 0 -and
           (Select-String -Path $obs -Pattern 'the \*\*only\*\* dispatch path').Count -ge 1
$ptr     = (Select-String -Path "$refs\parallel-codex.md" -Pattern 'Windows sandbox artifact ownership').Count -eq 0
$commit  = (Select-String -Path "$refs\parallel-codex.md" -Pattern 'First commit the worktree to its task branch').Count -ge 1
$perm = "$refs\permissions.md"
$pfix = (Select-String -Path $perm -Pattern 'At L4\+, append every action').Count -eq 0 -and
        (Select-String -Path $perm -Pattern 'never edits permissions').Count -ge 1
if ($noRaw -and $wrapper -and $always -and $ptr -and $commit -and $pfix) { 'PASS' } else { 'FAIL' }
```

- [ ] **Task 2**, **Task 14**, and **Task 22** — ADR-046 is reachable from all eleven amended ADRs, so a reader entering through an older one is warned; and the two prose consumers (ROADMAP.md, SKILLS.md) no longer name Opus as the fallback coder.

```powershell
$adrDir = "C:\users\user\apex\docs\technical\adr"
$eleven = @(
 "$adrDir\ADR-027-codex-primary-opus-fallback-deepseek-archived.md",
 "$adrDir\ADR-028-parallel-codex-dispatch.md",
 "$adrDir\ADR-029-cross-spec-parallel-build.md",
 "$adrDir\ADR-030-codex-reasoning-effort-dial.md",
 "$adrDir\ADR-031-codex-context-propagation.md",
 "$adrDir\ADR-032-gpt56-role-split.md",
 "$adrDir\ADR-034-sol-default-coder.md",
 "$adrDir\ADR-036-remove-knowledge-layer.md",
 "$adrDir\ADR-038-single-session.md",
 "$adrDir\ADR-042-critical-file-confirmation-and-achievable-cross-family.md",
 "$adrDir\ADR-045-four-role-split.md")
$noLink = $eleven | Where-Object {
  (Select-String -Path $_ -SimpleMatch -Pattern 'ADR-046-doctrine-audit-resolutions').Count -lt 1 }
# the two non-ADR consumers carrying the same stale claim
$rm = (Select-String -Path "C:\users\user\apex\ROADMAP.md" -SimpleMatch -Pattern 'Opus fallback').Count -eq 0
$sk = "C:\users\user\apex\SKILLS.md"
$sk1 = (Select-String -Path $sk -SimpleMatch -Pattern 'Opus on fallback').Count -eq 0
# Task 22's second unconditional edit: the apex-coder agent row is qualified fallback-only
$sk2 = (Select-String -Path $sk -SimpleMatch -Pattern 'Claude-fallback path only').Count -ge 1
if (-not $noLink -and $rm -and $sk1 -and $sk2) { 'PASS' } else { 'FAIL'; $noLink }
```

- [ ] **Task 17** and **Task 18** — the dead spec-schema headings are gone from both AGENTS contracts, and both now point at the live Tasks/Verify-commands schema.

```powershell
$agents = "C:\users\user\apex\AGENTS.md"
$tmpl   = "$env:USERPROFILE\.claude\skills\apex-orchestrate\templates\AGENTS-template.md"
$D1 = 'The host EXECUTES the recipe as mechanics from the orchestrator''s wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows.'
$dead = (Select-String -Path $agents,$tmpl -SimpleMatch `
   -Pattern '## Exact changes','## Commands to run','move it to `docs/changes/done/`').Count
$queue = (Select-String -Path $tmpl -SimpleMatch -Pattern 'ADR-029','foreground and sequential').Count -ge 2
$verb  = (Select-String -Path $tmpl -SimpleMatch -Pattern $D1).Count -ge 1
$live  = (Select-String -Path $agents -SimpleMatch -Pattern '## Verify commands').Count -ge 1
# the coder never archives — D6 puts spec archival on the host's-pen side, in BOTH contracts
$arch  = ($agents,$tmpl | Where-Object {
   (Select-String -Path $_ -SimpleMatch -Pattern 'Never move or archive a spec').Count -lt 1 -or
   (Select-String -Path $_ -SimpleMatch -Pattern 'D6, ADR-046').Count -lt 1 }).Count -eq 0
if ($dead -eq 0 -and $queue -and $verb -and $live -and $arch) { 'PASS' } else { 'FAIL' }
```

- [ ] **Task 6** — the technical docs agent matches the live handoff template: the ADR-006-era recipe read and the five removed sections are gone, the four narrative sections are present, the D6 role boundary and the product-status input are wired, and **the overview promise is retired — the agent file mentions `overview.md` nowhere at all**.

```powershell
$dta = "$env:USERPROFILE\.claude\agents\apex-docs-technical-agent.md"
$dead = (Select-String -Path $dta -SimpleMatch `
  -Pattern 'stack_skills','ADR-006','What Was Built','Specs Completed','Documentation Status').Count
$miss = 'Decisions Made','Specialist Flags','Blocked Actions','D6, ADR-046',
        'docs_product_summary','completed_with_skips' |
  Where-Object { (Select-String -Path $dta -SimpleMatch -Pattern $_).Count -lt 1 }
# the overview promise is RETIRED — this agent must not mention it at all
$retired = (Select-String -Path $dta -SimpleMatch -Pattern 'overview.md').Count -eq 0
if ($dead -eq 0 -and -not $miss -and $retired) { 'PASS' } else { 'FAIL'; $miss }
```

- [ ] **Task 10** — the docs-product agent is dispatched only after the reviewer returns (the category-8 race fix), the digest-binding known limit is stated and points at the retro set, D6's scope-lock exception and the host-review step are in the executable flow, the verify section carries the D1 ownership split verbatim plus the interim-executor framing, the fork path re-issues the scope lock, and the skill stays inside its physical line cap. **The material descoped on 2026-07-30 must be absent.**

```powershell
$D1 = 'The host EXECUTES the recipe as mechanics from the orchestrator''s wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows.'
$ac = "$env:USERPROFILE\.claude\skills\apex-code\SKILL.md"
$stale = (Select-String -Path $ac -SimpleMatch `
   -Pattern '**In parallel:**','Serialized — docs first','Run the recipe **per task**, not once at the end',
            'same tree by construction','passes by construction','outside the wrapper ledger',
            'never family-gate-bound','enumerates every post-review write',
            'remains accepted for a deliberate exception',"the spec's ``## Commands to run``").Count
$need  = 'Serialized — the reviewer first','only after the reviewer has returned',
         'Known limit — digest binding','artemis-retro-2026-07-29.md',
         'Host review of docs-agent output','permitted post-build writes outside','Two cadences',
         're-issued','Sole exception (D6, ADR-046)','interim executor' |
  Where-Object { (Select-String -Path $ac -SimpleMatch -Pattern $_).Count -lt 1 }
$verb  = (Select-String -Path $ac -SimpleMatch -Pattern $D1).Count -ge 1
$cap   = @(Get-Content $ac).Count -le 500      # physical lines; Measure-Object -Line undercounts
if ($stale -eq 0 -and -not $need -and $verb -and $cap) { 'PASS' } else { 'FAIL'; $need }
```

- [ ] **Task 5** — the code-worker contract allows a spec-authorized delete and nothing wider, and the product docs agent reads the live spec section and reports off-scope skips.

```powershell
$cw = "$env:USERPROFILE\.claude\agents\code-worker.md"
$pa = "$env:USERPROFILE\.claude\agents\apex-docs-product-agent.md"
$stale = (Select-String -Path $cw -SimpleMatch -Pattern 'Never delete anything').Count +
         (Select-String -Path $pa -SimpleMatch -Pattern '## Scope').Count
$live  = (Select-String -Path $cw -SimpleMatch -Pattern 'Operation: delete').Count -ge 1 -and
         (Select-String -Path $cw -SimpleMatch -Pattern '## Verify commands').Count -ge 1 -and
         (Select-String -Path $pa -SimpleMatch -Pattern 'skipped_off_scope').Count -ge 1 -and
         (Select-String -Path $pa -SimpleMatch -Pattern 'completed_with_skips').Count -ge 1
if ($stale -eq 0 -and $live) { 'PASS' } else { 'FAIL' }
```

- [ ] **Task 9** — the orchestrator's routing table wires both ADR-045 dispatches and cites ADR-046.

```powershell
$orc = "$env:USERPROFILE\.claude\skills\apex-orchestrate\SKILL.md"
$miss = 'build orchestrator','spec author','build-orchestrator agent contract','author contract',
        'interim executor','ADR-046-doctrine-audit-resolutions' |
  Where-Object { (Select-String -Path $orc -SimpleMatch -Pattern $_).Count -lt 1 }
if (-not $miss) { 'PASS' } else { 'FAIL'; $miss }
```

- [ ] **Task 16** — the status template points at the hook file for model routing, and the init skill drops the removed session mode and **both** occurrences of the ADR-037 contradiction.

```powershell
$tpl = "$env:USERPROFILE\.claude\skills\apex-orchestrate\templates\status-template.md"
$ini = "$env:USERPROFILE\.claude\skills\apex-init\SKILL.md"
$stale = (Select-String -Path $tpl -Pattern 'Model routing.*CLAUDE\.md').Count +
         (Select-String -Path $ini -Pattern 'Mode: planning','loaded by every new agent').Count
$live  = (Select-String -Path $tpl -SimpleMatch -Pattern 'apex-session-context.md').Count -ge 1 -and
         (Select-String -Path $ini -SimpleMatch -Pattern 'ADR-037').Count -ge 1 -and
         (Select-String -Path $ini -SimpleMatch -Pattern 'Codex never reads it').Count -ge 1
if ($stale -eq 0 -and $live) { 'PASS' } else { 'FAIL' }
```

- [ ] **Task 21** — the projection reference no longer contradicts itself on card provenance or the recipe's home, and its owning skill carries the version bump.

```powershell
$proj = "$env:USERPROFILE\.claude\skills\apex-skill-author\references\agents-skills-projection.md"
$sa   = "$env:USERPROFILE\.claude\skills\apex-skill-author\SKILL.md"
$stale = (Select-String -Path $proj -Pattern 'projected sections','status.md . AGENTS.md').Count
$live  = ('no source APEX skill','its single home, ADR-037' |
  Where-Object { (Select-String -Path $proj -SimpleMatch -Pattern $_).Count -lt 1 }).Count -eq 0
$bump  = (Select-String -Path $sa -SimpleMatch -Pattern 'version: 2.0.3').Count -ge 1
if ($stale -eq 0 -and $live -and $bump) { 'PASS' } else { 'FAIL' }
```

- [ ] **Task 23** — **pre-executed attended 2026-07-29; the build verifies read-only and writes nothing.** The live session-context file carries the reconciling clause, the D1 tightening with its git-mechanics list, and the Opus-orchestrator row. A failing check means the live file drifted after 2026-07-29 — surface it, do not repair it in-build.

```powershell
$sc = "$env:USERPROFILE\.claude\hooks\apex-session-context.md"
$miss = 'not a licence','ADR-046 D1','orchestrator-owned','executing the git operations it',
        'owner amendment 2026-07-29; was Sonnet' |
  Where-Object { (Select-String -Path $sc -SimpleMatch -Pattern $_).Count -lt 1 }
$stale = (Select-String -Path $sc -SimpleMatch -Pattern 'Build orchestrator | Sonnet').Count
if (-not $miss -and $stale -eq 0) { 'PASS' } else { 'FAIL — live file drifted since 2026-07-29'; $miss }
```

- [ ] **Task 22** — the bookkeeping double-write landed: one dated row per meaningfully-updated skill, sourced to ADR-046, prepended above the previously-newest row.

```powershell
$sh = "C:\users\user\apex\SKILL-HISTORY.md"
$new = (Select-String -Path $sh -SimpleMatch -Pattern 'ADR-046-doctrine-audit-resolutions' |
          Select-Object -First 1).LineNumber
$old = (Select-String -Path $sh -Pattern 'all 14 apex-\* skills \+ brandkit/design-motion-principles' |
          Select-Object -First 1).LineNumber
$ordered = $new -lt $old
$skills = 'apex-governance','apex-code','apex-handoff','apex-orchestrate','apex-plan','apex-research',
          'apex-init','apex-stack','apex-context-budget','apex-skill-author','apex-coding-principles'
# one DISTINCT row per skill: collect each skill's first matching row line, require all distinct
$rows = @{}
foreach ($s in $skills) {
  # the row must name the skill AND cite ADR-046 — otherwise the pre-existing
  # 2026-07-29 aggregate row ("all 14 apex-* skills ...") would satisfy every skill
  $m = Select-String -Path $sh -Pattern "^\| 2026-07-29 \|.*$s.*ADR-046" | Select-Object -First 1
  if ($m) { $rows[$s] = $m.LineNumber }
}
$allPresent = $rows.Count -eq $skills.Count
$allDistinct = (@($rows.Values | Sort-Object -Unique).Count -eq $rows.Count)
# each mandated minor bump must appear IN ITS OWN skill's row, not merely in the file
$bumps = @{ 'apex-governance'='2.3.0'; 'apex-code'='2.13.0'; 'apex-handoff'='1.7.0';
            'apex-orchestrate'='2.1.0'; 'apex-plan'='2.2.0' }
$missBump = $bumps.Keys | Where-Object {
  $ln = $rows[$_]; -not $ln -or -not ((Get-Content $sh)[$ln-1]).Contains($bumps[$_]) }
if ($ordered -and $allPresent -and $allDistinct -and -not $missBump) { 'PASS' }
else { 'FAIL'; $rows; $missBump }
```

- [ ] **Every task, Task 1 through Task 23** — no file is owned by two tasks. The Files-to-Change table holds **57** rows and **57** *distinct* paths, and the Permissions File Operations table matches it as a set. **Reasoning note:** per-task file-list disjointness was machine-verified at plan time (each task's `files:` clause extracted, sorted, compared); table-level uniqueness plus Files-to-Change ↔ Permissions set equality is the runnable proxy the build re-checks, since the task bodies are prose and their extraction is not robust enough to gate on.

```powershell
# resolve dynamically — promotion moves the spec from drafts/ to changes/ before the build
$spec = @("C:\users\user\apex\docs\changes\doctrine-sweep.md",
          "C:\users\user\apex\docs\drafts\doctrine-sweep.md",
          "C:\users\user\apex\docs\changes\done\doctrine-sweep.md") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $spec) { 'FAIL — spec not found'; return }
$txt  = Get-Content $spec

# Files-to-Change rows, and their uniqueness
$ftc = $txt | Select-String -Pattern '^\| (C:/\S+) \|' | ForEach-Object { $_.Matches[0].Groups[1].Value }
# Permissions File Operations rows (the action cell may carry a conditional note)
# action cell may read Create / Modify / "Verify only (pre-executed attended)"
$perm = $txt | Select-String -Pattern '^\| (?:Create|Modify|Verify)[^|]*\| (C:/\S+) ' |
  ForEach-Object { $_.Matches[0].Groups[1].Value }

$ftcU = @($ftc | Sort-Object -Unique); $permU = @($perm | Sort-Object -Unique)
$counts = (@($ftc).Count -eq 57) -and ($ftcU.Count -eq 57) -and
          (@($perm).Count -eq 57) -and ($permU.Count -eq 57)
$equal  = @(Compare-Object $ftcU $permU).Count -eq 0
if ($counts -and $equal) { 'PASS' } else { 'FAIL'; @($ftc).Count; @($perm).Count; Compare-Object $ftcU $permU }
```

## Progress
_(The build writes here — do not edit manually)_
