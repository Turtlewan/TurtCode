---
skill: apex-jobs
backend: claude
version: 1.1.0
last_updated: 2026-05-31
sources:
  - BullMQ Docs — docs.bullmq.io
  - Bull Board — github.com/felixmosh/bull-board
  - pg-boss — github.com/timgit/pg-boss
  - AWS ElastiCache Redis — docs.aws.amazon.com
  - SP5 de-coupling (stack-agnostic; § Stack assumptions)
staleness_threshold: 30d
description: >
  Use when designing background jobs / async task processing — job queues, workers, retries +
  backoff, cron/scheduled tasks, dead-letter queues, graceful shutdown. Triggers: "background job",
  "job queue", "worker", "cron job", "scheduled task", "retry failed tasks", "process X async".
  Concepts are stack-neutral (queue/worker separation, retry+backoff, DLQ, idempotent handlers);
  concrete examples illustrate BullMQ + Redis + Node and adapt to the bound stack (e.g. Python arq /
  APScheduler / SQLite-backed) via § Stack assumptions. Not real-time push (apex-realtime).
---

# apex-jobs — Background Jobs

## Stack assumptions

Concepts below are **stack-neutral**; concrete examples assume **BullMQ + Redis + Node** (the
default illustration). Planning checks this against the bound `stack_skills` and adapts on mismatch;
the **stack skill's Verification Recipe is the verifier**.

| Concept (keep) | BullMQ + Redis + Node (illustrated) | Swap point on the bound stack |
|---|---|---|
| Queue + separate worker process | `Queue`/`Worker` + ioredis | **Python:** arq (Redis, async), Celery, or RQ. **Local single-user (no broker):** APScheduler (in-process cron) or a SQLite-backed durable queue. |
| Retry + backoff | `attempts` + `backoff: exponential` | arq `max_tries`; Celery `retry_backoff` — same concept. |
| Durable backing | Redis (`maxRetriesPerRequest: null`) | Redis / Postgres (pg-boss) / **SQLite** for a local app — never purely in-memory. |
| Cron / repeatable | `repeat: { pattern }` + stable `jobId` | arq cron; APScheduler `CronTrigger`; Celery beat — always a stable id to avoid duplicate registration. |
| Dashboard | Bull Board (auth-gated) | Celery → Flower; arq has no built-in UI — gate any dashboard behind auth. |
| Graceful shutdown | `worker.close()` on SIGTERM | arq handles SIGTERM; APScheduler `scheduler.shutdown(wait=True)`. |

Stack-neutral — never swap out: worker-separate-from-web-process, retry + exponential backoff,
never-silently-swallow-job-errors, idempotent handlers, durable backing, graceful shutdown.

## Research findings (BullMQ / Redis-specific reference)

| Technology | Finding | Tag |
|------------|---------|-----|
| BullMQ v5 | Current stable v5.76.x. QueueScheduler removed (functionality merged into Queue). Worker/Queue constructor takes ioredis instance. Default prefix changed from `bull` to `bullmq`. | [VERIFIED] |
| Bull Board | Current stable v6.16.x. Package: @bull-board/api + @bull-board/express (or /fastify). Setup: createBullBoard({ queues: [new BullMQAdapter(queue)], serverAdapter }). | [VERIFIED] |
| ioredis + BullMQ | `maxRetriesPerRequest: null` is mandatory for Worker connections. Queue producers from HTTP can default to 20 retries for fail-fast. QueueEvents needs its own connection instance. | [VERIFIED] |
| AWS ElastiCache | Use standard cache-nodes (not serverless — incompatible maxmemory-policy). TLS: `tls: {}` in ioredis options. Cluster mode works but needs slot configuration. | [VERIFIED] |
| pg-boss | Current stable v12.18.x. Pure ESM, requires Node >= 22.12.0, PostgreSQL >= 13. API: createQueue, send, work, schedule. Built-in dead letter queue and exponential backoff. | [VERIFIED] |
| FlowProducer | Still recommended for job chaining. FlowProducer.add({ name, data, opts, children }) atomically creates job trees. Parent waits for all children. | [VERIFIED] |

## When to activate

- "background job" / "job queue" / "worker"
- "async task" / "run this in the background"
- "cron job" / "scheduled task" / "run every X"
- "email queue" / "process uploads" / "bulk operation"
- "retry failed tasks" / "dead letter queue"
- "BullMQ" / "Bull" / "Redis queue"

## 5 questions to ask before designing

1. **What triggers the job?** — user action / API event / cron schedule / another job completing
2. **What happens if the job fails?** — retry silently / notify / move to dead letter queue
3. **How long can a job run?** — seconds / minutes / unbounded (affects timeout and concurrency config)
4. **Any CPU-intensive work?** — could block the event loop (needs sandboxed processor)
5. **Need a monitoring dashboard?** — to inspect queues and retry failed jobs

