# Sol plan-check gate + cross-model deliberation (ADR-032)

Runs after the readiness gate, before an applicable Deep Details spec moves to `docs/changes/`.
For a gpt-6.1-sol-authored spec (ADR-048), the Claude `apex-critic` in spec mode is the cross-family
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
the spec, do not rewrite it. Do not open docs/drafts/*.review.log, docs/drafts/*.findings.json or docs/plans/."*

- **Input = spec + repo evidence only.** Never the spec AUTHOR's or the host's self-review notes, reviewer findings, or
  planning-discussion text — the cold first read is sacred (evaluator independence).
- `--sandbox read-only` + no profile: Sol can inspect the repo, writes nothing. **Sol never
  edits the spec.** Accepted amendments go to the author in an `-AuthorSpec` revise dispatch with
  `-ExpectedDigest` (apex-plan, Writing the spec); planning does not edit the draft.
- Effort `xhigh` — the standing DEFAULT (retro P7(a); the drop from `max` pre-authorized in this
  file has been taken, and xhigh's named use case is review). A per-spec rubric may still override
  UPWARD to `max` for a known-hard spec — that remains legal; never below `xhigh`.
- Every plan-check dispatch appends its own digest-bound `sol-N` row to
  `docs/drafts/<short-name>.review.log` (apex-plan § Convergence control). Sol rows are separate
  from the reviewer-family risk-tier ceiling: Low 3 / Medium 5 / High 10 non-VOID Critic spec-mode
  rows per spec lifetime (doc-only Low unless explicit High). The `SPEC-DIGEST` header remains
  mandatory; a digest mismatch at adjudication makes the verdict VOID. Sol dispatches remain
  bounded by the announced pass-or-park rule. A Medium or High post-readiness cold-read BLOCK
  is adjudicated and fixed by author revise, then reviewed by Critic against
  that same reviewer-family ceiling: a full fresh round 1 without prior non-VOID reviewer-family findings, otherwise a fix check. Continue automatically under it; ask the OWNER only when
  an open BLOCK or required FLAG-fix confirmation would require a round beyond the ceiling:
  (a) accept and promote, (b) exactly one further fix-and-review cycle, (c) park or kill, recorded
  as an `owner` row. Once that extra cycle has been used for a spec, any later escalation, including a post-readiness Sol cold-read BLOCK, offers only (a) accept and promote or (c) park or kill.

## Disposition

| Spec | Sol verdict | Action |
|---|---|---|
| any | CLEAN | proceed to ready |
| routine | FLAG | advisory — resolve or explicitly accept with reasoning (verify-before-implementing: findings can be wrong; rebut with evidence, no performative agreement) |
| Medium or High | BLOCK | HOST adjudicates and sends accepted fixes through author revise, then a Critic review against the same reviewer-family risk-tier ceiling (full fresh round 1 without prior non-VOID reviewer-family findings, otherwise a fix check); OWNER escalation only at that ceiling under apex-plan § Convergence control |
| `risk: high` | unresolved BLOCK | promotion remains blocked unless the OWNER accepts the open finding under the ceiling disposition; optional deliberation retains its existing user-invoked ≤2-round budget |

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

## Planning gate check

Big changes use this gate BEFORE spec authoring. The HOST creates the C2 plan path,
`docs/plans/<plan>.md`, in the spec-owning repo BEFORE the first gate dispatch.
It contains the one-screen Big plan brief,
a slices table with columns slice-id / spec name / wave / size / risk / predicted files,
one `### Slice <slice-id>` section per slice containing that slice's intent, predicted files,
and cited map sections, cross-slice contracts, and an empty gate-record table:

| Round | Dispatched (UTC) | Reviewer | Plan digest | Verdict | Disposition |
|---|---|---|---|---|---|

The brief pastes the cited map sections of every target code repo: the wrapper runs in the
spec-owning repo and may not see target code. Set the one-screen brief as the review input.
Request design, contract, grounding, and decision findings, not wording findings.
Keep `codex-review-schema.json` unchanged: `severity` carries `BLOCK` / `FLAG` / `CLEAN`,
and `criterion` begins with `design:`, `contract:`, `grounding:`, or `decision:`.

Dispatch gpt-6.1-sol at xhigh through
`codex-dispatch.ps1 -Spec <plan> -Task gate-check -Phase review -Worktree <spec-owning repo> -BaseSha <HEAD> -Schema review -Effort xhigh -SkipScopeCheck -Prompt $prompt`.
The prompt's first line is `SPEC-DIGEST: <git hash-object of the plan file at dispatch>`.
The wrapper's default model is gpt-6.1-sol; Sol is read-only and never writes the plan.

Use `gate-N` Round tokens and the sidecar's two-phase row lifecycle. Bind the digest to the
plan content before appending its own pending gate row. At dispatch append a row with Round,
Dispatched (UTC), Reviewer, and Plan digest filled, with Verdict and Disposition both `pending`.
At adjudication reconstruct the dispatch-time plan by omitting this gate row entirely,
including its lifecycle cells, and compare its hash to the recorded Plan digest. Preserve the
remaining content byte-for-byte when reconstructing it; prior gate rows remain included.
Any hash mismatch at adjudication makes the read `VOID` and discards its findings unread.

At adjudication complete that same row with the returned JSON `verdict` field of
`codex-review-schema.json` (BLOCK / FLAG / CLEAN as the schema defines it) and the outcome.
A gate dispatch that the wrapper refuses, times out, or declares VOID (including a tree-pin VOID,
exit 69), or that returns no parseable review JSON, completes its pending row with Disposition `VOID`;
record Verdict as `—` when no valid review verdict exists. A digest-mismatch read also completes
its pending row with Disposition `VOID`; do not inspect its findings to obtain a verdict.
A VOID row does not count toward the two-read budget, and the HOST may re-dispatch the same read.
This planning gate is the one exception to `No plan-check-family dispatch may occur outside the sidecar record`: its record is the plan file's gate-record table.

After each row's adjudication, the HOST rules on every non-VOID finding once in writing in the
plan: accept with the resulting change, or reject with evidence and reasoning. Allow a second
read only when the approach changed, scoped to the changed section; maximum two reads per gate
cycle. Then pass or park both sides for the owner, retaining rejected findings and unresolved
disagreements for the owner's decision.

Before any slice-author dispatch, render the apex-governance § Approval gate banner:

```text
Action: <approve the Big plan and authorize slice spec authoring>
Scope: <plan path, target repos, slices and waves>
Risks: <remaining risks, rejected findings and disputed positions>
Rollback: <how to withdraw or revise the plan>
Approve? [y / n / edit]
```

Attach the one-screen brief containing goal, approach and rejected alternatives, system changes
with cited map sections, slices table with slice-id / spec name / wave / size / risk / predicted files,
check summary including rejected findings, and decisions with proposals. Obtain the owner's
explicit approval before authoring; an edit returns to planning, and a refusal parks the plan.

## Plan artifact

Keep the approved brief, slices table, each `### Slice <slice-id>` section, cross-slice contracts
and `gate-N` rows in the C2 plan path. Gate rows never count toward a spec reviewer-family ceiling.
That slice's section text in C2 and the clean slice brief in C6 come from its `### Slice <slice-id>` section.
Judge wave completion and the C4 pointer from the slices table's `wave` column.

C1 headings in skills/apex-plan/references/sol-plan-check.md: `## Planning gate check` and `## Plan artifact`.

C2 the Critic's optional input block is named **plan-slice inputs** = (a) the plan path `docs/plans/<plan>.md`, (b) that slice's section text, (c) the plan's cross-slice contracts section text, (d) the map sections the slice cites, all pasted into the prompt by the dispatcher. Gate findings, `gate-N` rows, adjudication history and the rest of the plan narrative are never plan-slice inputs. The plan path is a reference only: the Critic never opens the plan file and relies on the pasted section texts.

C3 plan-gate finding transport: codex-review-schema.json unchanged; `severity` carries BLOCK/FLAG/CLEAN; the class is a prefix of `criterion`: `design:` `contract:` `grounding:` `decision:` (wording findings are not requested).

C4 the In-Flight pointer row in docs/status.md: `plan · docs/plans/<plan>.md · next wave <N>`, HOST-maintained, one row per active plan. N = the earliest unfinished wave. The pointer advances only after every slice spec of wave N has archived to docs/changes/done/.
The location is `docs/status.md` in the spec-owning repo.

C5 spec-to-slice association: a slice spec's `## Intent` block carries the line `plan: docs/plans/<plan>.md · slice: <slice-id>`; the plan's slices table maps each slice-id to its spec name.

C6 clean slice brief: for a Big plan slice, the spec-author pack and every Critic pack (spec mode) carry the slice brief (slice intent, cross-slice contracts, cited map sections) in place of the full adjudicated plan brief; gate findings and adjudication are removed.

Every eligible slice gets its own independent post-readiness cold read by that slice spec's tier,
without gate findings or adjudication.
The HOST alone maintains the C4 In-Flight pointer row and close-out records. After the last slice
archives to `docs/changes/done/`, the HOST moves the plan to `docs/plans/done/` and deletes the pointer.
After the plan moves to `docs/plans/done/`, a slice spec's C5 line `plan: docs/plans/<plan>.md` resolves to `docs/plans/done/<plan>.md`.

## Pre-draft architecture pass (ADR-032 §1b)

Runs BEFORE the spec author is dispatched.

**Trigger:** Big changes use § Planning gate check instead of this pass. For non-Big Deep Details
specs, Low and doc-only skip this pass; Medium and High retain it in addition to their independent
post-readiness cold read. An explicit `risk: high` overrides doc-only, and an unresolved High BLOCK
remains blocking. Same wrapper, same read-only Sol; different input, different lens: it judges
the PLAN, and no spec exists yet.

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

- **Disposition:** when no draft exists, advisory for routine specs; **blocking for `risk: high`**.
  The no-draft-yet blocking path is an **approval gate**: on an unresolved arch-pass BLOCK for
  a `risk: high` plan, print the **apex-governance § Approval gate** banner and get the explicit
  `Approve? [y / n / edit]` answer **BEFORE any spec-author dispatch**. Adjudicate findings into
  the PLAN before dispatching the author. Once a draft exists, an arch-pass BLOCK is adjudicated
  and fixed by author revise, then reviewed by Critic (full fresh round 1 without prior non-VOID reviewer-family findings, otherwise a fix check) against the same
  reviewer-family risk-tier ceiling, with OWNER escalation only per apex-plan § Convergence
  control at the ceiling. Sol never writes the plan and never edits the spec.
- **The cold read stays cold.** Never pass this pass's findings, the host's answers to them, or the
  fact that it ran into the post-readiness dispatch above — evaluator independence.
  Big changes use the planning gate instead of the pre-draft pass; non-Big Medium/High Deep Details
  specs retain both reads. Every eligible slice spec gets its own post-readiness cold read by its own
  tier, without gate findings or adjudication. Neither planning read substitutes for the cold read.
- **The cold-read prompt excludes the sidecar — discovery, not just delivery.** The prompt shape in
  § The cold read above now ends with `Do not open docs/drafts/*.review.log, docs/drafts/*.findings.json or docs/plans/.` The sidecar carries
  prior findings, this pass's among them, so a cold reader that opens it is no longer cold. A cold
  reader that opens a plan file would also see gate output.
- **Round record — ALWAYS WHEN DISPATCHED.** Every arch-check dispatch creates (only when absent) or appends to
  `docs/drafts/<short-name>.review.log` (short-name fixed at plan time) with a normal `arch-N` row on
  apex-plan § Convergence control's terms — separate from the reviewer-family risk-tier ceiling (Low 3 / Medium 5 / High 10) and
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
