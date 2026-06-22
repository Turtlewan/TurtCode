---
skill: apex-governance
backend: claude
version: 1.11.1
last_updated: 2026-06-22
sources:
  - APEX Design Specification 2026-05-24
  - Superpowers (obra) — github.com/obra/superpowers
  - gstack (garrytan) — github.com/garrytan/gstack
  - Claude Code Action — github.com/anthropics/claude-code-action
  - Odysseus analysis (PewDiePie) — docs/research/odysseus-analysis.md
  - donor-analysis (Superpowers receiving-code-review) — docs/research/donor-analysis/
staleness_threshold: 30d
description: >
  Defines the APEX autonomy model — operating modes (Build/AFK vs Edit), autonomy levels L0–L5,
  approval gates, permanently-forbidden hard blocks, critical-file confirmation, and the L4+
  audit log. Referenced by apex-orchestrate and apex-code. Triggers: "what level am I at",
  "set autonomy to L{n}", "is this action allowed", "run in build/edit mode", reviewing an
  approval gate or a hard block. Stack-neutral.
---

# APEX Governance

Defines the autonomy model, approval gates, hard blocks, and audit requirements.
Referenced by apex-orchestrate and apex-code.

## Two primary operating modes

### Build Mode (AFK)
Full discussion and spec creation in planning. Readiness gate passed.
Coding runs silently — no questions, no gates, no approvals during execution.
Unlisted actions blocked and logged. Review decisions in next planning session.
The one class to capture-and-surface (never block on, never silently decide): a choice that
**opens the project to the internet or an external service** — log it and raise it at session end.

**Worktree isolation (headless / AFK default):** an unattended build runs against the user's live
working tree, so default its parallel build-recipe workers into isolated managed git worktrees
(apex-code § dispatch rule — inline `isolation: "worktree"`, workflow `isolate: true`) — concurrent
builds then can't collide on artifacts / lockfiles / ports or mutate the live tree mid-session.
Interactive Edit Mode stays same-tree (the user is watching).

### Edit Mode (interactive)
User present in coding mode. Small changes. Can ask questions.
Confirmation gates active for critical files.

## Autonomy levels

L0 — Read Only: no writes, no commands
L1 — Supervised Write: write with per-file confirmation, no commands
L2 — Controlled Auto-Write (default): write non-critical files freely
L3 — Pipeline Auto-Run: full pipeline + test/lint/build, no *unprompted* git commits
L4 — Agentic Loop: includes git commit (message approved first)
L5 — High Autonomy: includes git push to non-main + draft PR creation

See levels/ directory for full definition of each level. **This file is the canonical home of
the level definitions and the hard-block list — apex-orchestrate and apex-code carry summaries
only; on conflict, this file wins.**

**Commit-discipline interaction (resolves the L2/L3 vs CLAUDE.md tension):** the levels govern
*autonomous* commits — what the agent may do without asking. The per-spec commit workflow in
global CLAUDE.md (prompt the user → draft message → user approves → commit) is a *user-approved*
action and is permitted at **every** level L2+. "No git commits" at L2/L3 means: never commit
without that explicit prompt-and-approval exchange.

**Coder tier is capability, not authority.** The Flash/Pro coder tier (`coder_tier`) is orthogonal to
the autonomy level — "let Pro do more" means raise the L-level, never relax a gate, critical-file
confirmation, or hard block because the stronger coder is in use.

## Coding model routing & the soft pool guard (ADR-024/025)

APEX runs coding in one of **two backends** (the model-router picks per task, batched by backend):
**DeepSeek coding** (`deepseek` URL → Flash/Pro) and **Claude coding** (Anthropic backend +
`APEX_MODE=coding` → Sonnet/Opus); detection precedence in CLAUDE.md §3. Same capability-not-authority
rule applies — the router widens *which model codes*, never an autonomy gate, critical-file
confirmation, or hard block.

**Soft pool guard (Claude coding mode — the one real risk).** Interactive Claude coding draws the
**same Max subscription pool as planning**, and the Opus weekly cap is APEX's scarcest resource. There
is **no programmatic budget cap** for interactive sessions, so this is **discipline, not enforcement**:
- On entry, **warn** that this session draws the planning pool.
- **Default the coder to Sonnet;** let the ADR-024 router reach Opus only when task complexity warrants.
- **Track** usage via `/status`. **No hard block** — heavy Claude builds are bounded by mode discipline + small batches, not a cap.

