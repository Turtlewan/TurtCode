---
skill: apex-auth
backend: deepseek
version: 1.1.0
last_updated: 2026-06-01
sources:
  - OWASP Password Storage Cheat Sheet — cheatsheetseries.owasp.org
  - Better Auth Docs — better-auth.com
  - Auth.js Docs — authjs.dev
  - FastAPI Users — fastapi-users.github.io
  - py_webauthn — github.com/duo-labs/py_webauthn
  - SimpleWebAuthn Docs — simplewebauthn.dev
  - SP5 de-coupling + 2026 refresh (stack-neutral core; references/ illustration)
staleness_threshold: 30d
description: >
  Coding-mode rules for authentication — stack-neutral invariants (argon2id hashing,
  httpOnly/secure-storage sessions, server-derived tenant scoping, generic auth errors,
  refresh-token rotation, WebAuthn counter check, rate-limited auth endpoints). Loaded when a
  task implements login/signup/sessions/passkeys/route-protection. Concrete code is
  stack-specific — the Node + TypeScript worked examples live in references/nodejs-typescript.md;
  Python (FastAPI Users / argon2-cffi / py_webauthn) and native (Keychain) swaps in § Stack
  assumptions.
---

# apex-auth — authentication implementation rules

Capability skill — **stack-neutral**. The invariants below are OWASP-grade and apply on any stack;
the concrete hashing lib, session transport, and route-guard mechanism come from the bound stack
(see § Stack assumptions). The bound stack skill's Verification Recipe is the verifier.

## Stack assumptions

Rules below are stack-neutral; the worked examples assume **Node.js + TypeScript**
(`references/nodejs-typescript.md`). On the bound stack, swap:

- **Password hashing:** `@node-rs/argon2` → **Python:** `argon2-cffi` (PyCA) or `passlib[argon2]`; **Apple:** a vetted argon2/bcrypt lib server-side (never roll your own). Use **argon2id**, OWASP params **m=19456 / t=2 / p=1** *or* **m=47104 / t=1 / p=1** (equivalent strength); `bcrypt` cost ≥ 12 as fallback.
- **Auth framework (new projects, 2026):** **Node:** **Better Auth** (lean core + plugins for 2FA / passkeys / orgs) is the current default; Auth.js v5 for OAuth-heavy or migrating apps. **Python/FastAPI:** **FastAPI Users** (sessions + JWT + OAuth, async) + Authlib for social login. **Lucia is deprecated** (maintenance-mode since late 2024 — read it to learn, do not install).
- **Session transport:** httpOnly + secure + SameSite cookie (web, any stack) → same concept. **Native app (Swift/mobile):** store the token in the **OS keychain / secure enclave**, never `UserDefaults` / `localStorage`.
- **Route protection:** Express/Hono middleware → **FastAPI:** `Depends(...)` dependencies; **Starlette/other:** middleware. Same shape: authenticate → 401, authorize role → 403, *before* DB work.
- **WebAuthn / passkeys:** SimpleWebAuthn (JS) → **Python:** `py_webauthn`; **Apple:** `AuthenticationServices`.

## NEVER do

- Hash passwords with MD5, SHA-1, SHA-256, or any reversible/unsalted method.
- Store session tokens in `localStorage` / `sessionStorage` (web) or `UserDefaults` / plaintext (native) — httpOnly cookies on the web, OS keychain/secure storage on native.
- Put auth/role checks *after* DB work has started — authenticate/authorize first, fail fast.
- Derive `tenantId` (or any authorization key) from URL params, query strings, or request body.
- Return different error messages for "user not found" vs "wrong password" (user enumeration).
- Share JWT secrets or signing keys across environments (dev, staging, prod).
- Skip verifying the WebAuthn counter on passkey authentication.
- Log tokens, session IDs, password-reset links, or raw passwords.
- Return a password hash in any API response or error message.

## ALWAYS do

- Hash passwords with **argon2id** (OWASP params above) via the stack's vetted binding; `bcrypt` cost ≥ 12 only as fallback.
- Set web session cookies `httpOnly: true, secure: true (prod), sameSite: 'lax', path: '/'`; on native, persist the token in the OS keychain.
- Scope every tenant-scoped query to a `tenantId` pulled from the server-side session.
- Return one generic message (e.g. `Invalid credentials`) for all login/signup/reset failures.
- Rotate refresh tokens on every use and invalidate the previous one immediately.
- Invalidate all other sessions when the user changes their password.
- Verify the WebAuthn counter is strictly greater than the stored value, then update it, on every authentication.
- Rate-limit auth endpoints per IP and per email.

## Acceptance checks (stack-neutral)

- Signup with a weak password → 400 (not 500/crash).
- Login with wrong password **and** login with a non-existent email → identical generic error.
- Protected route without a session → 401; role-gated route with insufficient role → 403.
- Multi-tenant: a `tenantId` spoofed in the request body is ignored — the session's tenantId is used.
- Session cookie has `httpOnly` + `Secure` (prod) + `SameSite=Lax` (web); native token lives in the keychain, not plaintext.
- Changing the password invalidates other live sessions.
- Passkey auth verifies and advances the WebAuthn counter.

## Worked examples (load on demand)

> The concrete **Node + TypeScript** implementation (argon2 + edge scrypt hashing, cookie set/clear,
> multi-tenant query scoping, route-protection middleware, library map) is in
> **`references/nodejs-typescript.md`** — load it **only when the bound stack is Node + TypeScript**.
> On Python use FastAPI Users + argon2-cffi + py_webauthn; on Apple use AuthenticationServices +
> Keychain — following the swaps in § Stack assumptions.
