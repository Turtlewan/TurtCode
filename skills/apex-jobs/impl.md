---
skill: apex-jobs
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - BullMQ Docs — docs.bullmq.io
  - Bull Board — github.com/felixmosh/bull-board
staleness_threshold: 30d
---

## NEVER do

- Import Queue or Worker in the same entry file as your Express/Fastify server
- Use `new Redis()` without `maxRetriesPerRequest: null` — BullMQ requires it
- Swallow errors inside a job processor with an empty catch block
- Register repeatable jobs without checking if they already exist (causes duplicates)
- Set `removeOnFail: true` in production — you lose debugging context

## ALWAYS do

- Run workers in a dedicated entry file (`worker.ts`) started as a separate process
- Set `maxRetriesPerRequest: null` on the ioredis connection passed to BullMQ
- Rethrow or let errors propagate in job processors — BullMQ needs uncaught errors to mark jobs failed
- Call `worker.close()` on SIGTERM before process exits
- Log job ID, queue name, and attempt number on every failure
- Configure `removeOnComplete: { count: N }` on high-volume queues to prevent Redis memory bloat

## Code example — Redis connection (required config)

```typescript
import { Queue, Worker } from 'bullmq'
import IORedis from 'ioredis'

const connection = new IORedis(process.env.REDIS_URL, {
  maxRetriesPerRequest: null, // required by BullMQ
})
```

## Code example — producer (adding a job)

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

## Code example — worker (consuming jobs)

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

## Code example — cron / repeatable job

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

## Code example — Bull Board setup (Express)

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

## Verification checklist

- [ ] `npm run build` — 0 TypeScript errors
- [ ] Worker process starts independently: `npx ts-node worker.ts`
- [ ] Add a test job → appears in Bull Board as completed
- [ ] Force a job to throw → appears in Bull Board as failed with error message
- [ ] Kill worker mid-job with SIGTERM → job completes before process exits
- [ ] Repeatable job registered → appears in Bull Board Repeatable tab
- [ ] Redis memory: `redis-cli info memory` — no unexpected growth after 100 jobs
