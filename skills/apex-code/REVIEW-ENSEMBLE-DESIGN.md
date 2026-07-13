# APEX Review-Ensemble Design — hybrid Codex+Claude multi-lens review (DESIGN BACKLOG)

_Status: DESIGN NOTE for later deep-dive. Not yet built. Authored 2026-06-28 from a live Artemis
review-needs survey. Augments apex-code § Cross-model review + apex-governance § Cross-model review /
Ultra review gate. Relocate into the APEX project's design backlog if there's a better home._

## Why this exists (the problem)

1. **Cloud "ultra" review is Team/Enterprise-only.** On a Max subscription `/code-review ultra` (cloud
   multi-agent) is unavailable (per Claude Code feature-availability docs). So the deepest review tier
   the pipeline assumes (apex-governance § Ultra review gate) can't be reached on this plan.
2. **The Max pool is scarce.** Building + reviewing both draw the same weekly subscription pool. APEX
   already routes *building* to Codex (gpt-5.6-sol) on a separate OpenAI/ChatGPT quota (ADR-027) to spare
   the Max pool — but *review* still leans on Opus (Max pool).
3. **Single-pass review under-covers.** Today's cross-model review is one pass (apex-reviewer ± one
   Codex pass). High-risk surfaces (auth, concurrency, privacy) want multi-lens adversarial depth.

**Goal:** approximate the depth of an "ultra" review WITHOUT the Team plan and WITHOUT draining the Max
pool — by making the review a **multi-lens ensemble that runs mostly on the Codex pool**, with Claude
spent surgically where its judgment pays for itself.

## The enabler (already exists)

`~/.claude/skills/apex-code/references/codex-review.md` + `codex-review-schema.json` already give a
**proven, read-only, schema-enforced Codex reviewer**:
`printf '%s' "<prompt>" | codex exec -c approval_policy=never --sandbox read-only --output-schema <schema> -o <out.json> -m gpt-5.6-sol -C <repo>`
→ returns `{ findings[], verdict }`. Read-only sandbox = zero blast radius; reviewers don't execute
code, so the sandbox limits that blocked Codex from running vitest during builds DON'T apply to review.
Today it's used as a *single advisory pass on Opus-built code only*. The augmentation generalises it.

## Design — tiered hybrid ensemble

**Tier 1 — Breadth sweep (Codex, OFF the Max pool).**
Fan out N parallel `codex exec` read-only reviewers over the same diff, each pinned to ONE LENS:
- `security` (authN/Z, secrets, crypto framing, fail-closed)
- `concurrency` (races, lock-free shared mutable state, idempotency, atomicity)
- `data-integrity` (schema constraints, money/Decimal, bitemporal, migrations)
- `correctness-vs-spec` (acceptance criteria met, edge cases)
- `privacy/injection` (cloud-egress gate, untrusted-content handling, the sensitivity wall)
Each returns the schema'd `{findings[], verdict}`. This is the multi-agent breadth that "ultra" buys —
on Codex quota. Lenses are diff-scoped; pick the subset by changed-file domain (reuse apex-code's
file-path domain match).

**Tier 2 — Claude adjudication (surgical, MINIMAL Max draw).**
One Opus pass that does NOT re-review everything — it only:
(a) reviews the P0/high-stakes lens (e.g. `security`/`concurrency`) directly for the worst surfaces,
(b) adjudicates the **union** of Codex findings — real vs noise vs misread (this session proved the
   need: a Codex-side review FLAG was based on a false premise about `reject_suggestion`; an
   independent adjudicator catches that),
(c) resolves cross-lens duplicates.
Volume stays on Codex; Claude is the judge, not the grunt.

**Tier 3 — Triage (existing rule, ADR-010/026).**
- Finding raised by **both** a Codex lens AND Claude → high-confidence, fix before "complete".
- Raised by **one** → human-adjudicate (decisions table).
- Deterministic merge/dedupe by (file, line-range, rule) — plain orchestrator code, no model.

## Is hybrid Codex+Claude actually better than either alone? (the user's question)

**Yes — with discipline.** Reasoning:
- **Model-family diversity is the real lever.** Different training → different blind spots. The value
  is in *disagreement*: where two families flag the same thing = high signal; where they diverge =
  exactly the spot a human should look. Single-family (Claude-only or Codex-only) loses this.
