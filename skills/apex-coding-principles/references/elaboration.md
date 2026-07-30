# Coding-principles elaboration (load on demand)

Core enforceable rules live in `impl.md` (always loaded by apex-code at pre-flight) and stand on
their own without this file. Load this tail only when reviewing a violation in depth, onboarding a
new domain, or auditing why a rule exists.

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

## Scalability — write code that survives growth (full detail)

- Paginate every endpoint or query that returns a list — never return an unbounded collection.
- Never load a whole table or large dataset into memory — use an explicit `LIMIT`, stream, or process in batches.
- Fetch related records with the ORM's eager-loading in one query — never run a query inside a loop (N+1).
- Hot queries need indexes on the columns they filter/join/sort by — the spec's data tasks name them; if a hot query has no index named, flag to planning.
- Keep no correctness-critical state in process memory (sessions, queues, locks, dedupe sets) — use the external store the spec names; assume more than one instance of the service runs.

## Error handling — always think about these

For every external call (API, database, file, network) handle: missing data · invalid input · network failure · API failure · timeout · permission denied · duplicate record · empty response.

Do not let the application crash unexpectedly when the error can be handled.

## Security — hard rules (consolidated view)

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

## Source-grounding protocol (framework / library code) — full procedure

Training data goes stale. APIs get deprecated. When writing code that calls a specific framework or library API, ALWAYS verify against the installed version before using it.

**ALWAYS:**
1. **Detect the version** — read `package.json` / `package-lock.json` (Node), `pyproject.toml` / `requirements.txt` (Python), `Package.swift` (Swift), `go.mod` (Go), `Cargo.toml` (Rust). State what you found: `"React 19.1.0 from package.json"`.
2. **Consult version-matched official docs** — use the `context7` MCP (resolve-library-id → query-docs) for the specific API you are about to call. Not the homepage — the specific feature page.
3. **Implement from the docs** — use the API signatures shown for that version. If the docs show a new pattern, use the new pattern; if they mark something deprecated, don't use it.
4. **Cite the source** — add a brief inline comment on non-obvious framework-specific choices: `// React 19: useActionState replaces manual isPending — react.dev/reference/react/useActionState`.

**NEVER:**
- Write framework-specific code from memory alone without checking the installed version's docs.
- Cite Stack Overflow, blog posts, or AI summaries as authoritative sources — official docs only.
- Use deprecated APIs because they appeared in training data.
- If context7 is unavailable, flag the pattern as `// UNVERIFIED: based on training data — check official docs before shipping`.

This protocol is canonical here. Do not duplicate it anywhere else — the knowledge layer was removed (ADR-036).
