---
skill: apex-governance
backend: claude
version: 2.0.0
last_updated: 2026-07-14
sources:
  - docs/technical/adr/ADR-010-multi-pass-review.md
  - docs/technical/adr/ADR-027-codex-primary-opus-fallback-deepseek-archived.md
  - docs/technical/adr/ADR-032-gpt56-role-split.md
  - docs/technical/adr/ADR-038-single-session.md
staleness_threshold: 30d
description: >
  The APEX autonomy model — levels L0–L5, Build/AFK vs Edit, approval gates, permanently-forbidden
  hard blocks, critical-file confirmation, cross-model review, and evaluator independence. Canonical
  home: apex-orchestrate and apex-code carry summaries; on conflict, this file wins. Triggers: "what
  level am I at", "set autonomy to L{n}", "is this allowed", reviewing a gate or a hard block.
---

# APEX Governance

## What autonomy actually is

**Autonomy is a budget for un-reviewed *distance*, not for *blast radius*.** The levels vary how far
the agent may travel from a pre-approved plan before it must stop. They never vary what is safe.

Two corollaries, both load-bearing:

- **"May do X without asking" ≠ "may do X."** Removing the prompt removes a *check on judgment*, not
  a *grant of authority*. The action still has to be right on its merits. An unattended agent should
  hold itself to a **higher** bar, not a lower one, because nobody will catch the error. "You don't
  have to ask" means "we moved the review downstream — make it survive review."
- **Capability is not authority.** A stronger coder lowers *competence* risk and leaves
  *correctability* risk untouched. A force-push is exactly as unrecoverable when a genius does it. So
  a better model earns **narrower review** — fewer prompts, longer runs, bigger batches — and earns
  **nothing** from the hard blocks or the critical-file list, which are indexed to consequence, not
  skill. (Worse: a stronger model pursues a mis-specified goal *further* before anything breaks, and
  argues for it more persuasively.)

## Modes

**Build / AFK** — "run the list, don't ask." Spec frozen, gate passed. Runs silently; unlisted
actions are blocked and logged. Every AFK run ends with the standing **Opus** adversarial pass
(read-only, advisory) before the handoff. Parallel workers default to **isolated git worktrees** — an
unattended build must not mutate the live tree or collide on lockfiles, ports, and caches.

**Edit** — user present and watching. Small changes, questions allowed, confirmation gates live.

These are **autonomy** modes, not session types. ADR-038 removed session modes: one session plans and
builds.

## Levels

```
L0  Read only          — no writes, no commands
L1  Supervised         — write with per-file confirmation, no commands
L2  Controlled (default) — write non-critical files freely; critical files need confirmation
L3  Pipeline           — full build + the verify recipe; no unprompted git commits
L4  Agentic            — includes git commit (message approved first)
L5  High               — includes push to non-main branches + draft PR
```

No level unlocks the hard blocks. A level that did would just be L4 with the safeties off, which is
the thing we are refusing to build.

**Commit discipline:** the levels govern *autonomous* commits. The per-spec workflow (prompt → draft
message → user approves → commit) is a *user-approved* action, permitted at **every** level L2+. "No
commits" at L2/L3 means: never without that exchange.

## Hard blocks — permanently forbidden, every level, regardless of who asks

```
- git push to main/master; any force-push or history rewrite on a shared branch
- git merge / merging its own PR
- SQL DROP TABLE / DROP SCHEMA / DROP DATABASE; TRUNCATE against a non-local store
- git branch -d / -D
- Reading, logging, or writing production secrets to any file
- Any modification to docs/audit/
- ANY action that disables, bypasses, or widens its own controls
- Deploying to production, or anything with external side effects (payments, email, publish)
- Weakening a security control to satisfy an acceptance criterion
```

Each is either **irreversible by the agent**, or **removes the mechanism by which humans catch its
other mistakes**. The last kind is load-bearing: **an agent that can widen its own permissions has no
permissions.**

**And that block cannot live here.** Every gate in this file is enforced by the same system it
constrains — a motivated agent, or a prompt injection, can reason around an *instruction*. So
self-modification must be blocked in the **harness**: hooks, branch protection, credential scoping,
`permissions.deny`. **When a rule must hold with zero exceptions, it belongs in a hook, not in this
file.**

