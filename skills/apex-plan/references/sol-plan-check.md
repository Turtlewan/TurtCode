# Sol plan-check gate + cross-model deliberation (ADR-032)

Runs after the readiness gate, before an applicable Deep Details spec moves to `docs/changes/`.
For a gpt-6-sol-authored spec (ADR-048), the Claude `apex-critic` in spec mode is the cross-family
check; this gpt-6.1-sol cold read (the wrapper default) is an independent same-family read.

## The cold read (the gate)

**Trigger:** Low and doc-only specs skip this read; Medium and High retain one independent, fresh,
stateless read per spec. An explicit `risk: high` overrides doc-only, and an unresolved High BLOCK
remains blocking.

```powershell
# Raw `codex exec` is guard-blocked (W2, 2026-07-17) — dispatch through the wrapper:
$digest = (git hash-object <spec-path>)   # record this in the round row BEFORE dispatching
$prompt = "SPEC-DIGEST: $digest`n`n" + "<prompt below>" + "`n`n---`nSPEC:`n`n" + (Get-Content -Raw <spec-path>)
& "$env:USERPROFILE\.claude\skills\apex-code\scripts\codex-dispatch.ps1" `
  -Spec <spec-name> -Task 'plan-check' -Phase review -Worktree <project-repo> `
  -BaseSha <repo HEAD> -Schema review -Effort xhigh -SkipScopeCheck -Prompt $prompt
# Exit 67 = BLOCK verdict (findings in the printed .final report path); 0 = CLEAN/FLAG-only.
# Concurrent read-only checks into one repo: add -AllowSharedWorktree
#   -AllowSharedWorktreeReason 'concurrent read-only plan-checks; no writes possible'.
```

Prompt shape: *"You are an independent plan reviewer. Review this APEX spec against the repo
for: internal contradictions, acceptance criteria a builder cannot verify as written, missing
producing mechanisms, files/anchors that don't exist, hazards the tasks don't cover, and
simpler structures that meet the same criteria. Findings as BLOCK (spec will fail or build the
wrong thing) / FLAG (planning should decide) / CLEAN, each with file/line + rationale. Judge
the spec, do not rewrite it. Do not open docs/drafts/*.review.log."*

- **Input = spec + repo evidence only.** Never the spec AUTHOR's or the host's self-review notes, reviewer findings, or
  planning-discussion text — the cold first read is sacred (evaluator independence).
- `--sandbox read-only` + no profile: Sol can inspect the repo, writes nothing. **Sol never
  edits the spec.** Accepted amendments go to the author in an `-AuthorSpec` revise dispatch with
  `-ExpectedDigest` (apex-plan, Writing the spec); planning does not edit the draft.
- Effort `xhigh` — the standing DEFAULT (retro P7(a); the drop from `max` pre-authorized in this
  file has been taken, and xhigh's named use case is review). A per-spec rubric may still override
  UPWARD to `max` for a known-hard spec — that remains legal; never below `xhigh`.
- Every plan-check dispatch appends its own digest-bound row (Round token `sol-N`) to
  `docs/drafts/<short-name>.review.log` (apex-plan § Convergence control). Plan-check rows are
  separate from the Critic spec-mode 3-round cap, but the `SPEC-DIGEST` header line is still
  mandatory, and a verdict whose digest no longer matches at adjudication is VOID. Plan-check
  repair cycling is bounded by the announced pass-or-park rule, not by that cap.

## Disposition

| Spec | Sol verdict | Action |
|---|---|---|
| any | CLEAN | proceed to ready |
| routine | FLAG / BLOCK | advisory — resolve or explicitly accept with reasoning (verify-before-implementing: findings can be wrong; rebut with evidence, no performative agreement) |
| `risk: high` | BLOCK | **blocking** — the spec does not move to ready with an unresolved Sol BLOCK; resolve, or run deliberation, or the user overrides explicitly. This path is an **approval gate** (apex-governance § Approval gate format), not an advisory review — the "review" label stays with the advisory rows |

Terminology: this gate reviews *plans* and is distinct from the build-side `cross_model_review`
frontmatter flag (code review — apex-governance § Cross-model review).

## Tier 1 deliberation — high-risk specs only, never auto-runs

Trigger: the **user asks, or the host suggests it and asks — every time** (Council offer-only
rule, ADR-010). Protocol:
1. The host answers each finding into the *same* Sol conversation — **amend** (accept; the change
   goes to the author through an `-AuthorSpec` revise dispatch with `-ExpectedDigest`; the host
   never edits the draft) or **rebut with evidence** — via `codex exec resume <session-id>` (session id from the
   dispatch's event stream; fallback if resume is unavailable: fresh dispatch carrying the
   prior findings + responses verbatim).
2. **≤2 rounds** (ADR-015 cap). Termination is NOT consensus — each finding ends as exactly one of:
   `accepted` (amendment sent to the author) · `withdrawn` (Sol retracts — the resolution table MUST cite the
   specific evidence that moved it; an uncited withdrawal is conversational capitulation, record
   it as DISPUTED instead) · `DISPUTED` (both positions stated → **the user arbitrates**).
3. The resolution table's invariants go to the author through an `-AuthorSpec` revise dispatch with
   `-ExpectedDigest`, which lands them in the spec's `## Intent` block; the host adjudicates and
   never edits the draft.
4. **Anti-collusion valve:** disputes surface, never negotiate away — "split the difference"
   is forbidden; no movement on evidence → DISPUTED → user (apex-governance § Evaluator independence).

