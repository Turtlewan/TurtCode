---
skill: apex-google
backend: claude
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Google Identity — developers.google.com/identity
  - Google Sign-In for Web (GIS) — developers.google.com/identity/gsi/web
  - Google OAuth2 — developers.google.com/identity/protocols/oauth2
  - Gmail API — developers.google.com/gmail/api
  - Google Calendar API — developers.google.com/calendar/api
  - Google Drive API — developers.google.com/drive/api
  - googleapis npm — github.com/googleapis/google-api-nodejs-client
  - google-api-python-client — github.com/googleapis/google-api-python-client
staleness_threshold: 30d
description: >
  Use when integrating Google identity or Workspace — Sign in with Google, Google OAuth2, Gmail /
  Calendar / Drive access, service accounts, domain-wide delegation, scope selection. The OAuth
  flows, scopes, token-storage rules, and architecture patterns are stack-neutral platform facts;
  only the client library differs by stack — googleapis (Node) / google-api-python-client (Python),
  see § Stack assumptions. Not the coding-mode enforcement rules (that's impl.md).
---

# Google Account & Workspace Specialist — Planning Mode

## Stack assumptions

Almost everything here is **stack-neutral Google-platform knowledge** (OAuth flows, scopes, token
storage, the three credential patterns). Only the **client library** differs by stack: **googleapis +
google-auth-library** (Node) ↔ **google-api-python-client + google-auth + google-auth-oauthlib**
(Python). Where a pattern names the Node library, the Python equivalent is 1:1 (see impl.md § Stack
assumptions).

## When to activate

Any time a project needs to interact with Google identity or Workspace services:
- "Add Sign in with Google" / "Google OAuth login"
- "Read emails from Gmail" / "Send calendar invites" / "Access Drive files"
- "Use a service account to access Google APIs"
- "What scopes do I need for X?"
- Designing a Google Workspace integration architecture

## Core decision: OAuth2 user credentials vs service account

| Credential type | When to use | Acts as |
|----------------|-------------|---------|
| **OAuth2 user flow** | App accesses data on behalf of a specific user | That user |
| **Service account** | App accesses its own data or domain-wide delegation | The service account |
| **Workload Identity** | GCP workload accessing Google APIs without key files | Service account (keyless) |

**Default:** use OAuth2 user flow unless you own the data (e.g. a company calendar).
Service accounts with domain-wide delegation are powerful — treat them like admin credentials.

## OAuth2 flow selection

| Flow | When | Notes |
|------|------|-------|
| **Authorization Code + PKCE** | Web apps, mobile apps | Most secure; use for user-facing apps |
| **Authorization Code (server-side)** | Server rendering with sessions | Store refresh token server-side, never client |
| **Client Credentials** | Service-to-service, no user | Not applicable to Google — use service account instead |

**Never use implicit flow** — deprecated by Google since 2019.

## Questions to ask before designing

- Does the app act on behalf of users or on its own data?
- Which Workspace APIs are needed? (determines scopes)
- Is this a web app, mobile app, or server daemon?
- Will users consent individually, or does an admin grant domain-wide access?
- Does the app need offline access? (requires `access_type=offline` + refresh token)
- Where will tokens be stored? (never in localStorage for sensitive scopes)

## Scope selection — principle of least privilege

Always request the narrowest scope that covers the use case:

| Need | Scope |
|------|-------|
| Read user profile + email | `openid email profile` |
| Read Gmail labels/subjects | `https://www.googleapis.com/auth/gmail.readonly` |
| Send email | `https://www.googleapis.com/auth/gmail.send` |
| Full Gmail access | `https://mail.google.com/` (requires verification for production) |
| Read calendar events | `https://www.googleapis.com/auth/calendar.readonly` |
| Create/edit calendar events | `https://www.googleapis.com/auth/calendar.events` |
| Read Drive files the user opens | `https://www.googleapis.com/auth/drive.file` |
| Read all Drive files | `https://www.googleapis.com/auth/drive.readonly` |

**Sensitive and restricted scopes** require Google's OAuth verification process before going to production (more than 100 users). Plan for 4–8 weeks verification time.

## Sign in with Google — web implementation checklist

Using the GIS (Google Identity Services) library:
- [ ] Load GIS from `https://accounts.google.com/gsi/client` (not the old `platform.js`)
- [ ] Use One Tap or the Sign In With Google button component
- [ ] Verify the `credential` JWT on the server — do not trust client-side
- [ ] Use Google's token info endpoint or a JWT library with Google's JWKS
- [ ] Extract user identity from verified JWT: `sub` (stable user ID), `email`, `name`, `picture`
- [ ] Never use `email` as the primary key — use `sub` (email can change)

## Token storage — security rules

| Token | Where to store |
|-------|---------------|
| Access token (short-lived, ~1h) | Memory (in-memory variable) |
| Refresh token (long-lived) | Server-side DB (encrypted), HttpOnly cookie |
| ID token | Verify server-side; discard after extracting claims |

**Never** store refresh tokens in localStorage, sessionStorage, or cookies without HttpOnly.

## Architecture patterns

### Pattern 1: User-delegated access (most common)
```
User → OAuth consent → Google → auth code → your server
Your server → exchanges code → access token + refresh token
Your server → stores refresh token encrypted in DB
Your server → uses access token to call Google APIs on user's behalf
```

### Pattern 2: Service account (backend daemon)
```
Service account JSON key (or Workload Identity on GCP)
→ the Google auth library (google-auth-library / google-auth) creates a JWT
→ Google token endpoint → short-lived access token
→ Call API directly
```

### Pattern 3: Domain-wide delegation (Google Workspace admin)
```
Admin grants service account permission to impersonate any user in the domain
→ Service account JWT with `sub` claim set to target user email
→ Access token impersonating that user
→ Call API as that user
```

## Review checklist

- [ ] Narrowest possible scopes requested — no over-permissioning
- [ ] Refresh tokens stored encrypted, server-side only
- [ ] Access tokens never in localStorage
- [ ] ID tokens verified server-side before trusting
- [ ] `sub` used as user identity (not `email`)
- [ ] Sensitive/restricted scopes identified — Google verification timeline planned
- [ ] Token refresh logic handles `invalid_grant` (revoked token) gracefully
- [ ] Service account keys (if used) stored in secrets manager, not in code or env files

## Hard blocks

- Do not store refresh tokens client-side under any circumstances
- Do not use `email` as the primary user identifier — it can change
- Do not request broad scopes (`drive`, `mail.google.com`) unless genuinely needed
- Do not skip server-side JWT verification for Sign in with Google
