---
skill: apex-observability
backend: coding
version: 1.1.0
last_updated: 2026-06-01
sources:
  - OpenTelemetry Docs — opentelemetry.io/docs
  - Sentry Docs — docs.sentry.io
staleness_threshold: 14d
description: >
  Coding-mode enforcement for observability — structured JSON logging, no-PII, error
  capture, OTel spans. Examples are TS (pino/Sentry); Python (structlog/sentry-sdk) swaps
  via § Stack assumptions. Loads when adding logging/tracing/error handling.
---

# Observability Implementation Rules

## Stack assumptions

Code below is **TS (pino + `@sentry/node`)**. Swap per stack: **Python** → structlog/stdlib
`logging` (JSON) + `sentry-sdk`; **Swift** → `os.Logger` + sentry-cocoa. The rules
(structured JSON, requestId/userId, no PII, OTel spans, capture+rethrow) are universal.
"No raw stdout logging" means `console.log` (TS) / `print` (Python) / `NSLog` (Swift).

## NEVER do

- Log sensitive data: passwords, tokens, emails, credit card numbers
- Use raw stdout logging in production (`console.log` / `print` / `NSLog`) — use the structured logger
- Swallow errors silently — always log or rethrow
- Log at ERROR level for expected errors (404, validation failures — use WARN or INFO)

## ALWAYS do

- Use structured logging (JSON format, not string concatenation)
- Include requestId and userId in every log entry for traceability
- Capture unexpected errors with the error tracker (`Sentry.captureException` / `sentry_sdk.capture_exception`)
- Log external service calls at INFO level with duration
- Use OpenTelemetry spans for operations > 100ms or with external calls

## Structured log pattern

```typescript
import { logger } from '@/lib/logger'

// INFO — business event
logger.info({ event: 'user.created', userId: user.id, plan: user.plan })

// WARN — expected failure
logger.warn({ event: 'payment.retry', orderId: order.id, attempt: 3 })

// ERROR — unexpected failure
logger.error({ event: 'db.query.failed', error: err.message, query: 'findUser' })
```

## Sentry error capture

```typescript
import * as Sentry from '@sentry/nextjs'

try {
  await riskyOperation()
} catch (error) {
  Sentry.captureException(error, { extra: { context: 'checkout', orderId } })
  throw error // rethrow — don't swallow
}
```

## Verification checklist

- [ ] Check: no console.log or console.error in changed files
- [ ] Check: all catch blocks log the error
- [ ] Check: no PII visible in log statements
