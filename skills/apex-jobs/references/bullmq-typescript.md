# apex-jobs — BullMQ + Redis + TypeScript worked examples

**Load condition:** read this file only when the bound stack is **BullMQ + Redis + TypeScript**.
On another stack, follow the bound stack skill's patterns and the swaps in `impl.md` § Stack
assumptions (e.g. Python arq / APScheduler / a SQLite-backed queue). These are *one stack's
illustration* of the stack-neutral rules in `impl.md`.

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

## Redis connection (required config)

```typescript
import { Queue, Worker } from 'bullmq'
import IORedis from 'ioredis'

const connection = new IORedis(process.env.REDIS_URL, {
  maxRetriesPerRequest: null, // required by BullMQ
})
```

## Producer (adding a job)

```typescript
const emailQueue = new Queue('email', { connection })

await emailQueue.add(
  'send-welcome',
  { userId, email },
  {
    attempts: 3,
    backoff: { type: 'exponential', delay: 2000 },
    removeOnComplete: { count: 1000 },
  }
)
```

## Worker (consuming jobs)

```typescript
// worker.ts — separate process, not imported by server
const worker = new Worker(
  'email',
  async (job) => {
    if (job.name === 'send-welcome') {
      await sendWelcomeEmail(job.data.email)
    }
  },
  { connection, concurrency: 5 }
)

worker.on('failed', (job, err) => {
  console.error(`Job ${job?.id} failed on attempt ${job?.attemptsMade}:`, err.message)
})

// Graceful shutdown
process.on('SIGTERM', async () => {
  await worker.close()
  process.exit(0)
})
```

## Cron / repeatable job

```typescript
// Register once on app start — use jobId to prevent duplicates
await queue.add(
  'daily-report',
  {},
  {
    repeat: { pattern: '0 8 * * *' }, // every day at 08:00
    jobId: 'daily-report-cron',       // stable ID prevents duplicate registration
    removeOnComplete: true,
  }
)
```

- Use `repeat: { pattern: '0 * * * *' }` for cron expressions; `repeat: { every: 60000 }` for interval-based (every 60 seconds)
- Always name repeatable jobs — the stable `jobId` prevents duplicates on restart
- Remove stale repeatable jobs on deploy: call `queue.removeRepeatable()` for old patterns

## Bull Board setup (Express, auth-gated)

```typescript
import { createBullBoard } from '@bull-board/api'
import { BullMQAdapter } from '@bull-board/api/bullMQAdapter'
import { ExpressAdapter } from '@bull-board/express'

const serverAdapter = new ExpressAdapter()
serverAdapter.setBasePath('/admin/queues')

createBullBoard({
  queues: [new BullMQAdapter(emailQueue)],
  serverAdapter,
})

app.use('/admin/queues', requireAdminAuth, serverAdapter.getRouter())
```

## BullMQ-specific verification

- [ ] Worker process starts independently: `npx ts-node worker.ts`
- [ ] Add a test job → appears in Bull Board as completed
- [ ] Force a job to throw → appears in Bull Board as failed with error message
- [ ] Repeatable job → appears in the Bull Board Repeatable tab
- [ ] Redis memory: `redis-cli info memory` — no unexpected growth after 100 jobs