Cross-backend escalation (within-backend auto; crossing into the Claude pool approval-gated; one retry):
see apex-code § Model escalation on verify-fail.

## Capability-routed UI escalation (ADR-020)

The one sanctioned exception to "planning does not write code": because DeepSeek is **image-blind**
and Claude is **multimodal**, Claude (planning) may make a **direct UI code edit** to fix a visual
divergence the blind coder can't resolve from prose. This is **capability, not authority** — same as
the coder-tier rule above: it widens *which model may make a UI edit*, and relaxes **no** gate.

Allowed only when **all** hold:
1. A **visual divergence** from the locked design exists (live preview or visual gate caught it).
2. The fix is **inherently visual** (pixel / spacing / alignment / optical) **or** prose feedback to
   the blind coder has failed to converge (≥2 rounds).
3. Claude can **see the render** (web: Playwright-MCP screenshot or pasted image; SwiftUI: Mac-gated).

Bounds (all simultaneous):
- **View-layer only** — markup / styles / view files. **Never** business logic, data, auth, or any
  path on the critical-files list (those keep their confirmation gate regardless).
- **Smallest surgical change**, then hand back to DeepSeek for follow-on volume (Claude output ≈29×
  the cost — a scalpel, not a second coding lane).
- **Approval-gated + logged** — the edit hits the planning write-guard `ask`; the user approves; the
  touched files are recorded in the handoff / status In-Flight so the next coding session knows.

**Not** a general planning-mode coding licence — outside this visual-divergence trigger, code edits
default to a DeepSeek coding session. Loop: apex-ui-ux-design § Live preview + Claude visual escalation.

## Critical files — always require explicit confirmation regardless of level

