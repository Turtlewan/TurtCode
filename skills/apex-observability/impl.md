---
skill: apex-observability
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - OpenTelemetry Docs — opentelemetry.io/docs
  - Sentry Docs — docs.sentry.io
staleness_threshold: 14d
---

# Observability Implementation Rules

## NEVER do

- Log sensitive data: passwords, tokens, emails, credit card numbers
- Use console.log in production code — use structured logger
- Swallow errors silently — always log or rethrow
- Log at ERROR level for expected errors (404, validation failures — use WARN or INFO)

## ALWAYS do

- Use structured logging (JSON format, not string concatenation)
- Include requestId and userId in every log entry for traceability
- Capture unexpected errors with Sentry.captureException
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
