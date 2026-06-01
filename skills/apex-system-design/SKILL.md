---
skill: apex-system-design
backend: claude
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Designing Data-Intensive Applications — Kleppmann
  - System Design Interview — Alex Xu (Vol 1 & 2)
  - AWS Architecture Blog — aws.amazon.com/architecture
  - Martin Fowler — martinfowler.com
staleness_threshold: 60d
description: >
  Use when designing the distributed-systems / operational layer — consistency trade-offs
  (CAP/PACELC), caching, idempotency, message queues + sagas, rate limiting, read replicas,
  circuit breakers, distributed locking. Triggers: "will this scale", "strong vs eventual
  consistency", "add a cache/queue", "idempotency", "rate limit", "this keeps failing under
  load". Patterns are stack-neutral (tool names are illustrative); scale-gate first
  (§ Scale assumptions). Not codebase structure / monolith-vs-microservices (apex-architecture).
---

# System Design Specialist — Planning Mode

## When to activate
Designing distributed systems, planning for scale, handling consistency trade-offs,
designing message queues and async workflows, planning caching strategies,
database sharding/replication, rate limiting, idempotency, or any architecture
decision that affects reliability, latency, or scale across service boundaries.

Distinct from apex-architecture (which covers codebase structure, monolith vs microservices,
DDD, ADRs). This skill covers the **operational and distributed-systems layer**.

## Scale assumptions — gate before applying

These are **stack-neutral** patterns; the named tools (DynamoDB, Kafka, SQS, Redis…) are
*illustrative*, not prescriptions — map each to the bound stack. **Most importantly, gate by
real scale:** a single-user or local-hub system (e.g. an Artemis-style personal assistant)
rarely needs sharding, read replicas, distributed locks, or a saga orchestrator — reach for
them only when measured load demands it. Applying this layer prematurely is the most common
failure here. Start simple (one Postgres/SQLite, in-process work); add distribution on evidence.

## Questions to ask before designing

- What is the current scale? What scale triggers the need for this design?
- What are the consistency requirements? Can reads be stale? For how long?
- What is the acceptable latency? p50? p99?
- What happens when this component fails? What is the blast radius?
- Is idempotency required? Can this operation be safely retried?
- What is the read/write ratio? Where is the hotspot?

## CAP theorem — applied

Every distributed system must choose (under partition):

| Choice | Means | Example databases |
|--------|-------|-------------------|
| CP (Consistent + Partition-tolerant) | Refuse requests rather than return stale data | HBase, Zookeeper, etcd |
| AP (Available + Partition-tolerant) | Return potentially stale data during partition | Cassandra, CouchDB, DynamoDB (default) |

**In practice:** Most systems are not purely one or the other.
- Strong consistency: reads always see latest write. Requires synchronous replication. Higher latency.
- Eventual consistency: reads may see stale data temporarily. Async replication. Lower latency.
- **Default recommendation:** Start with strong consistency (simpler to reason about). Switch to eventual only when performance data demands it and you fully understand the conflict resolution strategy.

## PACELC — the fuller model

Even without partitions, there is a latency/consistency trade-off:
- Lower latency → replicate asynchronously → eventual consistency
- Higher consistency → synchronous replication → higher latency

**Decision:** What is the business impact of a stale read? For financial transactions: never acceptable. For a social media feed: totally fine.

## Consistency patterns

**Strong consistency:** Write completes only after all replicas acknowledge.
- Use for: financial ledgers, inventory counts, auth state
- Tools: Postgres with synchronous_commit, Aurora with read replicas using wait_for_synchronous_commit

**Eventual consistency:** Write completes after primary; replicas catch up asynchronously.
- Use for: social feeds, analytics counters, search indexes
- Tools: DynamoDB, Cassandra, Elasticsearch

**Read-your-writes:** After a write, the same user immediately sees their own write.
- Implementation: route user's reads to the primary for a short window after their write (sticky read)
- Or: use version vectors / fencing tokens to skip stale reads

**Causal consistency:** Causally related operations appear in order.
- Implementation: vector clocks, CRDTs
- Use for: collaborative editing, distributed document stores

## Caching strategies

**Cache-aside (lazy loading):**
```
read → cache miss → read DB → write to cache → return
write → write DB → invalidate cache
```
Good for: read-heavy, tolerable staleness, arbitrary access patterns.

**Write-through:**
```
write → write cache AND DB synchronously → return
read → always hits cache
```
Good for: high read/write ratio, requires cache hit on first read.

**Write-behind (write-back):**
```
write → write cache → return (async flush to DB)
```
Good for: absorbing write bursts. Risk: data loss if cache dies before flush.

**Cache invalidation strategies:**
- TTL (time-to-live): simple, stale by at most N seconds
- Event-driven: publish cache-bust event on write → subscribers invalidate
- Versioned keys: cache key includes version; new writes generate new key (old key expires naturally)

**Thundering herd:** When cache expires and many requests simultaneously try to repopulate it.
- Solution: probabilistic early expiry, locking with a single repopulation, staggered TTLs

## Idempotency

A critical property for any operation that can be retried (payments, message processing, API calls).