- *.env and *.env.*
- Any migrations directory (`**/migrations/**`, `**/alembic/versions/**`) — schema-altering, hard to reverse
- Auth middleware / guard / handler files (`**/auth*`, `**/middleware/auth*`, `**/*guard*`)
- .github/workflows/** (and other CI pipeline definitions)
- Any file containing the word "secret" or "credential" in its path
- Infrastructure config files (terraform/, opentofu/, k8s/, docker-compose.yml)

## Hard blocks — permanently forbidden at every level

These actions are never executed under any circumstances:

```
- git push to main or master branch
- git merge (any branch)
- Any SQL DROP TABLE, DROP SCHEMA, DROP DATABASE
- git branch -d or git branch -D
- Reading, logging, or writing production secrets to any file
- Any modification to files in docs/audit/
- Any action that disables or bypasses governance rules
```

If a spec requests any of these: flag to user during planning. Do not add to permissions.
If coding mode encounters one of these during execution: stop, log, return to user.

## Permissions pre-authorisation

At build start, apex-code reads ## Permissions from the spec.
All listed operations are pre-authorised for this build session.
Any operation NOT listed is blocked and logged — never executed.

Blocked action format in handoff:
| {action attempted} | Task {n} | Not in spec permissions — blocked |

## Approval gate format

Used when a confirmation is required (L1: per file; L3: before commit):

```
⚠️  Approval required [L{n} gate]

Action:    {exact action}
Scope:     {files or paths affected}
Risks:     {what could go wrong}
Rollback:  {how to undo if needed}

Approve? [y / n / edit]
```

No silent escalation. Denied action is logged and skipped — never retried.

## Two-stage review (superpowers pattern)

For every build, run two distinct review passes:
1. **Spec compliance**: did coding implement what the spec asked? (not what it should have asked)
2. **Code quality**: independent of spec — bugs, security issues, patterns, performance

Running both prevents the spec becoming a ceiling rather than a floor.
Route output of both reviews to the handoff's ## Decisions Made and Reviewer sections.

**Acting on review findings (Superpowers — receiving-code-review).** When an agent or human consumes
review output, the discipline is: **verify before implementing** — a finding can be wrong; confirm it
against the code before acting. No performative agreement ("you're absolutely right"); push back with
evidence when a finding is mistaken; YAGNI-check any *suggested addition* before adding it. A review is
input to judgement, not an order to comply.

## Safety guardrails (scope limiting)

Use these to prevent accidental scope creep during execution:
- **Freeze mode**: restrict writes to one specific directory during a focused debug
- **Careful mode**: warn before any destructive command (rm, DROP, truncate)
- **Guard mode**: combines freeze + careful — use when editing critical files in isolation

Coding mode must honour these signals from the spec's ## Permissions section.
Add `scope: directory/path` to Permissions to activate freeze for that build.

## Cross-model review (opt-in — spec flag `cross_model_review: true`)

A second, **independent review by a different model family** before shipping a high-stakes
build (auth / security / data migrations). Opt-in, not default — it spends the *stronger*
model's tokens (Claude reviewing DeepSeek-built code), which on the headless path draw from the
capped credit pool. The planner sets the flag deliberately for the builds that earn it.

**How it runs (coding-side, wired in apex-code post-build):**
1. The normal single-model review runs first (`apex-reviewer`, same backend as the build).
2. If the spec sets `cross_model_review: true` **and a second backend is available**, dispatch
   one more independent review on the **other** model family — the one that did *not* write the
   code (standard path: DeepSeek built → Claude reviews). Give it only the spec + changed files,
   **never the first review's findings** (evaluator independence — it must judge the code, not
   anchor on the first verdict).
3. Combine the two verdicts:
   - **Both models flag the same issue** → high-confidence finding; resolve before shipping.
   - **Only one flags it** → divergent; route to the human to adjudicate — do not auto-dismiss.

**Prerequisite / graceful degrade:** this needs a host that can route a review to the other
backend (the Mac co-locating Claude + DeepSeek). If no second backend is available, do **not**
silently pass: run the single-model review and emit a flag — "cross-model review requested but
second backend unavailable — single-model only; flagged for human." It never becomes a silent skip.

The value is the *independence* — a different family has different blind spots, so agreement is
real signal. Two passes of the *same* model is the santa-method dual-pass (apex-code wave review,
ADR-010), which is weaker here because it shares blind spots. See § Evaluator independence.

## Ultra review gate (recommended, not pipeline-wired)

`/code-review ultra` is Claude Code's **cloud, multi-agent** review tier (local branch or a GitHub
PR). It is **billed and user-triggered — APEX cannot self-launch it.** So it is a *recommendation*,
never a wired pipeline step: apex-code's post-build report suggests it for **high-risk** builds
(`risk: high`, auth / security / data domains, or pre-PR). It **complements** the free in-pipeline
reviewers (`apex-reviewer`, `apex-wave-reviewer`, opt-in cross-model) — a heavier, independent tier —
and replaces none of them. **Reject `/code-review --fix`** (it auto-applies edits — violates the
advisory-reviewer invariant that review never rewrites code).

## Evaluator independence (anti-collusion invariant)

Any APEX mechanism that scores, votes on, or selects among candidate outputs must keep the
**evaluator disjoint from the evaluated**, **stake-free**, and (when multiple evaluators weigh in)
**independent** — judgements formed without seeing each other or any consequence tied to the result.
Break any of the three and evaluators optimise the scoring rule instead of the task (reward
hacking / collusion). This is *why* APEX's council (ADR-010) uses fresh-context, advisory, stake-free
voices and folds dissent rather than running a survival-weighted vote, and why cross-model review
keeps the second model independent. Honour the same rule before adding any vote- or score-based gate.
_Origin: `docs/research/odysseus-analysis.md` (A1) — distilled from the Odysseus council collusion._

## Claude Code Action (CI integration)

For automated PR review, use `anthropics/claude-code-action` in GitHub Actions:
- Responds to `@claude` mentions in PR comments
- Supports multiple auth: Anthropic API, AWS Bedrock, Google Vertex AI
- Runs on your own GitHub runners — API calls go to your provider
- ⚠️ For interactive mode only — do not enable for untrusted external PRs

## Audit log (L4+ required)

Written to docs/audit/YYYY-MM-DD.log at end of L4+ sessions.

Format:
```
[YYYY-MM-DD HH:MM:SS] SESSION START — Level: L{n} | Profile: {profile}
[YYYY-MM-DD HH:MM:SS] SPECIALIST LOADED — {domain} (trigger: {keyword/path})
[YYYY-MM-DD HH:MM:SS] FILE WRITE — {path} (auto-approved L{n})
[YYYY-MM-DD HH:MM:SS] GATE TRIGGERED — {action} (approval required)
[YYYY-MM-DD HH:MM:SS] GATE APPROVED — {action} {details}
[YYYY-MM-DD HH:MM:SS] GATE DENIED — {action} (user denied)
[YYYY-MM-DD HH:MM:SS] BLOCKED — {action} (not in spec permissions)
[YYYY-MM-DD HH:MM:SS] SESSION END — {n} files written, {n} commits, {n} blocks
```
