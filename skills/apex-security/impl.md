---
skill: apex-security
backend: deepseek
version: 1.1.0
last_updated: 2026-06-01
sources:
  - OWASP Top 10 (2025) — owasp.org/Top10/2025
  - NIST SP 800-63B — pages.nist.gov/800-63-3/sp800-63b
  - SP5 de-coupling + OWASP-2025 refresh (stack-neutral core; Node illustration)
staleness_threshold: 14d
description: >
  Coding-mode security rules — stack-neutral invariants (parameterised queries, hash with
  argon2id/bcrypt, secrets in env, validate at boundary, CSRF, security headers, 401-vs-403,
  rate-limit auth, dependency/supply-chain integrity, safe exception handling). Aligned to OWASP
  Top 10:2025 (incl. A03 Software Supply Chain, A10 Exceptional Conditions). Loaded on any
  security-relevant task. Crypto/validation libs are stack-specific — see § Stack assumptions.
---

# apex-security — security implementation rules

Capability skill — **stack-neutral**, aligned to **OWASP Top 10:2025**. The invariants apply on any
stack; the concrete crypto / validation / audit tooling comes from the bound stack (see § Stack
assumptions). The bound stack skill's Verification Recipe is the verifier.

## Stack assumptions

Rules below are stack-neutral; the code patterns assume **Node.js + TypeScript**. On the bound
stack, swap:

- **Secure random token:** `crypto.randomBytes(32)` → **Python:** `secrets.token_hex(32)`; **Swift:** `SecRandomCopyBytes` / `SystemRandomNumberGenerator`. Never a non-CSPRNG (`Math.random` / `random.random`).
- **Password hash:** `bcrypt` (cost ≥ 12) → **Python:** argon2-cffi / passlib[argon2]; prefer **argon2id** (see apex-auth for OWASP params).
- **Input validation:** Zod → **Python:** pydantic.
- **Parameterised query:** Prisma / parameterised driver → **Python:** SQLAlchemy / DB-API params. Never string-concatenate SQL on any stack.
- **Dependency / supply-chain audit:** `npm audit` → **Python:** `pip-audit` / `uv` audit; verify the lockfile is committed and integrity-pinned.

## NEVER do

- Store passwords without argon2id (preferred) or bcrypt cost ≥ 12.
- Hardcode secrets — environment variables only; never commit secrets.
- Trust client-provided IDs for authorisation decisions (A01:2025 Broken Access Control — still #1).
- Use a non-cryptographic RNG (`Math.random()` / `random`) for security tokens.
- Expose stack traces / internal detail in API error responses (A10:2025 — handle exceptional conditions; never fail *open*).
- Skip server-side input validation because "the client validates".
- Build SQL with string concatenation — parameterise.
- Set CORS to wildcard (`*`) in production.
- Store sensitive data in `localStorage` (web: httpOnly cookies; native: OS keychain).
- Log passwords, tokens, or any PII.
- Add a dependency without pinning + auditing it (A03:2025 Software Supply Chain Failures — pin versions, commit the lockfile, audit).

## ALWAYS do

- Validate and sanitise all input at the system boundary.
- Use parameterised queries for every database operation.
- Hash passwords before storage — never compare plaintext.
- Set token expiry: access ≤ 15 min, refresh ≤ 7 days.
- Return 401 (unauthenticated) vs 403 (unauthorised) correctly.
- Rate-limit auth endpoints (e.g. ≤ 5 attempts per 15-minute window).
- Set security headers: `X-Content-Type-Options`, `X-Frame-Options`, a Content-Security-Policy (A02:2025 Security Misconfiguration — now #2).
- Handle exceptional conditions explicitly — catch, log with context, fail *closed*, return a generic error (A10:2025).
- Pin and audit dependencies; keep the lockfile committed and verify its integrity in CI (A03:2025).

## Implementation patterns (Node.js illustration)

> One stack's form. Python equivalents: `secrets.token_hex`, argon2-cffi, pydantic, SQLAlchemy
> params, `pip-audit` — same rules.

```typescript
import { randomBytes } from 'crypto'
const token = randomBytes(32).toString('hex')         // secure token

import bcrypt from 'bcrypt'
const hash = await bcrypt.hash(password, 12)           // prefer argon2id; bcrypt cost >= 12
const valid = await bcrypt.compare(password, hash)

const schema = z.object({ email: z.string().email().max(255), password: z.string().min(8).max(128) })
const result = schema.safeParse(input)
if (!result.success) return res.status(400).json({ error: 'Invalid input' })

// Parameterised query — never string-interpolate into raw SQL
const user = await prisma.user.findUnique({ where: { email: input.email } })
```

## Acceptance checks (stack-neutral)

- Dependency audit (`npm audit` / `pip-audit`) → 0 high/critical; lockfile committed.
- An invalid token returns 401, not 500.
- A SQL-injection string in any user input returns 400, not 500 (and does not execute).
- No secrets appear in `git diff`.
- All new routes have auth applied.
- An unexpected internal error returns a generic message (no stack trace) and fails closed.

## Flag for planning-mode review (do not decide yourself)

- Any new authentication flow design.
- Any change to the permission model.
- Any new third-party auth / dependency integration (supply-chain risk).
- Any decision to store data the privacy policy doesn't mention.