Every deliberation dispatch — `codex exec resume` or the fresh-dispatch fallback — appends its own
digest-bound row (Round token `delib-N`) to the same `docs/drafts/<short-name>.review.log`, carrying the `SPEC-DIGEST` line
and auto-VOIDing on a digest mismatch exactly as the cold read does. The ≤2-round Tier 1 cap
(ADR-015) still bounds deliberation. **No plan-check-family dispatch may occur outside the sidecar
record** — an unrecorded round is a protocol violation, not a shortcut.

## Tier 2 — blind dual-draft (user-invoked ONLY)

For the rarest, biggest decisions. Both models draft from the same problem brief independently
(neither sees the other's draft) → exchange → ≤2 critique rounds → a **merge doc** of
agreements + disputes for the user's final call. The host never suggests Tier 2 proactively.

## Pre-draft architecture pass (ADR-032 §1b)

Runs BEFORE the spec author is dispatched.

**Trigger:** Low and doc-only specs skip this pass; Medium and High retain it in addition to the
cold read above, never as a replacement. An explicit `risk: high` overrides doc-only, and an
unresolved High BLOCK remains blocking. Same wrapper, same read-only Sol; different input,
different lens: it judges the PLAN, and no spec exists yet.

```powershell
# $planBrief = a REQUIRED `risk:` field (host-assigned at plan time) + problem statement +
#   proposed structure + file map (path, operation, one-line role). Nothing else: no host
#   self-review notes, no prior reviewer findings.
# ROW FIRST, THEN DISPATCH — create docs/drafts/<short-name>.review.log only if absent, else APPEND
#   the plan-check-family row (Round token `arch-N`), carrying the same digest value used below.
$digest = '— (pre-draft)'   # initial pass: no draft exists, so there is nothing to hash
# Re-plan against a LIVE draft instead: $digest = (git hash-object <draft>), and APPEND that draft
#   to $prompt after the brief — the hash must bind what the reviewer actually reads.
$prompt = "SPEC-DIGEST: $digest`n`n" + "<prompt below>" + "`n`n---`nPLAN BRIEF:`n`n" + $planBrief
& "$env:USERPROFILE\.claude\skills\apex-code\scripts\codex-dispatch.ps1" `
  -Spec <short-name> -Task 'arch-check' -Phase review -Worktree <project-repo> `
  -BaseSha <repo HEAD> -Schema review -Effort xhigh -SkipScopeCheck -Prompt $prompt
# Exit contract (codex-dispatch.ps1:1793-1795, :2052-2053): 0 = CLEAN · 68 = done_with_concerns
#   (FLAG-only) · 67 = BLOCK. Findings are in the printed .final report path.
# Concurrent read-only checks into one repo: add -AllowSharedWorktree
#   -AllowSharedWorktreeReason 'concurrent read-only plan-checks; no writes possible'.
```

Prompt shape: *"You are an independent architecture reviewer. What follows is a PLAN, not a spec —
no spec has been written yet. Review the proposed structure against the repo for: wrong
decomposition, a structure that cannot produce the stated outcome, missing or misplaced boundaries,
a file map that fights the repo's existing seams, and simpler structures that meet the same goal.
Findings as BLOCK (the plan will build the wrong thing) / FLAG (planning should decide) / CLEAN,
each with file/line + rationale. Judge the plan, do not write it."*

- **Disposition:** advisory for routine specs; **blocking for `risk: high`**. The blocking path is
  an **approval gate**: on an unresolved arch-pass BLOCK for a `risk: high` plan, print the
  **apex-governance § Approval gate** banner and get the explicit `Approve? [y / n / edit]` answer
  **BEFORE any spec-author dispatch**. Adjudicate findings into the PLAN before dispatching the
  author. Sol never writes the plan and never edits the spec.
- **The cold read stays cold.** Never pass this pass's findings, the host's answers to them, or the
  fact that it ran into the post-readiness dispatch above — evaluator independence. The pre-draft
  pass and post-readiness read use the same tier trigger: Low and doc-only skip both; Medium and
  High retain both. Neither substitutes for the other.
- **The cold-read prompt excludes the sidecar — discovery, not just delivery.** The prompt shape in
  § The cold read above now ends with `Do not open docs/drafts/*.review.log.` The sidecar carries
  prior findings, this pass's among them, so a cold reader that opens it is no longer cold.
- **Round record — ALWAYS WHEN DISPATCHED.** Every arch-check dispatch creates (only when absent) or appends to
  `docs/drafts/<short-name>.review.log` (short-name fixed at plan time) with a normal `arch-N` row on
  apex-plan § Convergence control's terms — separate from the Critic spec-mode 3-round cap and
  bounded by pass-or-park. `Spec digest` = the literal `— (pre-draft)` when no draft exists yet, or the real
  `git hash-object` digest when re-planning against a live draft: a value convention inside the
  existing row schema, not a schema change, and no counting rule moves. **While the cell holds the
  `— (pre-draft)` sentinel the digest-mismatch/VOID check is a DEFINED NO-OP** — no file exists to
  re-hash, so the check is inapplicable, not failed — and it reactivates the moment a real hash is
  recorded. No row is ever overwritten or recreated; Round tokens and counting follow apex-plan
  § Convergence control.
- **A sidecar with no matching draft is NORMAL, never "abandoned".** Between this pass and the
  author's first draft, a `.review.log` with no `.md` sibling is the expected state: nothing
  auto-classifies it as abandoned and nothing sweeps it. A later plan reusing the same short-name
  APPENDS to the existing sidecar — lifetime records stay conservatively intact. Cleanup happens
  only at promotion to `docs/changes/` (§ Closing the session's deletion step) or by explicit owner
  action.
- **Dispatch is digest-bound.** The prompt's first line is `SPEC-DIGEST: <value>` — the sentinel on
  an initial pass, the real `git hash-object` of the draft on a re-plan, with that draft attached to
  the prompt after the brief so the hash binds what the reviewer actually reads.
