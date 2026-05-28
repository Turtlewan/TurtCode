---
skill: apex-auth
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Auth.js Docs — authjs.dev
  - Better Auth Docs — better-auth.com
  - SimpleWebAuthn Docs — simplewebauthn.dev
  - OWASP Auth Cheat Sheet — cheatsheetseries.owasp.org
staleness_threshold: 30d
---

# apex-auth — Implementation patterns

Coding-mode patterns for authentication implementation: password hashing, session cookies, multi-tenant query scoping, route protection middleware, and auth verification.

---

## NEVER do

- Hash passwords with MD5, SHA-1, SHA-256, or any reversible/unsalted method
- Store session tokens in `localStorage` or `sessionStorage` — httpOnly cookies only
- Put auth/role checks inside route handlers after DB work has already started — middleware first, fail fast
- Derive `tenantId` from URL params, query strings, or request body
- Return different error messages for "user not found" vs "wrong password" (user enumeration)
- Share JWT secrets or signing keys across environments (dev, staging, prod)
- Skip verifying the WebAuthn counter on passkey authentication
- Log tokens, session IDs, password reset links, or raw passwords
- Return password hash in any API response or error message

## ALWAYS do

- Hash passwords with `argon2id` via `@node-rs/argon2` (preferred), or `bcrypt` with cost >= 12. On edge: use `@noble/hashes` Scrypt or WebCrypto PBKDF2-SHA256 with 600K iterations.
- Set cookies with `httpOnly: true, secure: true (prod), sameSite: 'lax', path: '/'`
- Scope every tenant-scoped query to `tenantId` pulled from the server-side session
- Return `{ error: 'Invalid credentials' }` (or equivalent) for all auth failures
- Rotate refresh tokens on every use and invalidate the previous one immediately
- Invalidate all sessions (except current) when user changes password
- Verify the WebAuthn counter is strictly greater than the stored value on every authentication
- Use generic error messages on login, signup, and password reset endpoints
- Rate-limit auth endpoints per IP and per email

---

## Code example — password hashing (Node.js server)

```typescript
import { hash, verify } from '@node-rs/argon2'

// On signup / password creation
async function createPasswordHash(password: string): Promise<string> {
  return await hash(password, {
    memoryCost: 19456, // 19 MB
    timeCost: 2,       // 2 iterations
    outputLen: 32,     // 32-byte output
    parallelism: 1,    // single thread
  })
}

// On login / password verification
async function verifyPassword(hash: string, password: string): Promise<boolean> {
  return await verify(hash, password)
}
```

**Edge runtime alternative** (Cloudflare Workers, Vercel Edge):

```typescript
import { scrypt } from '@noble/hashes/scrypt'
import { bytesToHex, hexToBytes } from '@noble/hashes/utils'

// On signup
async function hashPasswordEdge(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const key = await scrypt(password, salt, { N: 2 ** 17, r: 8, p: 1, dkLen: 32 })
  return `${bytesToHex(salt)}:${bytesToHex(key)}` // store salt:hash
}

// On login
async function verifyPasswordEdge(stored: string, password: string): Promise<boolean> {
  const [saltHex, hashHex] = stored.split(':')
  const salt = hexToBytes(saltHex)
  const key = await scrypt(password, salt, { N: 2 ** 17, r: 8, p: 1, dkLen: 32 })
  return bytesToHex(key) === hashHex
}
```

---

## Code example — session cookie config

```typescript
// Set session cookie on login
function setSessionCookie(res: Response, token: string, rememberMe = false): void {
  res.cookie('session', token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
    sameSite: 'lax',
    path: '/',
    maxAge: rememberMe ? 60 * 60 * 24 * 30 : 60 * 60 * 24 * 7, // 30 days / 7 days
  })
}

// Clear session cookie on logout
function clearSessionCookie(res: Response): void {
  res.cookie('session', '', {
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
    sameSite: 'lax',
    path: '/',
    maxAge: 0, // expires immediately
  })
}
```

---

## Code example — multi-tenant query scoping

```typescript
// CORRECT — tenantId from authenticated session, never from request
async function getTenantItems(req: Request, res: Response) {
  const session = await getSession(req)
  if (!session) return res.status(401).json({ error: 'Unauthenticated' })

  const { tenantId } = session // <-- from session, not request params
  const items = await db.item.findMany({
    where: {
      tenantId,
      deletedAt: null,
    },
  })
  return res.json({ items })
}

// WRONG — tenantId from request (attacker can spoof tenant)
async function vulnerableGetItems(req: Request, res: Response) {
  const { tenantId } = req.params // <-- NEVER do this
  const items = await db.item.findMany({ where: { tenantId } })
  return res.json({ items })
}
```

---

## Code example — route protection middleware

```typescript
// Framework-agnostic pattern — adapt to Express, Hono, Fastify, etc.

// Middleware: require authentication (returns 401)
async function requireAuth(req: Request, res: Response, next: NextFunction) {
  const session = await getSession(req)
  if (!session) {
    return res.status(401).json({ error: 'Unauthenticated' })
  }
  req.session = session // attach session to request
  next()
}

// Middleware: require specific role(s) (returns 403)
function requireRole(...roles: string[]) {
  return async (req: Request, res: Response, next: NextFunction) => {
    if (!req.session || !roles.includes(req.session.role)) {
      return res.status(403).json({ error: 'Forbidden' })
    }
    next()
  }
}

// Usage
router.get('/api/admin/users', requireAuth, requireRole('admin', 'owner'), getAdminUsers)
router.get('/api/documents', requireAuth, getDocuments) // any authenticated user
```

---

## Verification checklist

Run through these checks after implementing auth:

- [ ] `npm run build` (or equivalent) — 0 TypeScript/compile errors
- [ ] POST /signup with weak password (e.g., "abc") -> 400 error (not 500 or crash)
- [ ] POST /login with wrong password -> `{ error: 'Invalid credentials' }` (not "Wrong password" or "User not found")
- [ ] POST /login with non-existent email -> `{ error: 'Invalid credentials' }` (same message as wrong password)
- [ ] Accessing protected route without session cookie -> 401
- [ ] Accessing admin route with member role -> 403
- [ ] Multi-tenant: user in tenant A tries `GET /api/tenants/B/items` -> 401 or 403 (not tenant B's data)
- [ ] Multi-tenant: tenantId spoofed in request body is ignored -> session's tenantId used instead
- [ ] Session cookie in DevTools: `httpOnly` checked, `Secure` checked (in prod), `SameSite` = `Lax`
- [ ] Password change invalidates other sessions (log in on two devices, change password on one -> old session on the other no longer works)
- [ ] Passkey counter is verified and updated after each authentication
