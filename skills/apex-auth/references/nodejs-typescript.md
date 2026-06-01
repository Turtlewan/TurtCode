# apex-auth — Node.js + TypeScript worked examples

**Load condition:** read this file only when the bound stack is **Node.js + TypeScript** (Express /
Hono / Fastify / Next.js). On another stack, follow the stack-neutral invariants in `impl.md` and the
library/mechanic swaps in `impl.md` § Stack assumptions (e.g. Python argon2-cffi + FastAPI
dependencies; Swift CryptoKit + server sessions). These are *one stack's illustration* of those
invariants.

## Password hashing (Node.js server)

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

**Edge runtime alternative** (Cloudflare Workers, Vercel Edge — no native argon2 binding):

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

## Session cookie config

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

## Multi-tenant query scoping

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

## Route protection middleware

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

## Library map (Node ecosystem)

- **Hashing:** `@node-rs/argon2` (native argon2id, preferred) · `bcrypt` (cost ≥ 12) · `@noble/hashes` scrypt / WebCrypto PBKDF2-SHA256 600K (edge).
- **Auth frameworks:** Auth.js (authjs.dev) · Better Auth (better-auth.com).
- **WebAuthn / passkeys:** SimpleWebAuthn (simplewebauthn.dev) — server + browser packages.