## Library decision table

| Scenario | Library | Why |
|----------|---------|-----|
| Node + persistent server + Redis | BullMQ + Redis | Battle-tested, feature-complete, horizontal scale |
| Have PostgreSQL, no Redis | pg-boss (Node) / arq / Celery (Python) | Reuse existing infra; pick per bound language |
| Python, local single-user (no broker) | APScheduler or a SQLite-backed queue | No Redis/broker to run on a desktop hub |
| Serverless / Vercel | Inngest or Trigger.dev | No persistent worker needed (out of scope here) |

**Primary recommendation: pick per bound stack** (see § Stack assumptions). Constants regardless of
library: workers run as a separate process; durable backing (not in-memory); attempts + exponential
backoff; idempotent handlers; graceful shutdown.

## Core BullMQ concepts

- **Queue** — named channel for jobs; producers add jobs here
- **Worker** — consumes jobs from a queue; runs in a separate process
- **Job** — unit of work with a name, data payload, and options
- **Repeatable job** — cron-scheduled job managed by BullMQ
- **FlowProducer** — chains jobs with parent/child dependencies
- **Dead letter queue** — failed jobs moved here after max retries exhausted

## Job options decision table

| Option | When to use | Example value |
|--------|------------|---------------|
| `attempts` | Any job that can fail transiently | 3–5 |
| `backoff` | Always pair with attempts | `{ type: 'exponential', delay: 2000 }` |
| `delay` | Schedule job for future execution | `5000` (ms) |
| `priority` | Time-sensitive jobs mixed with bulk | `1` (higher = more urgent) |
| `removeOnComplete` | High-volume queues (keep last N) | `{ count: 1000 }` |
| `removeOnFail` | Debugging mode (keep failed jobs) | `false` (default — keep them) |
| `timeout` | Long-running jobs with a time limit | `60000` (ms) |

## Cron / repeatable jobs

- Use BullMQ `repeat: { pattern: '0 * * * *' }` for cron expressions
- Use `repeat: { every: 60000 }` for interval-based (every 60 seconds)
- Always name repeatable jobs — use `jobId` to prevent duplicates on restart
- Remove stale repeatable jobs on deploy: call `queue.removeRepeatable()` for old patterns

## Dead letter queue pattern

- Create a separate `{queueName}:failed` queue
- In Worker's `failed` event listener: add failed job to the failed queue with full error context
- Allows manual inspection and replay without cluttering the main queue

## Graceful shutdown rule

Worker must call `worker.close()` on SIGTERM/SIGINT. Never kill the process mid-job. BullMQ waits for the current job to finish before closing — configure `closeTimeout` for max wait.

## Hard blocks

- Never run workers inside the web server process (separate process only)
- Never use an in-memory queue in production (always Redis-backed)
- Never set unlimited retries without exponential backoff (runaway retry storm)
- Never silently catch job errors — always rethrow or the job won't be marked as failed
- Never add jobs without a `removeOnComplete` policy on high-volume queues (Redis memory bloat)
- Never use `new Redis()` without `maxRetriesPerRequest: null` for BullMQ Worker connections

## Review checklist

- [ ] Worker runs in a separate process from the web server
- [ ] All jobs have `attempts` + exponential `backoff` configured
- [ ] Failed jobs are observable (Bull Board or failed queue)
- [ ] Repeatable jobs use named `jobId` to prevent duplicate registration
- [ ] Worker has SIGTERM handler calling `worker.close()`
- [ ] `removeOnComplete: { count: N }` set on high-volume queues
- [ ] Redis connection uses `maxRetriesPerRequest: null` (required by BullMQ)

## Gotchas / edge cases

- **maxRetriesPerRequest: null is mandatory**: BullMQ throws without it. Must be in every code example and the NEVER section.
- **QueueScheduler deprecated**: BullMQ v2+ removed the need for a separate QueueScheduler. Do not include it.
- **Duplicate repeatable jobs on restart**: Without a stable `jobId`, every app restart registers a new repeatable job. The `jobId` pattern is critical.
- **Empty catch blocks mark jobs as completed**: BullMQ only marks a job as failed if the processor throws. A silent `catch` makes failed jobs disappear silently.
- **Bull Board must be auth-gated**: The code example must show auth middleware. An unprotected Bull Board exposes all job data and allows manual retries.
- **AWS ElastiCache cluster mode**: Works with ElastiCache in single-node mode. Cluster mode requires additional config (enableOfflineQueue, slot routing).
- **Concurrency vs CPU**: Setting `concurrency: 5` means 5 jobs run concurrently in the same Node.js event loop. For CPU-heavy tasks, use sandboxed processors (separate child process per job).
