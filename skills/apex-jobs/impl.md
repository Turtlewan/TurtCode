---
skill: apex-jobs
backend: coding
version: 1.1.0
last_updated: 2026-05-31
sources:
  - BullMQ Docs — docs.bullmq.io
  - Bull Board — github.com/felixmosh/bull-board
  - SP5 de-coupling (stack-neutral core; references/ illustration)
staleness_threshold: 30d
description: >
  Coding-mode rules for background jobs — stack-neutral invariants (worker separate from web,
  retry + backoff, never-swallow-errors, durable backing, graceful shutdown, idempotent handlers).
  Loaded when a task adds async/queued/scheduled work. Concrete code is bound-stack-specific — the
  BullMQ + TypeScript worked examples live in references/bullmq-typescript.md.
---

# apex-jobs — background-jobs implementation rules

Capability skill — **stack-neutral**. The bound stack skill's Verification Recipe is the verifier;
the concrete queue library + language come from the bound stack (see § Stack assumptions).

## Stack assumptions

Rules below are stack-neutral; the worked examples assume **BullMQ + Redis + TypeScript**
(`references/bullmq-typescript.md`). On the bound stack, swap:

- **Queue/worker library:** BullMQ + ioredis → **Python:** arq (Redis, async) / Celery / RQ; **local single-user (no broker):** APScheduler or a SQLite-backed queue.
- **Durable backing:** Redis → Redis / Postgres / **SQLite** (local) — never purely in-memory.
- **Retry + backoff:** BullMQ `attempts` + `backoff` → arq `max_tries` / Celery `retry_backoff`.
- **Cron:** BullMQ `repeat` + `jobId` → arq cron / APScheduler `CronTrigger` / Celery beat — a stable id to avoid duplicate registration.
- **Shutdown:** `worker.close()` on SIGTERM → arq SIGTERM handling / APScheduler `shutdown(wait=True)`.

## NEVER do

- Run the worker inside the web-server process — it must be a separate process/worker.
- Use a purely in-memory queue for durable work — back it with Redis / Postgres / SQLite so jobs survive restart.
- Swallow errors inside a job handler with an empty catch — rethrow/propagate so the runner marks it failed.
- Register a repeatable/cron job without a stable id — every restart re-registers it (duplicates).
- Drop failed-job context in production (e.g. BullMQ `removeOnFail: true`) — you lose debugging info.

## ALWAYS do

- Run workers in a dedicated entrypoint started as a separate process.
- Pair retries with exponential backoff (`attempts` + `backoff`, or the library equivalent).
- Make job handlers idempotent — a job may run more than once (retry / at-least-once delivery).
- Rethrow/propagate handler errors so the runner marks the job failed.
- Log job id, queue/name, and attempt number on every failure.
- Handle the shutdown signal so the current job finishes before exit (graceful shutdown).
- Cap retention on high-volume queues (completed-job removal policy) so the backing store doesn't bloat.

## Acceptance checks (stack-neutral)

- Worker process starts independently of the web server.
- A job that throws → ends up observably failed (dashboard or failed table) with its error.
- Kill the worker mid-job with the shutdown signal → the in-flight job completes before exit.
- A repeatable/cron job registers exactly once across restarts (stable id).
- Re-deliver the same job → handler is idempotent (no duplicate side effects).

## Worked examples (load on demand)

> The concrete **BullMQ + TypeScript** implementation (Redis connection, producer, worker,
> cron/repeatable, Bull Board dashboard) is in **`references/bullmq-typescript.md`** — load it
> **only when the bound stack is BullMQ + TypeScript**. On another stack, follow the bound stack
> skill's patterns and the swaps in § Stack assumptions.