**Implementation patterns:**
- **Idempotency keys**: client generates UUID; server stores key + result; duplicate requests return stored result
- **Natural idempotency**: PUT (not POST) with full resource state. Setting a value is idempotent; incrementing a counter is not.
- **At-least-once + deduplication**: message queue delivers at least once; consumer deduplicates by message ID

**Database-level idempotency:**
```sql
INSERT INTO payments (idempotency_key, amount, status)
VALUES ($1, $2, 'pending')
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING *;
```

## Message queues and async patterns

**When to use async:**
- Operation takes > 200ms (background it)
- Operation can fail and retry without user waiting
- Fan-out to multiple consumers
- Decoupling producer availability from consumer availability

**Queue selection:**
| Need | Tool |
|------|------|
| Simple job queue, retries, DLQ | SQS, BullMQ (Redis), PostgreSQL-based queue |
| Ordered events, replay, streaming | Kafka, Kinesis, Redpanda |
| Event-driven microservice integration | EventBridge, SNS |
| Workflow orchestration with state | Step Functions, Temporal |

**Dead letter queues (DLQ):** Every queue that processes business-critical work needs a DLQ.
- Configure max retry count (3–5 for transient failures)
- Alert on DLQ depth > 0
- Reprocess or manually inspect DLQ messages

**Saga pattern (distributed transactions):**
When a transaction spans multiple services and one step fails:
- **Choreography**: each service publishes events and reacts to others. Simple, but hard to trace.
- **Orchestration**: a central coordinator (Step Functions, Temporal) calls each step; handles compensation on failure.

Default recommendation: orchestration for complex multi-step workflows (easier to reason about, centralized error handling).

## Rate limiting

**Algorithms:**
- **Token bucket**: allows burst up to bucket size; refills at fixed rate. Good for: most API rate limiting.
- **Fixed window**: count requests per window (per minute). Simple but allows burst at window boundary.
- **Sliding window**: smoother than fixed window; tracks request timestamps in a sorted set.
- **Leaky bucket**: constant output rate regardless of input. Good for: smoothing bursty traffic.

**Implementation (Redis token bucket):**
```
MULTI
  INCR rate_limit:{user_id}:{window}
  EXPIRE rate_limit:{user_id}:{window} {window_seconds}
EXEC
```

**Response headers (standard):**
```
X-RateLimit-Limit: 1000
X-RateLimit-Remaining: 997
X-RateLimit-Reset: 1716825600
Retry-After: 60  (only when 429 is returned)
```

## Read replicas and read/write splitting

**When to add a read replica:**
- CPU on primary > 50% consistently AND majority is read-query load
- Read latency p99 > SLA AND reads can tolerate slight staleness (typically < 1–2 seconds replication lag)

**Application-level routing:**
- Writes → primary connection string
- Reads → replica connection string (or round-robin pool of replicas)
- After a write, route the same user's reads to primary for 2–5 seconds (read-your-writes)

## Load balancing and service discovery

**Layer 4 (TCP) vs Layer 7 (HTTP):**
- L4: faster, less overhead, no content inspection. Use for: raw TCP, database proxies.
- L7: content-based routing (path, header, cookie), SSL termination, health checks. Use for: most web services.

**Routing algorithms:**
- Round-robin: even distribution, ignores server load
- Least connections: routes to least-loaded server. Better for long-lived requests.
- Consistent hashing: same key always routes to same server. Essential for caching layers.

## Circuit breaker

Prevents cascading failures when a downstream service is degraded.

**States:** Closed (normal) → Open (blocking calls, returning error) → Half-open (testing if service recovered)

**Configuration:**
- Failure threshold: 5 failures in 10 seconds → open
- Recovery timeout: 30 seconds in open → try half-open
- Success threshold: 2 successes in half-open → close

Libraries: Resilience4j (Java), Polly (.NET), opossum (Node.js)

## Distributed locking

When multiple instances must not execute the same operation concurrently.

**Redis-based (Redlock for single-instance):**
```
SET lock:{resource} {unique_token} NX PX 5000
# ... do work ...
DEL lock:{resource}  # only if token matches (use Lua script)
```
**Use for:** distributed cron jobs, inventory decrements, webhook deduplication.

**Caution:** Distributed locks have failure modes (lock holder crashes holding lock). Always set a TTL. Design the protected operation to be idempotent as a fallback.

## Review checklist

- [ ] Consistency requirements explicitly stated (strong vs eventual)
- [ ] Idempotency designed for any retryable operation
- [ ] Failure modes documented — what happens when each dependency is unavailable
- [ ] Rate limiting designed for all externally-facing endpoints
- [ ] Caching invalidation strategy defined (not just "add a cache")
- [ ] Async operations have a DLQ and alerting on DLQ depth
- [ ] Distributed transactions use saga pattern with compensation logic
- [ ] Circuit breakers on all synchronous calls to external services
- [ ] Read replicas only added when primary CPU/latency data justifies it
- [ ] Hotspot analysis done — no single partition key receiving disproportionate traffic

## Standards

Designing Data-Intensive Applications — Kleppmann (primary reference)
Martin Fowler — Patterns of Enterprise Application Architecture
AWS Architecture Blog — aws.amazon.com/architecture/blog
Google SRE Book — sre.google/books
