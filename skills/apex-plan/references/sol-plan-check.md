# Sol plan-check gate + cross-model deliberation (ADR-032)

Runs after the readiness gate, before a Deep Details spec moves to `docs/changes/`. One
independent cross-family read per spec; skip only trivial single-domain specs (same economy
rule as dispatched domain review). Light / Bug Fix modes skip entirely.

## The cold read (the gate)

```powershell
# Raw `codex exec` is guard-blocked (W2, 2026-07-17) — dispatch through the wrapper:
$prompt = "<prompt below>" + "`n`n---`nSPEC:`n`n" + (Get-Content -Raw <spec-path>)
& "$env:USERPROFILE\.claude\skills\apex-code\scripts\codex-dispatch.ps1" `
  -Spec <spec-name> -Task 'plan-check' -Phase review -Worktree <project-repo> `
  -BaseSha <repo HEAD> -Schema review -Effort max -SkipScopeCheck -Prompt $prompt
# Exit 67 = BLOCK verdict (findings in the printed .final report path); 0 = CLEAN/FLAG-only.
# Concurrent read-only checks into one repo: add -AllowSharedWorktree
#   -AllowSharedWorktreeReason 'concurrent read-only plan-checks; no writes possible'.
```

Prompt shape: *"You are an independent plan reviewer. Review this APEX spec against the repo
for: internal contradictions, acceptance criteria a builder cannot verify as written, missing
producing mechanisms, files/anchors that don't exist, hazards the tasks don't cover, and
simpler structures that meet the same criteria. Findings as BLOCK (spec will fail or build the
wrong thing) / FLAG (planning should decide) / CLEAN, each with file/line + rationale. Judge
the spec, do not rewrite it."*

- **Input = spec + repo evidence only.** Never Opus's self-review notes, reviewer findings, or
  planning-discussion text — the cold first read is sacred (evaluator independence).
- `--sandbox read-only` + no profile: Sol can inspect the repo, writes nothing. **Sol never
  edits the spec** — planning applies accepted amendments itself.
- Effort `max` (plan-check is the highest-leverage read; if gate spend ever crowds Sol build
  quota, drop to `xhigh` before dropping the gate).

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
1. Opus answers each finding into the *same* Sol conversation — **amend** (accept; change the
   spec) or **rebut with evidence** — via `codex exec resume <session-id>` (session id from the
   dispatch's event stream; fallback if resume is unavailable: fresh dispatch carrying the
   prior findings + responses verbatim).
2. **≤2 rounds** (ADR-015 cap). Termination is NOT consensus — each finding ends as exactly one of:
   `accepted` (spec amended) · `withdrawn` (Sol retracts — the resolution table MUST cite the
   specific evidence that moved it; an uncited withdrawal is conversational capitulation, record
   it as DISPUTED instead) · `DISPUTED` (both positions stated → **the user arbitrates**).
3. The resolution table lands in the spec's `## Intent` block as invariants.
4. **Anti-collusion valve:** disputes surface, never negotiate away — "split the difference"
   is forbidden; no movement on evidence → DISPUTED → user (apex-governance § Evaluator independence).

## Tier 2 — blind dual-draft (user-invoked ONLY)

For the rarest, biggest decisions. Both models draft from the same problem brief independently
(neither sees the other's draft) → exchange → ≤2 critique rounds → a **merge doc** of
agreements + disputes for the user's final call. The host never suggests Tier 2 proactively.
