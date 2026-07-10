---
skill: apex-governance
backend: claude
version: 1.15.0
last_updated: 2026-07-10
sources:
  - APEX Design Specification 2026-05-24
  - Superpowers (obra) — github.com/obra/superpowers
  - gstack (garrytan) — github.com/garrytan/gstack
  - Claude Code Action — github.com/anthropics/claude-code-action
  - Odysseus analysis (PewDiePie) — docs/research/odysseus-analysis.md
  - donor-analysis (Superpowers receiving-code-review) — docs/research/donor-analysis/
  - docs/technical/adr/ADR-032-gpt56-role-split.md
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

**Coder model is capability, not authority.** Which model codes (Codex / Opus) is orthogonal to the
autonomy level — "let the stronger coder do more" means raise the L-level, never relax a gate,
critical-file confirmation, or hard block because a particular coder is in use.

## Coding model routing (ADR-027, supersedes ADR-024/026)

APEX coding is **Codex-primary**: `gpt-5.6-terra` (run as a `codex exec -p apex-coder` subprocess from the
build session) is the default coder for every task. The `coder_models` menu is `{codex, opus}`;
per-task routing collapses to **"codex unless its quota is exhausted, then Opus."** Capability-not-
authority applies — the model that codes never widens an autonomy gate, critical-file confirmation, or
hard block.

**Opus is the manual fallback coder** (mechanic A): the build runs in a Claude `APEX_MODE=coding` host
(Sonnet 5 default — below) that dispatches Codex per task; when Codex quota runs out the task is
built by **Opus** — a fresh `model: opus` code-worker dispatch, or the operator switches the session
(`/model opus`) for a fallback-heavy build (no restart, no backend swap). Operator-driven, not auto-escalation. See apex-code § Model
escalation on verify-fail.

**The build host runs Sonnet 5 by default (ADR-032).** The `APEX_MODE=coding` session that
orchestrates dispatch — and **runs the verify loop; never the coder subprocess judging itself**
(evaluator independence at task level) — is Sonnet 5 (`/model sonnet` / `ANTHROPIC_MODEL`),
drawing its own separate weekly bucket. Opus in coding mode is a deliberate choice, not the
default: the per-spec **coder** pin (`coder_model: opus` — selects who codes, a different axis
from who hosts), an Opus **host** as an operator choice for `risk: high` supervision or
GRAY-fork-heavy work, and the Opus fallback coder at Codex quota-out (dispatched as above).
The first real Sonnet-hosted build is the flip's proving run.

**Soft pool guard — RE-INSTATED, scoped to the fallback.** Steady-state coding spends the separate
OpenAI pool; the light Anthropic-pool draw lands mostly on the Sonnet bucket (host orchestration + routine Claude reviews); Opus draws only for high-risk dual-pass reviews and the fallback below.
**But when the build falls back to Opus, Opus builds draw the same scarce Max weekly pool as planning**
→ treat the fallback as a budgeted exception: surface remaining planning headroom at the switch, and
prefer parking or splitting the build over draining the shared pool. Warn, don't block.

DeepSeek (Flash/Pro) is **archived/parked** — recoverable, not in the active menu.

## Capability-routed UI escalation (ADR-020) — RETIRED (ADR-027)

**Retired 2026-06-23.** This carve-out let planning (Claude, multimodal) make a bounded view-layer UI
edit because the coder (DeepSeek) was **image-blind**. Under ADR-027 the coder is **Codex (`gpt-5.6-terra`,
native vision)** or **Opus (multimodal)** on fallback — it **sees the render**, so a visual divergence
is fixed as a **normal coding task**, not a planning-mode escalation. No special exception is needed;
"planning does not write code" stands without it. The live-preview design loop (design lane → build →
visual gate) survives in apex-ui-ux-design — only the image-blindness escalation is gone.

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

A second, **independent review by a different model family than the builder** before shipping a
high-stakes build (auth / security / data migrations). Opt-in, not default. **Invariant: reviewer
family ≠ builder family** (family-aware routing, ADR-027):
- **Codex-built** task (the default coder) → **Claude** reviews (`apex-reviewer`, always a **fresh
  context** — never the orchestrating host reviewing its own build): the host family (Sonnet)
  routinely; **Opus** reviewers for the high-risk dual-pass set (auth / security / data,
  `risk: high`). This is the common path (ADR-032).
- **Opus-built** task (the fallback coder) → **Codex** (`gpt-5.6-terra`) reviews, via headless `codex exec`
  (read-only, schema'd — apex-code § Cross-model review + `references/codex-review.md`). **Advisory** —
  never auto-blocks, never auto-fixes. Note: Opus builds only *because* Codex quota is exhausted, so this
  Codex review usually can't run either → degrade to single-model + human flag (below).

**How it runs (coding-side, wired in apex-code post-build):**
1. The normal single-model review runs first (`apex-reviewer`, same family as the build).
2. If `cross_model_review: true`, run the family-aware independent review above. Give it only the spec
   + changed files, **never the first review's findings** (evaluator independence — judge the code, not
   anchor on the first verdict).
3. Combine the verdicts:
   - **Both flag the same issue** → high-confidence finding; resolve before shipping.
   - **Only one flags it** → divergent; route to the human to adjudicate — do not auto-dismiss.

**Graceful degrade:** if the reviewer family is unavailable (`codex --version` fails **or Codex quota is
exhausted** — the latter is the usual case when Opus is the fallback builder), do **not** silently pass — run the single-model review and emit "cross-model review requested but {family}
unavailable — single-model only; flagged for human." Never a silent skip. Codex runs on **any host**
(its own auth — the old Mac co-location prerequisite is retired).

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
