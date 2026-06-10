---
skill: apex-auth
backend: claude
version: 1.2.0
last_updated: 2026-06-10
sources:
  - Auth.js Docs — authjs.dev
  - Better Auth Docs — better-auth.com
  - FastAPI Users — fastapi-users.github.io
  - py_webauthn — github.com/duo-labs/py_webauthn
  - SimpleWebAuthn Docs — simplewebauthn.dev
  - Lucia Docs — lucia-auth.com
  - WebAuthn Spec — w3.org/TR/webauthn-3
  - OWASP Auth Cheat Sheet — cheatsheetseries.owasp.org
staleness_threshold: 30d
description: >
  Use when designing or choosing an authentication system — login/signup, sessions vs JWT, OAuth2 /
  social login, passkeys/WebAuthn, multi-tenant orgs/workspaces, RBAC, invite flows, password
  security. The design invariants are stack-neutral (OWASP hashing, session-derived tenant scoping,
  passkey counter, OAuth state); the concrete library differs by stack — Better Auth (TS) vs FastAPI
  Users (Python) vs AuthenticationServices (Apple), see § Stack assumptions. Not the coding-mode
  enforcement rules (that's impl.md).
---

# apex-auth — Authentication & Authorisation

Planning-mode guidance for choosing and designing authentication systems: session vs JWT, OAuth2 providers, passkeys/WebAuthn, multi-tenant auth (organisations/workspaces), RBAC, invite flows, and password security.

---

## Stack assumptions

The **design invariants** in this skill are stack-neutral and apply on any stack: OWASP argon2id
hashing, session-vs-JWT trade-offs, multi-tenant tenant-from-session scoping, the passkey counter
check, the OAuth `state` parameter, invite-token hashing, RBAC-on-membership. The **library
decision table and code below assume the TypeScript/JS ecosystem** (Better Auth is TS-only). On the
bound stack, swap the concrete auth framework:

| Concept (stack-neutral) | TypeScript/JS (illustrated) | Swap on the bound stack |
|---|---|---|
| Auth framework | **Better Auth** (orgs/passkeys/2FA plugins) | **Python/FastAPI:** FastAPI Users (sessions+JWT+OAuth) + Authlib (social). **Apple:** AuthenticationServices + a server. |
| Password hashing | `@node-rs/argon2` | **Python:** argon2-cffi / passlib[argon2]. argon2id, OWASP params (see impl.md). |
| Passkeys / WebAuthn | `@simplewebauthn/server` | **Python:** py_webauthn. **Apple:** AuthenticationServices / ASAuthorization. |
| Session token storage | httpOnly cookie | Same on web; **native app:** OS keychain / secure enclave, never `UserDefaults`/`localStorage`. |
| Route protection | Express/Hono middleware | **FastAPI:** `Depends(...)`; Starlette: middleware. |

The findings table and library comparison below are accurate for the **JS ecosystem** (re-verified
June 2026). For a Python/native Artemis surface, the *patterns* carry over; the *products* do not —
pick the per-stack framework above.

---

## Research findings (JS ecosystem — re-verified 2026-06-01, still current)

| Topic | Finding | Tag |
|-------|---------|-----|
| **Auth.js v5 status** | Never reached GA/stable. In beta since October 2023. Absorbed into Better Auth in September 2025 after main contributor left. Existing integrations in maintenance mode only. **New projects should use Better Auth.** | [VERIFIED] |
| **Better Auth** | v1.6.11 (May 2026). Framework-agnostic, TypeScript-first. Active development (6,800+ commits). Built-in Organization plugin for multi-tenant. Plugin ecosystem: passkeys, 2FA, magic link, SSO, SCIM, OAuth 2.1 Provider. ORM adapters for Drizzle, Prisma, MongoDB, Kysely. Has absorbed Auth.js. | [VERIFIED] |
| **@simplewebauthn/server** | v13.3.0 (March 2026). Supports Node.js LTS 20+, Cloudflare Workers, Deno, Bun. Also `@simplewebauthn/browser` for the client side. Active development. | [VERIFIED] |
| **Lucia v3** | Officially deprecated as a library (March 2025). Transitioned to learning resource. Oslo (crypto) and Arctic (OAuth) libraries still maintained separately. Recommended replacement: Better Auth or implement sessions from scratch using Lucia guides. | [VERIFIED] |
| **Clerk organisations** | Cloud-only, no self-hosting, no EU data residency. Per-MAU + per-org pricing rots fast — **verify pricing at decision time**. | [VERIFIED] |
| **Supabase Auth** | Bundled with broader Supabase platform (DB, storage, realtime). Open-source, self-hostable. No built-in organisations (roll your own). Per-MAU pricing rots fast — **verify pricing at decision time**. | [VERIFIED] |
| **Argon2 in Node.js — edge compatibility** | `@node-rs/argon2` (Rust via napi-rs): fast, NOT edge-compatible without WASM build step. `argon2` (C++ native): NOT edge-compatible. Edge-safe alternatives: `@noble/hashes` Scrypt (audited, zero-deps, works everywhere); WebCrypto PBKDF2-SHA256 with 600K iterations (OWASP 2024, built-in). `@noble/hashes` Argon2 works in JS but is 5-10x slower than native — Scrypt is preferred on edge runtimes. | [VERIFIED] |

---

## When to activate

Activate `apex-auth` when the conversation involves any of:

- **General**: auth, authentication, login, signup, logout, password, credentials
- **Sessions**: session management, JWT, token, cookie, refresh token
- **OAuth**: OAuth2, OIDC, "Sign in with Google/GitHub/Apple", social login
- **Access control**: RBAC, roles, permissions, authorisation, access control
- **Multi-tenant**: organisations, workspaces, teams, multi-tenant, tenancy, B2B auth
- **Passwordless**: passkeys, WebAuthn, magic link, email OTP, passwordless
- **Security**: MFA, 2FA, TOTP, brute force protection, rate limiting
- **Enterprise**: SSO, SAML, SCIM, directory sync, enterprise auth
- **Invites**: invitation flow, invite member, join organisation
- **Users**: user management, profile, account, user settings

---

## Questions to ask before designing

1. **Single-tenant or multi-tenant?** Will users belong to multiple organisations/workspaces? If multi-tenant, how is the tenant resolved (subdomain, path, custom domain)? This is the single biggest architecture fork.

2. **Which authentication methods are required?** Email+password only? OAuth2 providers? Passkeys/WebAuthn? Magic link? All of the above? Each method adds complexity — start with the minimum viable set.

3. **Which OAuth2 providers are needed?** Google, GitHub, Apple, Microsoft — each has different setup requirements (client ID/secret, redirect URIs, verification process). Plan the provider list before picking a library, as provider breadth varies significantly.

4. **Edge runtime or Node.js server?** If deploying to Cloudflare Workers, Vercel Edge Functions, or Deno, rule out libraries that depend on native Node.js bindings (e.g., `argon2`, `bcrypt`). Use `@noble/hashes` Scrypt or WebCrypto PBKDF2 instead.

5. **How complex is the role/permission system?** Simple admin/member split, or granular resource-level permissions (e.g., "can edit documents in workspace X")? This determines whether you need a full RBAC system or a simple role check on the membership.

6. **Are invite flows needed?** Does the app support inviting users to organisations via email links? Do invitations expire? Is email verification required before accepting? Invite flows add significant complexity to the auth schema.

---

## Library decision table

| Library | Type | Multi-tenant | Self-host | Status | Best for |
|---------|------|-------------|-----------|--------|----------|
| **Better Auth** | Open-source, plugin-based | ✅ Built-in Organization plugin (members, invites, roles, teams) | ✅ Yes | Active (v1.6.11, May 2026) | New TypeScript projects, especially B2B/multi-tenant SaaS needing passkeys, 2FA, RBAC |
| **Auth.js v5** | Open-source, provider-based | ❌ No built-in multi-tenant (must build on callbacks) | ✅ Yes | Absorbed into Better Auth (Sept 2025); maintenance only | Existing NextAuth.js v4/v5 projects already in production |
| **Lucia v3** | Open-source, minimal | ❌ No (roll your own) | ✅ Yes | Deprecated (March 2025); learning resource only | Learning how auth works; implementing from scratch |
| **Clerk** | Managed cloud service | ✅ Via organisations feature (verify pricing at decision time) | ❌ No | Active | Teams wanting fully managed auth with no self-hosting overhead |
| **Supabase Auth** | Managed + self-hostable | ❌ No built-in orgs (roll your own via RLS/invites) | ✅ Yes (self-host) | Active | Projects already using Supabase for DB/storage needing simple auth |

**Recommendation for new TypeScript projects:** Better Auth. It has the most complete feature set (multi-tenant, passkeys, 2FA, RBAC, invite flows), is framework-agnostic (Next.js, Hono, Express, Nuxt, SvelteKit, Remix), actively maintained, and has absorbed Auth.js.

---

## Session vs JWT decision table

| Criterion | DB Sessions | JWT |
|-----------|-------------|-----|
| SSR web app (Next.js, SvelteKit) | ✅ Preferred — server reads session cookie, looks up DB row | ⚠️ Works but harder to revoke individual sessions |
| Stateless API / microservices | ❌ Requires DB lookup per request | ✅ Preferred — no DB call, self-contained token |
| Edge runtime (CF Workers, Vercel Edge) | ❌ Needs edge-compatible DB (e.g., KV, D1) | ✅ Signed cookies / JWTs work natively |
| Session revocation | ✅ Instant — delete session row from DB | ❌ Must wait for expiry or maintain a blocklist |
| Refresh token rotation | ✅ Natural (update session ID, rotate) | ⚠️ Requires separate refresh token flow with rotation |
| Multi-device / concurrent sessions | ✅ Per-device session rows (track device info) | ⚠️ Shared JWT or multiple tokens per device |
| Payload size | ❌ Minimal (just opaque session ID in cookie) | ⚠️ JWT grows with claims; can exceed cookie size limits |

**Rule of thumb:**
- **SSR apps** (Next.js, SvelteKit, Remix) with server-rendered pages -> DB sessions (Better Auth default)
- **Public REST APIs / microservices** -> JWT (short-lived access token + long-lived refresh with rotation)
- **Hybrid** -> DB sessions for the web app, issue short-lived JWTs for API clients and mobile apps

**JWT refresh rotation rule:** Access token: 15 min expiry. Refresh token: 30 day expiry. Rotate refresh token on every use (issue new one, invalidate old). If a refresh token is reused after rotation, invalidate ALL tokens for that user (token theft detected).

---

## Multi-tenant auth

### Tenant resolution strategies

| Strategy | Example | Pros | Cons |
|----------|---------|------|------|
| **Subdomain** | `acme.myapp.com` | Clean, no URL path pollution | DNS + wildcard TLS cert needed; local dev is harder |
| **Path prefix** | `myapp.com/acme/` | Simple to implement; easy local dev | URL pollution; routing complexity per framework |
| **Custom domain** | `app.acme.com` | Most professional for B2B | DNS verification per tenant; cert provisioning |
| **Session-only** | User picks org after login | Simplest — no URL changes needed | Must scope all queries manually; no tenant-specific URLs |

### DB schema (multi-tenant)

```
tenants:         id, slug, name, domain (nullable), logo_url, created_at, updated_at
users:           id, email, name, hashed_password, email_verified, created_at
memberships:     id, user_id, tenant_id, role, joined_at
invitations:     id, tenant_id, email, role, token_hash, expires_at, status (pending|accepted|rejected|cancelled|expired), created_by, created_at
teams (optional): id, tenant_id, name, created_at
team_members:    id, team_id, user_id, role
```

**Key constraints:**
- `memberships.user_id + memberships.tenant_id` is unique
- `invitations.email + invitations.tenant_id` has a unique constraint on pending invites only
- `tenants.slug` is unique (used in URL resolution)

### Invite flow steps

1. **Admin creates invitation** -> Server generates cryptographically random token. Stores `sha256(token)` + role + expiry in `invitations` table. Sends email with link containing raw token and tenant context.
2. **User clicks link** -> Server receives raw token. Looks up `invitations` by `sha256(raw_token)`. Validates: not expired (`expires_at > now()`), status is `pending`, email matches authenticated user's email (if signed in).
3. **If user is authenticated** -> Create membership row with the specified role. Set invitation status to `accepted`. Redirect to tenant workspace.
4. **If user is not authenticated** -> Show signup or login flow. Store invite token in temporary state. After successful auth, create membership and mark invitation `accepted`.
5. **Cleanup** -> All other pending invitations for the same email + tenant combination are cancelled. Redirect user to the tenant workspace.

### Cross-tenant prevention (hard rule)

A user's `tenantId` MUST come from the **session**, never from a request parameter. If a route needs to scope data by tenant, read `session.tenantId` (Better Auth: `session.activeOrganizationId`) — never `req.params.tenantId`, `req.query.tenantId`, or `req.body.tenantId`. An API that accepts `tenantId` from the client is vulnerable to tenant-hopping.

```typescript
// CORRECT — tenantId from authenticated session
const { tenantId } = session
const data = await db.items.findMany({ where: { tenantId } })

// WRONG — tenantId from URL parameter (attacker can spoof)
const { tenantId } = req.params
const data = await db.items.findMany({ where: { tenantId } })
```

---

## Passkeys / WebAuthn

Library: `@simplewebauthn/server` v13.3+ (server) + `@simplewebauthn/browser` (client)

### Credential schema

```
passkey_credentials:
  id:            string (PK — credential ID, base64url encoded)
  user_id:       string (FK to users)
  tenant_id:     string (FK to tenants, nullable for single-tenant apps)
  public_key:    Uint8Array (the stored credential public key in COSE format)
  counter:       number (monotonically increasing — MUST verify on every auth)
  device_type:   string ("singleDevice" | "multiDevice")
  backed_up:     boolean (whether credential is backed up to cloud/secure enclave)
  transports:    string[] (["usb", "nfc", "ble", "internal", "hybrid"])
  device_name:   string (human-readable, e.g. "Chrome on MacBook Pro")
  created_at:    datetime
  last_used_at:  datetime
```

### Registration / authentication flows

Follow the SimpleWebAuthn docs for the step-by-step register/authenticate wiring (generate
options → browser ceremony → verify response). Project-specific invariants on top of the docs:
store the `challenge` server-side per attempt, set `excludeCredentials` on registration to
prevent re-registration, and apply the counter check below on every authentication.

### Counter verification (critical)

The `counter` field MUST be verified on every authentication. Per the WebAuthn spec, the counter is monotonically increasing on the authenticator hardware. If the counter is **not strictly greater** than the stored value, the credential may have been cloned or restored from a backup on a different device. Reject the authentication and flag the user's account for security review.

```typescript
if (verification.authenticationInfo.newCounter <= storedCredential.counter) {
  // Potential credential clone — reject and alert
  await flagAccountForReview(userId)
  throw new Error('Authentication rejected — security check triggered')
}
```

---

## RBAC patterns

### Minimum viable RBAC (3 roles)

| Role | Scope | Permissions |
|------|-------|-------------|
| `owner` | Tenant-wide | Everything including billing, deletion, role assignment, org deletion |
| `admin` | Tenant-wide | All management except billing/org deletion/critical settings |
| `member` | Tenant-wide | Read tenant resources; create own content; no management |

Roles are stored on **memberships**, not on users. A user can be `admin` in tenant A and `member` in tenant B.

### Route protection discipline

Check auth (then role) in middleware, never inside the handler after doing DB work — fail fast
before expensive operations. 401 for unauthenticated, 403 for insufficient role.

### Granular permissions (resource-level)

For resource-level permissions, model as `subject:action` pairs evaluated against a role-permission map:

```typescript
const rolePermissions = {
  owner:  ['document:create', 'document:read:*', 'document:update:*', 'document:delete:*', 'settings:manage', 'billing:manage'],
  admin:  ['document:create', 'document:read:*', 'document:update:*', 'document:delete:*', 'settings:manage'],
  member: ['document:create', 'document:read:*', 'document:update:own'],
}

function can(role: string, permission: string): boolean {
  return rolePermissions[role]?.includes(permission) ?? false
}
```

Better Auth's organization plugin supports this natively via its `ac` (access controller) system with role-based permission statements.

---

## Hard blocks (never override)

1. **Password hashing**: MUST use `argon2id` (preferred, via `@node-rs/argon2`) or `bcrypt` with cost >= 12. Never use plain SHA/MD5, unsalted hashes, or reversible encryption. On edge runtimes: use `@noble/hashes` Scrypt or WebCrypto PBKDF2-SHA256 with 600K iterations.

2. **Token exposure**: NEVER log tokens, session IDs, password reset links, or API keys to console, logs, error reporting services, or analytics.

3. **User enumeration**: Login, signup, and password reset endpoints MUST return the same response whether the user exists or not. A "User not found" vs "Wrong password" distinction leaks valid email addresses.

4. **Tenant ID from session only**: Multi-tenant apps MUST read `tenantId` from the authenticated session, never from request parameters or body. Accepting `tenantId` from the client enables tenant-hopping attacks.

5. **Session cookies**: MUST set `httpOnly: true`, `secure: true` (in production), `sameSite: 'lax'` (or `'strict'`). Never expose session tokens to JavaScript via `document.cookie`.

6. **OAuth2 state parameter**: MUST generate and validate a cryptographically random `state` parameter on every OAuth2 login attempt. Store the expected state in the session before redirecting to the provider. Without this, the OAuth callback is vulnerable to CSRF login attacks.

---

## Review checklist

- [ ] Password hashing uses `argon2id` (or `bcrypt`/`Scrypt`/`PBKDF2` on edge) — never plain hashes
- [ ] Session cookies configured with `httpOnly: true`, `secure: true`, `sameSite: 'lax'`
- [ ] Login/signup endpoints return generic error messages (no user enumeration)
- [ ] OAuth2 flow includes `state` parameter generation and callback validation
- [ ] Multi-tenant: `tenantId` is always read from session, never from request params/body
- [ ] Invite tokens are hashed (`sha256`) before storage; raw token sent only in the email link
- [ ] Passkey counter is verified as strictly increasing on every authentication
- [ ] All sessions except current are invalidated when user changes password
- [ ] JWTs (if used) have short expiry (15 min for access, 7-30 days for refresh with rotation)
- [ ] Rate limiting is applied to login, signup, and password reset endpoints (per IP and per email)
- [ ] CORS is configured to allow only the frontend origin(s) for auth endpoints
- [ ] Refresh token reuse (after rotation) triggers full user session invalidation

---

## Gotchas & edge cases

- **Argon2 at edge**: Neither `@node-rs/argon2` (Rust napi-rs) nor `argon2` (C++ native) work on Cloudflare Workers or Vercel Edge Functions — they depend on native bindings unavailable in edge runtimes. Use `@noble/hashes` Scrypt or WebCrypto PBKDF2-SHA256 (600K iterations, OWASP 2024) instead. `@noble/hashes` argon2 works in pure JS but is 5-10x slower — Scrypt is the pragmatic edge choice.

- **Better Auth vs Auth.js for multi-tenant**: Better Auth has a built-in `organization` plugin with full multi-tenant support (members, invitations, roles, teams, RBAC). Auth.js v5 has **no built-in multi-tenant** support — you must build it yourself on top of callbacks, custom session data, and manual invite flows.

- **Passkey counter verification**: The WebAuthn spec requires servers to verify the `counter` field increases monotonically. A non-increasing counter signals a cloned credential or a backup restored on a different device. **Never skip this check** — many tutorials omit it.

- **Invite token hashing**: Store `sha256(token)` in the database, never the raw token. The email link contains the raw token. This means a DB leak does not expose valid invite links and the raw token is never persisted server-side after creation.

- **Tenant ID in JWT**: If using JWTs with multi-tenant, the tenant claim MUST be embedded at signing time and validated on every request. However, JWT payloads are not invalidated if a user's membership is revoked mid-session — for sensitive operations, always re-verify tenant membership from the DB.

- **OAuth2 state parameter**: The `state` parameter must be a cryptographically random string generated per-attempt. Store it in the session before redirecting to the provider. Validate it strictly on the callback. Without this, your OAuth2 flow is vulnerable to CSRF login attacks where an attacker tricks a user into logging into the attacker's account.

- **Session invalidation on password change**: When a user changes their password, invalidate all existing sessions EXCEPT the current one (if tracking session IDs). Failing to do this means a leaked session token remains valid even after the user regains control of their account.

- **Rate limiting**: Auth endpoints (login, signup, password reset, OTP verification) must be rate-limited per IP AND per email/user. Without per-email rate limiting, an attacker can target a single account with unlimited attempts from many IPs.

- **Email verification gates**: Consider whether to require email verification before allowing: resource creation, accepting invitations, or using OAuth2 providers. Each gate is a potential conversion drop-off point — weigh security vs friction.

- **Refresh token rotation with reuse detection**: When using JWT refresh tokens, rotate on every use (issue new refresh token, invalidate old one). If a refresh token is reused after rotation (indicating theft), invalidate ALL tokens for that user immediately.

- **Better Auth plugin ordering**: If using Better Auth with both `organization` and `customSession` plugins, place `organization` AFTER `customSession` in the plugins array, or `activeOrganizationId` type inference will break.
