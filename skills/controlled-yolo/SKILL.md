---
name: controlled-yolo
description: Activated explicitly by the user ("use yolo mode", "yolo mode for this session"). NOT the default. Coding mode behavior contract — implement autonomously, defer internet-exposure questions to end of session.
---

# controlled-yolo

> **Activation:** Only active when the user explicitly says "use yolo mode", "yolo mode for this session", or equivalent. Normal coding sessions are unchanged.

Autonomous coding mode. Make every decision yourself. Never stop to ask unless something opens the project to the internet or an external service — log those to `docs/deferred.md` and ask them all at the end.

---

## The Contract

### What you decide autonomously (never ask)

- Implementation approach for anything specified in the spec
- File organization, naming, folder structure
- Error handling strategy and fallback behavior
- Component breakdown and internal API design
- Test strategy and coverage approach
- Database schema details not explicitly constrained
- Which existing utilities/components to reuse
- Code style and formatting choices
- Order of implementation within a spec

When genuinely ambiguous: pick the simpler option, note your assumption in the handoff doc, and keep moving.

### What gets deferred (never block on these)

Log to `docs/deferred.md` and continue. Ask at the very end.

Defer any decision that involves:

- **New external API integration** — OAuth provider, payment processor, email/SMS service, analytics, error tracking
- **New dependency that phones home** — a package requiring API keys, license checks, or that sends telemetry
- **Exposing an endpoint publicly** — adding a public-facing route, webhook receiver, or file upload endpoint with no auth
- **CORS policy for external origins** — allowing cross-origin requests from specific domains
- **Hardcoded external URLs** — embedding a third-party service URL that production traffic will hit
- **New environment variable for an external service** — anything that doesn't already exist in `.env.example`
- **Sending user data off-machine** — logging to external services, syncing to cloud storage, calling external enrichment APIs

If unsure whether something qualifies: defer it. Better to ask once at the end than to block now.

---

## Session Flow

```
1. Confirm yolo mode is active to the user
2. Read docs/changes/ — pick up all pending specs
3. Read docs/handoff/ — understand current state
4. Create docs/deferred.md (empty list, today's date)
5. Implement all specs autonomously
   └─ When you hit a deferred trigger: log it, keep going
6. When all specs are done:
   └─ Read docs/deferred.md
   └─ If empty: write handoff, done
   └─ If items exist: surface them all in one batch, wait for answers, resolve, write handoff
```

---

## docs/deferred.md Format

Maintain this file throughout the session. Append items as you encounter them. Do not surface them until step 6.

```markdown
# Deferred Questions
_Session: YYYY-MM-DD_

## Internet / External Exposure Decisions

- [ ] **[Feature or file context]** — [The specific question] _(Risk: [one line on why this matters])_
```

Example entries:

```markdown
- [ ] **Email notifications (tasks/notifications.py)** — Which email provider should we use? SendGrid is already in requirements; should I use that or add a new one? _(Risk: new external dependency + API key required)_
- [ ] **Finance webhook endpoint (POST /api/finance/webhook)** — This endpoint has no auth. Should I add HMAC signature verification before exposing it? _(Risk: unauthenticated public endpoint)_
- [ ] **Error tracking (main.py)** — The spec mentions Sentry. Should I add the Sentry SDK and DSN env var? _(Risk: sends stack traces + user context to external service)_
```

---

## Autonomous Decision Log

In the handoff doc, include a section `### Autonomous Decisions` listing non-obvious choices made without asking:

```
- [File/feature]: chose [X] over [Y] because [one-line reason]
```
