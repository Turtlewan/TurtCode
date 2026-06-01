---
skill: apex-google
backend: deepseek
version: 1.1.0
last_updated: 2026-06-01
sources:
  - googleapis npm — github.com/googleapis/google-api-nodejs-client
  - google-api-python-client — github.com/googleapis/google-api-python-client
  - google-auth (Python) — github.com/googleapis/google-auth-library-python
  - Google Identity GIS — developers.google.com/identity/gsi/web
  - SP5 de-coupling (stack-neutral core; googleapis/TS illustration)
staleness_threshold: 30d
description: >
  Coding-mode rules for Google Account / Workspace integration — stack-neutral invariants (use `sub`
  not email as the user key, verify ID tokens server-side, encrypt refresh tokens, handle
  invalid_grant, request minimal scopes, never commit service-account keys, use the official client
  not hand-rolled calls). Loaded on Google OAuth / Gmail / Calendar / Drive work. Client is
  stack-specific — googleapis (Node) / google-api-python-client (Python); see § Stack assumptions.
---

# apex-google — Google Account & Workspace implementation rules

Capability skill — **stack-neutral**. The OAuth/Workspace invariants apply on any stack; the concrete
Google client library comes from the bound stack (see § Stack assumptions). The bound stack skill's
Verification Recipe is the verifier.

## Stack assumptions

Rules below are stack-neutral; the worked examples assume **Node + TypeScript** (`googleapis` +
`google-auth-library`, `references/nodejs-typescript.md`). On the bound stack, swap:

- **Google client library:** `googleapis` / `google-auth-library` (Node) → **Python:** `google-api-python-client` + `google-auth` + `google-auth-oauthlib`. Same resources: `gmail`/`calendar`/`drive` services, `Credentials`, the OAuth flow.
- **ID-token verification:** `OAuth2Client.verifyIdToken` → **Python:** `google.oauth2.id_token.verify_oauth2_token(...)` — both return `sub`/`email`/`email_verified`.
- **Service account:** `google.auth.GoogleAuth({ keyFile })` + `subject` for domain-wide delegation → **Python:** `google.oauth2.service_account.Credentials.from_service_account_file(...).with_subject(...)`.
- **Sign-in widget:** the **GIS** library (`developers.google.com/identity/gsi/web`) — never the deprecated `platform.js` — on any web frontend.

## NEVER do

- Store refresh tokens in `localStorage`, `sessionStorage`, or non-HttpOnly cookies (web); on native, use the OS keychain.
- Use `email` as the primary user key — always use the stable `sub` claim.
- Skip server-side ID-token verification for Sign in with Google credentials.
- Commit service-account JSON key files to source control.
- Request broad scopes (`drive`, `mail.google.com`, …) without explicit need — minimise scopes.
- Use the deprecated `platform.js` GSI library — use the current GIS library.

## ALWAYS do

- Use the official Google client library for token exchange/refresh — never hand-roll the API calls.
- Encrypt refresh tokens before storing them in the database.
- Handle `invalid_grant` by clearing the stored token and re-initiating the OAuth flow (the token was revoked/expired).
- Verify returned tokens include the expected scopes before storing.
- Request `access_type=offline` + `prompt=consent` when a refresh token is needed.

## Acceptance checks (stack-neutral)

- OAuth2 client ID/secret come from env vars — not hardcoded.
- The refresh token is encrypted before DB insert.
- An `invalid_grant` clears the stored token and routes the user to re-auth.
- Sign in with Google verifies the ID token server-side before any user creation.
- `sub` (not `email`) is stored as the Google foreign key.
- The service-account key file is git-ignored and stored in a secrets manager.
- Granted scopes are minimal — confirmed against actual API usage.

## Worked examples (load on demand)

> The concrete **googleapis + TypeScript** implementation (OAuth2 setup, token refresh + revocation,
> Gmail/Calendar/Drive operations, service account + domain-wide delegation, server-side ID-token
> verification, env vars) is in **`references/nodejs-typescript.md`** — load it **only when the bound
> stack is Node + TypeScript**. On Python use `google-api-python-client` + `google-auth` per the
> swaps in § Stack assumptions.
