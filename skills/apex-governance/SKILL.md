---
skill: apex-governance
backend: claude
version: 1.3.0
last_updated: 2026-06-03
sources:
  - APEX Design Specification 2026-05-24
  - Superpowers (obra) — github.com/obra/superpowers
  - gstack (garrytan) — github.com/garrytan/gstack
  - Claude Code Action — github.com/anthropics/claude-code-action
  - Odysseus analysis (PewDiePie) — docs/research/odysseus-analysis.md
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

### Edit Mode (interactive)
User present in coding mode. Small changes. Can ask questions.
Confirmation gates active for critical files.

## Autonomy levels

L0 — Read Only: no writes, no commands
L1 — Supervised Write: write with per-file confirmation, no commands
L2 — Controlled Auto-Write (default): write non-critical files freely
L3 — Pipeline Auto-Run: full pipeline + test/lint/build, no git commits
L4 — Agentic Loop: includes git commit (message approved first)
L5 — High Autonomy: includes git push to non-main + draft PR creation

See levels/ directory for full definition of each level.

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

## Safety guardrails (scope limiting)

Use these to prevent accidental scope creep during execution:
- **Freeze mode**: restrict writes to one specific directory during a focused debug
- **Careful mode**: warn before any destructive command (rm, DROP, truncate)
- **Guard mode**: combines freeze + careful — use when editing critical files in isolation

Coding mode must honour these signals from the spec's ## Permissions section.
Add `scope: directory/path` to Permissions to activate freeze for that build.

## Cross-model review

For high-stakes builds (security, auth, data migrations):
Request an independent review from a different model before shipping.
Overlapping findings from two models = high confidence.
Divergent findings = flag for human review.

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
