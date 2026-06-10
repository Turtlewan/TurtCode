---
skill: apex-coding-principles
backend: deepseek
version: 1.3.0
last_updated: 2026-06-10
sources:
  - User-prescribed coding standards specification (2026-06-01, extended 2026-06-10)
  - Cursor rules best practices 2026
  - APEX rules-distill probe across 37 impl.md cores (2026-06-02)
  - donor-analysis (Aider edit-format reliability, Cline workspace rewind) — docs/research/donor-analysis/
  - 2026-06-10 stocktake rule-promotion pass (cross-read of domain impl.md cores)
staleness_threshold: 365d
description: >
  Universal coding enforcement rules. Loaded by apex-code at pre-flight before any code
  is written. Covers naming, formatting, simplicity, single responsibility, DRY, error
  handling, input validation, security, scalability, surgical scope discipline, Git
  discipline, testing, and maintainability. Applies to all stacks unless the project
  explicitly overrides a rule.
---

## NEVER do

- NEVER use vague names: `data`, `thing`, `stuff`, `temp`, `doIt`, `handleEverything`, `process`, `result`, `x`, `y`
- NEVER write a function that does more than one thing (validate AND save AND send email = three separate functions)
- NEVER copy-paste the same logic in two or more places — extract a reusable function, helper, or service
- NEVER build features or abstractions that were not asked for in the spec (YAGNI — you aren't gonna need it)
- NEVER hardcode secrets, API keys, tokens, passwords, or environment-specific URLs in source files
- NEVER log PII (names, emails, user content, personal identifiers) or secrets/tokens — redact or omit before logging, tracing, or error reporting
- NEVER store passwords in plain text — use bcrypt or equivalent
- NEVER trust frontend validation alone — always validate the same rules on the backend too
- NEVER expose internal error details (stack traces, database errors, internal field names) to end users
- NEVER commit `.env` files, secret files, database dumps, or backups
- NEVER write a comment that explains WHAT the code does — only write comments that explain WHY
- NEVER mix unrelated changes in one task (bug fix + refactor + new feature = three separate tasks)
- NEVER optimise for performance unless there is a confirmed, measured performance problem
- NEVER put business logic inside UI event handlers or components
- NEVER swallow an error silently — an empty `catch`/`except` block, or catching an error and just continuing, is forbidden; log it or rethrow it
- NEVER read identity or tenant keys (`userId`, `orgId`, `tenantId`) from the request body, query params, or client-supplied headers — derive them from the verified session/token only
- NEVER use mutable version references in anything that ships — no `latest` image tags, no `@v4`-style action tags, no unpinned base images; pin exact versions or digests
- NEVER use magic numbers — give the value a named constant (`MAX_RETRY_ATTEMPTS = 3`, not a bare `3` inline)
- NEVER leave commented-out code in the file — delete it (git history keeps it)

## ALWAYS do

- ALWAYS follow the language's syntax rules: correct brackets, commas, colons, semicolons, indentation, imports
- ALWAYS run the project's formatter or linter before finishing a task (`Prettier`, `Black`, `ESLint`, `Ruff`, or whatever is configured)
- ALWAYS use names that explain purpose: `getUserProfile`, `calculateMonthlySpending`, `isPaymentOverdue`, `sendReminderEmail`, `totalPrice`, `recurringPaymentId`
- ALWAYS validate inputs on the backend: required fields, correct types, valid ranges, min/max lengths, allowed values, no negative amounts where disallowed
- ALWAYS handle errors for every external call: missing data, network failure, timeout, permission denied, duplicate record, empty response, API failure
- ALWAYS retry only *transient* external failures (timeout, 429, 503) with bounded exponential backoff + jitter and a capped attempt count — and make any retried operation idempotent (it may run more than once)
- ALWAYS place new files where they belong in the existing project structure — ask "where does this type of code belong?" before creating a file
- ALWAYS write clear error messages for users (`"Payment amount must be greater than zero"`) and developers (`"Recurring payment ID not found"`)
- ALWAYS keep git commits small and focused — one logical change per commit
- ALWAYS write clear commit messages: `"Add validation for recurring payment amount"` not `"fix"` or `"update"`
- ALWAYS use environment variables or config files for secrets, API keys, and environment-specific URLs
- ALWAYS separate business logic from UI — services, backend routes, helpers, and domain modules own the logic; UI only displays and captures input
- ALWAYS understand the data flow before writing code: User action → Frontend → API → Backend logic → Database → Response → UI update
- ALWAYS treat a failed edit-apply (no match, or the file is not what you expected) as a verification failure — STOP, re-read the file, and retry; never continue assuming an edit landed
- ALWAYS checkpoint before a risky change — make sure prior work is committed (or `git stash` the working tree) before a multi-file edit you might need to undo, so the tree can be restored cleanly instead of hand-reverted
- ALWAYS set an explicit timeout on every external call (HTTP, database, queue, third-party API) — default 5000ms unless the spec states another value
- ALWAYS give every async UI surface three states: loading, empty, and error — never only the happy path
- ALWAYS prefer early returns over nested conditionals — when nesting exceeds 3 levels, extract a function
- ALWAYS (TypeScript projects) keep `strict: true` and never use `any` — use `unknown` plus narrowing when a type is genuinely unknown
- ALWAYS debug a failing check with ONE hypothesis at a time: read the exact error → form one hypothesis → make the smallest fix → re-run. After 2 failed fix attempts on the same check, STOP and flag to planning — never shotgun multiple changes at once

## Surgical scope — touch only what the task names

- Change ONLY files listed in the spec's `Files to Change`. Any other file is a blocked action — flag to planning instead of editing it.
- Do not refactor, reformat, or "improve" adjacent code, comments, or imports that your task does not require — even if they look wrong.
- Match the existing file's style, naming, and idiom exactly, even where you would write it differently.
- Remove imports/variables/functions that YOUR change made unused. Do not delete pre-existing dead code — mention it in the task summary instead.
- Final check: every changed line must trace directly to the task. A line you cannot trace → revert it.

## Scalability — write code that survives growth

- Paginate every endpoint or query that returns a list — never return an unbounded collection.
- Never load a whole table or large dataset into memory — use an explicit `LIMIT`, stream, or process in batches.
- Fetch related records with the ORM's eager-loading in one query — never run a query inside a loop (N+1).
- Hot queries need indexes on the columns they filter/join/sort by — the spec's data tasks name them; if a hot query has no index named, flag to planning.
- Keep no correctness-critical state in process memory (sessions, queues, locks, dedupe sets) — use the external store the spec names; assume more than one instance of the service runs.

## Pre-coding checklist

Before writing or changing any code:
- [ ] Do I understand the data flow? Where does data come from, where does it go, what is the source of truth?
- [ ] Do I know which layer owns the business logic for this change?
- [ ] Have I identified the smallest change that achieves the goal?
- [ ] Do I know where any new files belong in the project structure?

## Post-coding checklist

Before marking any task done:
- [ ] Does the code run?
- [ ] Is the syntax correct — brackets, indentation, imports all correct?
- [ ] Did I run the formatter or linter?
- [ ] Are all names clear and descriptive? No vague names?
- [ ] Is the code simple — no cleverness, no unnecessary abstractions?
- [ ] Did I avoid repeating logic — extracted reusable functions where appropriate?
- [ ] Did I handle errors — network failures, missing data, invalid input, timeouts?
- [ ] Did I validate inputs on the backend?
- [ ] Did I test the main case, empty input, invalid input, and at least one error case?
- [ ] Did I avoid committing secrets or `.env` files?
- [ ] Is this change small and focused — one logical change only?
- [ ] Does every changed line trace to the task — no unrelated edits, no drive-by refactors?
- [ ] Async UI: did I implement loading, empty, and error states?
- [ ] Can another developer understand this code without asking me?

## Naming reference

| Type | Good | Avoid |
|------|------|-------|
| Function | `getUserProfile`, `calculateMonthlySpending` | `getData`, `process`, `doStuff` |
| Boolean | `isPaymentOverdue`, `hasPermission`, `isActive` | `flag`, `check`, `ok`, `status` |
| Variable | `totalPrice`, `recurringPaymentId`, `userEmail` | `data`, `temp`, `x`, `val` |
| Handler | `handlePaymentSubmit`, `onUserLogout` | `handleEverything`, `onClick`, `go` |
| File | `userService.ts`, `paymentController.py` | `utils.ts`, `helpers.py`, `stuff.js` |

## Error handling — always think about these

For every external call (API, database, file, network) handle: missing data · invalid input · network failure · API failure · timeout · permission denied · duplicate record · empty response.

Do not let the application crash unexpectedly when the error can be handled.

## Security — hard rules

- Passwords: hash with bcrypt or equivalent. NEVER plain text, NEVER MD5 or SHA1.
- API keys and tokens: environment variables only. NEVER in source code or logs.
- PII in logs: never log personal data (names, emails, user content, identifiers). Redact or omit before logging, tracing, or error reporting.
- Resilience: retry only transient failures (timeout, 429, 503) with bounded exponential backoff + jitter and capped attempts; make retried operations idempotent.
- User input: sanitize before using in queries, templates, or file paths.
- API responses: expose only the fields the caller needs. Strip internal IDs, hashes, and admin fields.
- File uploads: validate type from file bytes (not the client's claimed content-type) and enforce size limits.
- Auth: verify authentication and authorization on every protected route, not just at login.
- Error responses to users: return a safe user-facing message. Log the full error server-side only.

## Comment rule

Write a comment only when the reason is not obvious from the code itself.

Bad: `# Add 1 to count`
Good: `# Retry once — the payment provider returns a temporary timeout on the first attempt`

## Priority order

**Correct → Clear → Tested → Simple → Fast (only when there is a confirmed performance problem)**

Never sacrifice correctness or clarity for performance.
