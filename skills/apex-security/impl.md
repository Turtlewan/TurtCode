---
skill: apex-security
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - OWASP Top 10 (2021) — owasp.org/Top10
  - NIST SP 800-63B — pages.nist.gov/800-63-3/sp800-63b
staleness_threshold: 14d
---

# Security Implementation Rules

## NEVER do

- Store passwords without bcrypt or argon2 (minimum cost factor 12)
- Hardcode secrets — always use environment variables
- Trust client-provided IDs for authorisation decisions
- Use Math.random() for security tokens — use crypto.randomBytes()
- Expose stack traces in API error responses
- Skip server-side input validation because "the client validates"
- Use string concatenation to build SQL queries
- Set CORS to wildcard (*) in production
- Store sensitive data in localStorage (sessionStorage only, or httpOnly cookies)
- Log passwords, tokens, or any PII

## ALWAYS do

- Validate and sanitise all input at the system boundary
- Use parameterised queries for all database operations
- Hash passwords before storage — never compare plaintext
- Set token expiry: access tokens ≤15 minutes, refresh tokens ≤7 days
- Return 401 (unauthenticated) vs 403 (unauthorised) correctly
- Rate-limit auth endpoints: maximum 5 attempts per 15-minute window
- Set security headers: X-Content-Type-Options, X-Frame-Options, CSP

## Implementation patterns

Generating a secure token (Node.js):
```typescript
import { randomBytes } from 'crypto'
const token = randomBytes(32).toString('hex')
```

Hashing a password (Node.js):
```typescript
import bcrypt from 'bcrypt'
const hash = await bcrypt.hash(password, 12)
const valid = await bcrypt.compare(password, hash)
```

Input validation with Zod:
```typescript
const schema = z.object({
  email: z.string().email().max(255),
  password: z.string().min(8).max(128)
})
const result = schema.safeParse(input)
if (!result.success) return res.status(400).json({ error: 'Invalid input' })
```

Parameterised query (Prisma):
```typescript
// CORRECT
const user = await prisma.user.findUnique({ where: { email: input.email } })
// NEVER do string interpolation into raw queries
```

## Verification checklist

- [ ] Run: `npm audit` — 0 high or critical vulnerabilities
- [ ] Test: invalid token returns 401, not 500
- [ ] Test: SQL injection string in all user inputs returns 400, not 500
- [ ] Confirm: no secrets appear in `git diff`
- [ ] Confirm: all new routes have auth middleware applied

## Flag for planning-mode review (do not decide yourself)

- Any new authentication flow design
- Any change to the permission model
- Any new third-party auth integration
- Any decision to store data the privacy policy doesn't mention