- **Cost frontier.** Claude-only deep review = full Max draw. Codex-only = off-Max + broad, but single
  family + currently advisory-only. Tiered hybrid = diversity + Codex carries the token volume +
  Claude bounded to adjudication → best cost/quality point.
- **Evidence from this very session.** The single Opus cross-model pass already earned its keep (caught
  a real risk-tag bug) AND produced one false-premise flag that needed a second look. An ensemble with
  an adjudication tier formalises both: more coverage, less acting-on-noise.

**Caveats / failure modes to design against:**
- If Claude's role creeps beyond adjudication, the Max-pool saving evaporates. Keep Tier 2 bounded.
- Codex advisory-only posture (never auto-blocks) must stay — a sandboxed reviewer's BLOCK is a
  recommendation, not a gate.
- Synthesis must be deterministic (dedupe in code), or the ensemble just produces noise.
- Reviewer independence (apex-governance invariant): never feed one reviewer another's findings.

## Artemis deep-review backlog — the motivating evidence + first test-case

Two read-only surveys (2026-06-28) ranked WHERE a deep review pays off most. **Meta-finding: NONE of
the built corpus has had an ultra-grade review** — it was all Codex-built + single-Opus-reviewed. So
"what needs ultra review" ≈ the whole high-risk surface; the survey prioritises where to spend it.
**Dominant theme across both passes: concurrency / race correctness in the always-on background +
auth.** (Calibration: single-owner, loopback, largely single-process hub → some request-level races
are low-real-risk; but the heartbeat + proactive drains DO run concurrently with request handling, so
the proactive/staging/memory races are genuine candidates. Verify, don't assume.)

**Tier 1 (P0) — concurrency + auth:**
- Auth counter-monotonicity race — `identity/app_auth.py` (devices.json, no file lock; per-IP rate
  limit doesn't serialise `bump_counter`). Replay window if two auths run in parallel.
- `proactive/tier1_queue.py` — `_items` mutated outside a lock before atomic persist; enqueue/drain/
  pending() races → lost/duplicate hook entries.
- Memory bitemporal write races — `memory/schema.py` UNIQUE-on-current-row; concurrent writes to a
  `fact_key` → integrity error, no app-level idempotency.
- `staging/service.py` state-machine flip — multi-step prepare→flip→execute→rollback without a
  serializable scope; concurrent approvals could bypass. (Adjacent to the just-shipped agency cap.)

**Tier 2 (P1) — integrity / lifecycle:**
- Nonce lifecycle / replay-after-restart untested (`app_auth.py ChallengeStore`).
- `proactive/ntfy_delivery.py` DedupStore + `tier1_queue.py` HitHandler.deliver mutation — same
  mutate-before-write / unsynchronised-swap pattern.
- SQLCipher per-query connections under contention (`staging/store.py`).
- Tool registry `execute_callable_ref` twin not validated against base tool (`registry/registry.py`).
- Pairing-code not redacted in request logs (`api_app.py`).

**Tier 3 (P2) — design / hardening:**
- Brain reactive dispatch (`brain.py:251–278`) has no read/write enforcement — safe today (only the
  read-only `time` tool is live) but a future mis-tagged WRITE tool would dispatch un-gated. (Directly
  ties to the agency/GATE deferred levers.)
- Reactions dispatcher at-least-once → duplicate effects if ledger write fails post-effect.
- Sensitivity classifier endpoint: no startup validation of the loopback-only rule.

## Suggested next steps (for the deep-dive)
1. Prototype the Tier-1 Codex multi-lens fan-out (security + concurrency lenses) on the agency commit
   `899c4a3` — it's the held "should we ultra-review this?" case. Measure: findings vs the single Opus
   pass already done.
2. If it adds signal, wire it as an opt-in apex-code post-build step (`review_ensemble: true` frontmatter)
   + an apex-governance policy line, gated to `risk: high` / auth / security / data.
3. Run the ensemble against the Tier-1 backlog above (auth counter race + tier1_queue + memory writes)
   as a standalone audit — these predate any review and are the highest-consequence.
4. Decide the Claude-adjudication budget (per-run Max-pool ceiling) so Tier 2 stays bounded.

---

## PROTOTYPE RUN — 2026-06-28 (Tier-1 + Tier-2 on the agency commit 899c4a3)

**What was run.** 3 parallel `codex exec --sandbox read-only --output-schema codex-review-schema.json -m gpt-5.5` reviewers over commit `899c4a3` (agency v0), one per lens (security / concurrency / correctness-vs-spec). Each was told to `git show 899c4a3` itself (read-only sandbox can read git) — no diff embedded in the prompt. Each returned schema'd `{findings[], verdict}`. **All on the Codex pool — zero Max draw for Tier-1.** Tier-2 adjudication = this Opus session (the only Max cost). Prompts: `scratchpad/review-lens-*.txt`; outputs: `scratchpad/review-*.json`.

**Per-lens raw verdicts:**
- **security → CLEAN.** Independently confirmed the invariants: owner-only routes under `require_unlocked` + `rate_limited`, `include_write_surface=False` excludes writes + accept/reject from the reactive registry, no `schedule_fn`/calendar path, `due_at` set / `scheduled_block` null, no leakage. (Agrees with the prior Opus pass.)
- **concurrency → BLOCK.** `accept_suggestion` (`repository.py:461`) reads the suggestion without a status check, creates the task in a *separate* transaction, then unconditionally flips status → **double-accept creates two tasks (not idempotent); accept/reject can race.** No app guard / DB constraint.
- **correctness → BLOCK ×3.** Test-rigor gaps: registry test asserts subset+forbidden-absent but **not exact equality** (an extra unexpected live tool would pass); the `include_write_surface=True` back-compat test checks only a subset (dropped/dup tools could pass); route tests never exercise accept/reject on an **unknown id** (404/idempotency unasserted).

**Tier-2 adjudication (Opus, the judgment tier):**
- concurrency BLOCK → **real, downgrade to MEDIUM/FLAG.** Genuine non-idempotency, but single-owner loopback hub → needs a double-click / two devices. **Pre-existing** in `accept_suggestion` (NOT in the agency commit — confirmed via `git show --stat`); the agency owner-route newly *exposes* it. Fix = conditional-on-`pending` status flip + task-create in one transaction (idempotent accept). Not an agency-commit regression.
- correctness BLOCK×3 → **real but FLAG-grade.** The *code* is correct (security lens + Opus agree); the *tests* under-assert. Cheap hardening: exact tool-set equality, full back-compat set, accept/reject unknown-id 404. Good regression armor.
- Net adjudicated verdict: **PASS-WITH-FLAGS** (no true BLOCK), 4 actionable follow-ups, none blocking the shipped feature.

**THE EXPERIMENT RESULT — does the ensemble add signal over one Opus pass? YES, clearly.**
The prior single Opus pass found: FLAG-2 `suggestion.list` mis-tagged WRITE (real), FLAG-3 dead `complete`/`reschedule` buttons, FLAG-4 spec path, FLAG-1 reject-500 (false premise). The Codex ensemble found **none of those** — but caught **4 things Opus missed** (the `accept_suggestion` idempotency race + 3 test-under-assertion gaps). **Near-disjoint coverage** → empirical proof of the model-family-diversity thesis: the *union* strictly dominates either alone. Also validated the adjudication tier's necessity — raw lens BLOCKs needed context-based downgrade (single-owner), exactly the judgment a bare ensemble lacks.

**Cost shape observed:** Tier-1 = 3 Codex subprocesses (own pool, ~parallel, schema-clean, no Max). Tier-2 = one Opus adjudication (small, bounded). This is the intended frontier — breadth off-Max, judgment surgical.

**Follow-ups this prototype surfaced (for the backlog):**
- (medium) Make `accept_suggestion` idempotent — conditional status flip + task-create in one transaction; pre-existing, newly owner-reachable.
- (low) Harden the 3 agency tests (exact-equality registry assertion, full back-compat set, unknown-id 404 for accept/reject).
- (process) The disjoint-coverage result argues for **keeping BOTH** Opus and Codex in the ensemble, not replacing one — and for running lenses Opus is weak on (concurrency, exhaustive test-rigor) on Codex, while Opus carries semantic/contract lenses (mis-tagging, dead-wiring, spec-divergence) it caught here.
