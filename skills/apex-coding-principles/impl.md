---
skill: apex-coding-principles
backend: coding
version: 1.5.0
last_updated: 2026-07-29
sources: [User-prescribed coding standards spec (2026-06-01, ext. 2026-06-10), Cursor rules best practices 2026, APEX rules-distill probe (2026-06-02), donor-analysis (Aider/Cline), 2026-06-10 rule-promotion pass, core/tail split (2026-07-29)]
staleness_threshold: 365d
description: >
  Universal coding standards (naming, formatting, error handling, input validation,
  security, scalability, scope discipline, Git discipline, testing, maintainability)
  apex-code auto-loads via impl.md before writing code; also used to review code quality.
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
- ALWAYS expose only the fields a caller needs in API responses — strip internal IDs, hashes, and admin fields
- ALWAYS validate file uploads by type from the file's bytes (not the client's claimed content-type) and enforce size limits
- ALWAYS verify authentication and authorization on every protected route, not just at login
- ALWAYS paginate/limit any list-returning query, avoid N+1 (use eager-loading), index hot query columns, and keep no correctness-critical state in process memory — assume more than one instance runs (detail → `references/elaboration.md`)
- ALWAYS verify framework/library API usage against the installed version's docs (context7) before writing framework-specific code — never from training-data memory alone (full protocol → `references/elaboration.md`)

## Surgical scope — touch only what the task names

- Change ONLY files listed in the spec's `Files to Change`. Any other file is a blocked action — flag to planning instead of editing it.
- Do not refactor, reformat, or "improve" adjacent code, comments, or imports that your task does not require — even if they look wrong.
- Match the existing file's style, naming, and idiom exactly, even where you would write it differently.
- Remove imports/variables/functions that YOUR change made unused. Do not delete pre-existing dead code — mention it in the task summary instead.
- Final check: every changed line must trace directly to the task. A line you cannot trace → revert it.

## Priority order

**Correct → Clear → Tested → Simple → Fast (only when there is a confirmed performance problem)**

Never sacrifice correctness or clarity for performance.

## Load more — `references/elaboration.md`

Naming-reference examples, the pre/post-coding checklists, the full scalability writeup, the
error-handling case list, the consolidated security section, comment-rule good/bad examples, and the
full source-grounding protocol (context7 verification steps) live in `references/elaboration.md`.
Load it when reviewing a violation in depth, onboarding a new domain, or auditing why a rule exists —
not on every build; every enforceable rule above already stands on its own without it.