> **Proven the hard way, 2026-07-14.** Removing the mode split silently disarmed the
> destructive-command guard — it was conditioned on a mode that no longer existed. `rm -rf` was
> unblocked for hours and nothing surfaced it. **Deleting a mode disarms everything conditioned on
> it.** Check that first, every time.

## Critical files — always confirm, regardless of level

`.env` / `*.env.*` · migrations (`**/migrations/**`, `**/alembic/versions/**`) · auth/authz/crypto
source and middleware · `.github/workflows/**` and any CI config · dependency manifests **and
lockfiles** (a one-line change executes arbitrary code) · infra-as-code · anything with `secret` or
`credential` in its path · **the permission settings, the hooks, and the audit log themselves**.

Common property: **a small, plausible-looking diff has effects far outside the diff** — including on
the agent's own leash. These are exactly the files a confused or compromised agent would touch.

**An authorising spec does not settle it.** A spec is a *plan*, written under assumptions the build
has since been testing, and irreversibility is precisely the case where a stale assumption cannot be
walked back. Unattended and irreversible → **park the task and continue the queue.** The right
behaviour at 3am is to lose an hour, not to bet the repo.

A new dependency is a **supply-chain action**: verify the exact name (typosquat) and that it is
maintained. Unattended and uncertain → don't install; block the spec.

## Approval gate

```
⚠️  Approval required [L{n} gate]
Action:    {exact action}
Scope:     {files or paths affected}
Risks:     {what could go wrong}
Rollback:  {how to undo}
Approve? [y / n / edit]
```

No silent escalation. A denied action is logged and skipped — never retried.

**Permissions pre-authorisation:** at build start, `apex-code` reads the spec's `## Permissions`.
Everything listed is pre-authorised for the run; anything not listed is **blocked and logged, never
executed**. Handoff row: `| {action attempted} | Task {n} | Not in spec permissions — blocked |`.

## Evaluator independence — the anti-collusion invariant

Any mechanism that scores, votes on, or selects among outputs must keep the evaluator **disjoint from
the evaluated**, **stake-free**, and (with multiple evaluators) **blind to each other**. Break any of
the three and evaluators optimise the scoring rule instead of the task.

This is why the council's voices are fresh-context and advisory; why the AFK end-gate is **Opus, not
the coder that built the run**; why the host runs the verify loop rather than the Codex subprocess
judging itself; and why a cross-model reviewer never sees the first reviewer's findings.

**Cross-model review** (`cross_model_review: true`; auto for auth / security / data / `risk: high`).
Invariant: **reviewer family ≠ builder family** (ADR-032).
- **Codex built** (the default) → **Claude** reviews, always fresh context; `model: opus` for the
  high-risk set.
- **Opus built** (the fallback) → **Codex** reviews, headless and read-only. Advisory only.

Give the second reviewer the spec + diff, **never the first's findings**. Both flag it →
high-confidence, resolve before shipping. Only one → human adjudication, never auto-dismiss.
Reviewer unavailable — usually Codex quota is out, which is *why* Opus was building — → **say so in
the report**; never a silent skip.

**Acting on findings:** verify before implementing. A finding can be wrong — confirm it against the
code, push back with evidence, YAGNI-check any *suggested addition*. A review is input to judgment,
not an order to comply.

**`/code-review ultra`** — Claude Code's cloud multi-agent tier. **Billed and user-triggered; APEX
cannot self-launch it.** Recommend it for `risk: high` / auth / security / data / pre-PR. It
complements the in-pipeline reviewers and replaces none. **Reject `--fix`** — it auto-applies edits,
violating the advisory-reviewer invariant.

## Logging

- **For the user** (morning review): what ran, what changed (SHAs), verify results, every autonomous
  decision + rationale, and **everything skipped or parked, and why**. The parked list is the most
  valuable artifact of an unattended run.
- **For the next session:** in-flight position, discoveries, blocked actions → the handoff.
- **Audit (L4+, append-only, agent cannot edit):** every side-effecting command, every file touched,
  every gate hit — **approved *or* refused.** Refusals must be logged as loudly as actions: a leash
  that silently declines things is indistinguishable from a broken one, and an agent repeatedly
  probing a gate is exactly the signal a human needs to see.
