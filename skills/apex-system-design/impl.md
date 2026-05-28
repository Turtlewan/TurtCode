---
skill: apex-system-design
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Designing Data-Intensive Applications — Kleppmann
staleness_threshold: 60d
---

# System Design Implementation Rules

## NEVER do

- Return a different error for "user not found" vs "wrong password" (user enumeration)
- Use wall-clock time for distributed ordering — use logical clocks or monotonic sequences
- Share a database connection pool across Lambda invocations without RDS Proxy
- Assume a message queue delivers exactly once — always design for at-least-once
- Implement distributed locks without a TTL (dead lock if holder crashes)
- Cache data without a defined invalidation strategy

## ALWAYS do

- Make retryable operations idempotent (payment charges, email sends, state mutations)
- Set a TTL on every distributed lock
- Add a DLQ to every message queue that processes business-critical work
- Alert on DLQ depth > 0
- Use exponential backoff with jitter on all retries

## Idempotency key pattern (PostgreSQL)

```sql
-- Create
CREATE TABLE idempotency_keys (
  key TEXT PRIMARY KEY,
  result JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX ON idempotency_keys (created_at);

-- Use in handler
INSERT INTO idempotency_keys (key, result)
VALUES ($1, $2)
ON CONFLICT (key) DO NOTHING
RETURNING result;
-- If rows returned = 0, key existed → return stored result
-- If rows returned = 1, key is new → proceed
```

## Rate limiting (Redis token bucket)

```typescript
async function checkRateLimit(userId: string, limit: number, windowSecs: number): Promise<boolean> {
  const key = `ratelimit:${userId}:${Math.floor(Date.now() / (windowSecs * 1000))}`;
  const count = await redis.incr(key);
  if (count === 1) await redis.expire(key, windowSecs);
  return count <= limit;
}

// Response headers
res.set({
  'X-RateLimit-Limit': limit,
  'X-RateLimit-Remaining': Math.max(0, limit - count),
  'X-RateLimit-Reset': nextWindowStart,
});
if (count > limit) res.status(429).set('Retry-After', windowSecs);
```

## Circuit breaker (opossum — Node.js)

```typescript
import CircuitBreaker from 'opossum';

const breaker = new CircuitBreaker(callExternalService, {
  timeout: 3000,           // 3s timeout per call
  errorThresholdPercentage: 50,  // open at 50% failure rate
  resetTimeout: 30000,     // try again after 30s
  volumeThreshold: 10,     // minimum calls before opening
});

breaker.on('open', () => logger.warn('Circuit OPEN — blocking calls to external service'));
breaker.on('halfOpen', () => logger.info('Circuit HALF-OPEN — testing recovery'));
breaker.on('close', () => logger.info('Circuit CLOSED — service recovered'));

// Use
const result = await breaker.fire(args);
```

## Distributed lock (Redis)

```typescript
// Acquire with TTL — never without
const token = crypto.randomUUID();
const acquired = await redis.set(
  `lock:${resource}`, token,
  'NX', 'PX', 5000  // 5 second TTL
);
if (!acquired) throw new Error('Could not acquire lock');

try {
  await doWork();
} finally {
  // Release ONLY if we own it (Lua ensures atomicity)
  await redis.eval(`
    if redis.call("GET", KEYS[1]) == ARGV[1] then
      return redis.call("DEL", KEYS[1])
    end
    return 0
  `, 1, `lock:${resource}`, token);
}
```

## Retry with exponential backoff + jitter

```typescript
async function withRetry<T>(fn: () => Promise<T>, maxAttempts = 3): Promise<T> {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (attempt === maxAttempts) throw err;
      const base = Math.min(1000 * 2 ** attempt, 30000);
      const jitter = Math.random() * base * 0.3;
      await new Promise(r => setTimeout(r, base + jitter));
    }
  }
  throw new Error('unreachable');
}
```

## Dead letter queue (SQS pattern)

```typescript
// Worker — always acknowledge, route failures to DLQ
export const handler = async (event: SQSEvent) => {
  const failures: SQSBatchItemFailure[] = [];
  for (const record of event.Records) {
    try {
      await processMessage(JSON.parse(record.body));
    } catch (err) {
      logger.error({ messageId: record.messageId, err }, 'Message processing failed');
      failures.push({ itemIdentifier: record.messageId });
    }
  }
  return { batchItemFailures: failures }; // SQS retries failed items
};
```

## Cache-aside pattern

```typescript
async function getUser(id: string): Promise<User> {
  const cached = await redis.get(`user:${id}`);
  if (cached) return JSON.parse(cached);

  const user = await db.query('SELECT * FROM users WHERE id = $1', [id]);
  await redis.setex(`user:${id}`, 300, JSON.stringify(user)); // 5min TTL
  return user;
}

// On update — invalidate
async function updateUser(id: string, data: Partial<User>) {
  await db.query('UPDATE users SET ...', [id, ...data]);
  await redis.del(`user:${id}`); // invalidate; next read repopulates
}
```

## Verification checklist

- [ ] All POST/PATCH/DELETE handlers that can be retried have idempotency key support
- [ ] Rate limiting applied to all public endpoints (5 req/15min for auth minimum)
- [ ] Circuit breakers wrapping all external synchronous service calls
- [ ] Every SQS/queue consumer returns `batchItemFailures` for partial batch failure
- [ ] DLQ configured on all queues; CloudWatch alarm on DLQ depth > 0
- [ ] Distributed locks have TTL — verified in code
- [ ] Retry logic uses exponential backoff with jitter (no fixed-interval polling)
- [ ] Cache invalidation is explicit on write (not just TTL-based)
