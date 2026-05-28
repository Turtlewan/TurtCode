---
skill: apex-debug
backend: claude
version: 1.1.0
last_updated: 2026-05-28
sources:
  - APEX Design Specification 2026-05-24
  - Superpowers (obra) — github.com/obra/superpowers
  - Sentry for AI — github.com/getsentry/sentry-for-ai
  - Sentry MCP — github.com/getsentry/sentry-mcp
  - Agent Skills (addyosmani) — github.com/addyosmani/agent-skills
staleness_threshold: 30d
---

# APEX Bug Investigation

One rule above all others: reproduce before fixing.
Assumption-based debugging is forbidden.

## Invocation

/apex-debug "description of the bug"
/apex-debug --forensic "production symptom with no clear reproduction"

## Standard workflow (6 stages)

### Stage 1 — Reproduce

Define exact reproduction steps before touching any code:
1. What is the exact input or action that triggers the bug?
2. What is the expected output?
3. What is the actual output?
4. Is it reproducible 100% of the time? If intermittent — note frequency.

If not reproducible in 3 attempts: stop. Document what was tried. Use --forensic mode.

Do NOT skip to Stage 2 until you have confirmed reproduction steps.

### Stage 2 — Isolate

Narrow the blast radius without fixing anything:
1. Read git log since last known-good state: `git log --oneline --since="7 days ago"`
2. Identify the layer: frontend / backend / database / infrastructure / third-party
3. List 2-3 candidate causes — do not fix any yet
4. Rule out each candidate systematically (logs, debugger, test, diff)

Do NOT write a fix during Stage 2.

### Stage 3 — Root Cause

One hypothesis at a time:
1. State the hypothesis: "I believe the bug is caused by X"
2. Instrument to confirm: add logging, write a targeted test, use debugger
3. Confirm or disprove the hypothesis
4. If disproved: return to Stage 2 with updated candidates
5. Only proceed when root cause is confirmed, not suspected

A root cause statement must be specific:
BAD:  "The auth is broken"
GOOD: "The JWT expiry check uses server time but tokens are issued with client time, causing a 60-second window where expired tokens are accepted"

### Stage 4 — Fix

Surgical fix only:
- Touch the minimum number of files to fix the root cause
- No refactoring adjacent code — not even obviously bad code
- No "while I'm here" improvements
- No cleanup of unrelated issues
- The fix must be directly traceable to the root cause

### Stage 5 — Verify

1. Run the original reproduction steps — bug is gone
2. Run the full test suite — no regressions introduced
3. If any test fails: this fix broke something — return to Stage 3

### Stage 6 — Prevent

1. Write a regression test that would have caught this bug
   - The test must fail before the fix and pass after
   - Name it: "it {describes the bug scenario}"
2. Document in handoff:
   - Root cause (1 sentence)
   - Fix location (file:line)
   - Regression test location
   - Recurrence risk: low / medium / high
   - If high: what to watch for

## Forensic mode (--forensic)

For production incidents where symptoms exist but reproduction is unclear.
Adds Stage 0 before the standard 6 stages.

### Stage 0 — Evidence Gathering

1. Timeline construction:
   - When did symptoms first appear? (check monitoring, logs, user reports)
   - What was deployed in the 24h before symptoms appeared?
   - Run: `git log --oneline --since="48 hours ago"`

2. Evidence collection:
   - Read available error logs, monitoring dashboards, Sentry events
   - Identify: error message, frequency, affected users, affected operations

3. Change correlation:
   - List deployments, config changes, dependency updates in the window
   - Identify most likely culprit based on evidence

4. Form initial hypothesis before attempting Stage 1
   "Based on the evidence, the most likely cause is X, introduced by Y"

Then proceed to Stage 1 with the hypothesis as starting point.

## Handoff mini-postmortem

Every bug investigation writes this to the session handoff:

```markdown
## Bug Investigation: {title}
- Root cause: {1 sentence — specific, not vague}
- Fix: {file}:{approximate line} — {what changed}
- Regression test: {test file path}:{test name}
- Recurrence risk: low | medium | high
- Watch for: {only if high — what would indicate recurrence}
```

## Rules that cannot be broken

- Never write a fix before Stage 3 confirms root cause
- Never modify more than the minimum files needed
- Always write a regression test (Stage 6 is not optional)
- Always document root cause — "fixed" without explanation is incomplete

## Sentry integration (forensic mode)

When Sentry MCP is available, use it in Stage 0 to accelerate evidence gathering:
- `search_issues` — find issues matching the symptom using natural language
- `search_events` — retrieve raw events with full stack traces and breadcrumbs
- Query by: timeframe, user impact, error type, affected operation

Sentry debugging workflow:
1. Query top errors from the relevant timeframe
2. Triage by user impact (most-affected users = highest priority)
3. Access PR context to correlate with recent deploys
4. Use full stack trace + breadcrumbs as Stage 0 evidence before forming hypothesis

## Doubt-driven review (for high-stakes fixes)

Before shipping a fix for critical bugs (security, data loss, auth):
Apply the CLAIM → EXTRACT → DOUBT → RECONCILE pattern:
1. **CLAIM**: state what the fix assumes is true
2. **EXTRACT**: find every place in the codebase that relies on that assumption
3. **DOUBT**: challenge each: "could this assumption be wrong?"
4. **RECONCILE**: resolve doubts before committing
5. **STOP**: if a doubt can't be resolved, escalate to planning — don't guess
