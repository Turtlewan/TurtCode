---
skill: apex-performance
backend: coding
version: 1.2.0
last_updated: 2026-06-13
sources:
  - Web Vitals — web.dev/vitals
  - Prisma Performance — prisma.io/docs/guides/performance-and-optimization
  - SP5 de-coupling (stack-neutral core; Prisma/TS illustration)
staleness_threshold: 14d
description: >
  Coding-mode performance rules — stack-neutral invariants (no query-in-a-loop / N+1, always
  paginate, index filtered/sorted/joined columns, don't block the event loop with sync CPU work,
  cache expensive infrequently-changing data, import only what's needed). Loaded on perf-sensitive
  work. The ORM eager-load + bundle tooling is stack-specific (Prisma `include` / SQLAlchemy
  `selectinload`); see § Stack assumptions.
---

# apex-performance — performance implementation rules

Capability skill — **stack-neutral**. The invariants apply on any stack; the concrete eager-load API
and profiling tools come from the bound stack (see § Stack assumptions). The bound stack skill's
Verification Recipe is the verifier.

## Stack assumptions

Rules below are stack-neutral; the snippet assumes **Prisma + TypeScript**. On the bound stack, swap:

- **Eager-load related data:** Prisma `include` → **Python:** SQLAlchemy `selectinload` / `joinedload`; **Swift/SwiftData:** fetch with relationships / batch. Goal: one query, not N.
- **Don't block the loop:** Node event loop → **Python:** never run sync CPU-heavy work in an async handler (offload to a thread/process pool); **Swift:** never block the main actor — move heavy work off-main.
- **Pagination:** Prisma `take`/cursor → the stack's LIMIT + keyset/cursor pagination.
- **Bundle/size check:** `npm run build` size → the stack's build/size tool (irrelevant for a pure API).

## NEVER do

- Query the database inside a loop — batch with an eager-load (`include` / `selectinload`) or one `WHERE ... IN`.
- Load all rows from a table — always paginate or limit.
- Block the event/request loop (or main actor) with synchronous CPU-heavy operations.
- Import an entire library when a subset is needed.
- Fetch the same data multiple times in one request lifecycle.

## ALWAYS do

- Eager-load related data in one query — never N queries for N records.
- Add a database index for any column used in `WHERE`, `ORDER BY`, or `JOIN`.
- Set a page-size limit on all list queries (default max 100 per page).
- Use cursor/keyset pagination for large or growing datasets.
- Cache expensive, infrequently-changing data (Redis / in-memory / HTTP cache headers).

## N+1 prevention (Prisma + TypeScript illustration)

> Same rule on any stack: one eager-loaded query, not a loop of lookups. Python: SQLAlchemy
> `selectinload`; the BAD/CORRECT contrast is identical.

```typescript
// BAD — N+1 query
const orders = await prisma.order.findMany()
for (const order of orders) {
  const user = await prisma.user.findUnique({ where: { id: order.userId } }) // N queries
}

// CORRECT — single query with include
const orders = await prisma.order.findMany({
  include: { user: { select: { id: true, name: true } } },
})
```

## Frontend — Core Web Vitals diagnostic decision tree

When a web frontend has a performance complaint, start here before optimising:

```
What is slow?
├── First page load / LCP
│   ├── TTFB > 800ms?
│   │   ├── DNS long → <link rel="dns-prefetch"> / <link rel="preconnect"> for known origins
│   │   ├── TCP/TLS long → enable HTTP/2, verify keep-alive, check edge deployment
│   │   └── Server wait long → profile backend, check slow queries and caching
│   ├── Render-blocking resources? → check network waterfall for CSS/JS blocking
│   └── LCP image not prioritised? → add fetchpriority="high", remove loading="lazy" from LCP image
├── Interaction sluggish / high INP
│   ├── Long tasks on main thread (>50ms)? → break up with scheduler.yield() or yieldToMain fallback
│   ├── Non-critical work in event handler? → defer analytics/logging out of the handler
│   └── Form input lag? → check re-renders, controlled component overhead
├── Layout shift / high CLS
│   ├── Images missing width/height? → always set explicit dimensions on <img> and <source>
│   ├── Font swap causing reflow? → use size-adjust/ascent-override/descent-override on fallback
│   └── SPA route change causing shift? → use View Transitions API to prevent layout flash
└── Page after navigation slow?
    ├── bfcache blocked? → remove unload handlers; avoid Cache-Control: no-store on HTML responses
    └── API waterfall? → profile component render time, check for N+1 fetches
```

## Frontend — INP scheduling APIs (2025-current)

When long tasks block the main thread and hurt INP, use these APIs in priority order:

```typescript
// 1. scheduler.yield() — preferred; yields to input, then resumes (Chrome 115+)
async function processLargeList(items: Item[]) {
  for (let i = 0; i < items.length; i++) {
    processItem(items[i]);
    if (i % 50 === 0) await scheduler.yield(); // yield every 50 items
  }
}

// 2. isInputPending() — yield ONLY when input is waiting (avoids unnecessary yields)
async function processWithInputCheck(items: Item[]) {
  for (let i = 0; i < items.length; i++) {
    processItem(items[i]);
    if (navigator.scheduling?.isInputPending()) await scheduler.yield();
  }
}

// 3. scheduler.postTask() — priority-aware task scheduling
scheduler.postTask(() => runAnalytics(), { priority: 'background' });
scheduler.postTask(() => updateUI(), { priority: 'user-visible' });

// 4. yieldToMain fallback — for browsers without scheduler.yield()
function yieldToMain(): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, 0));
}
```

## Frontend — font CLS fixes

Fonts are a common CLS source. Use these patterns:

```css
/* size-adjust: match fallback font metrics to prevent layout shift on swap */
@font-face {
  font-family: 'MyFont';
  src: url('/fonts/myfont.woff2') format('woff2');  /* WOFF2 only — smallest format */
  font-display: swap;
  unicode-range: U+0000-00FF; /* subset — ship only the glyphs this page needs */
}
@font-face {
  font-family: 'MyFont-Fallback';
  src: local('Arial');
  ascent-override: 90%;      /* tune these values to match the custom font's metrics */
  descent-override: 20%;
  line-gap-override: 0%;
  size-adjust: 107%;         /* scale the fallback so swap causes ≈0 layout shift */
}
/* Consider variable fonts when multiple weights/styles are needed — one file replaces many */
```

## Frontend — image priority patterns

```html
<!-- LCP hero image: high priority, art-direction with <picture>, no lazy loading -->
<picture>
  <source media="(max-width: 767px)"
    srcset="/hero-mobile-400.avif 400w, /hero-mobile-800.avif 800w"
    sizes="100vw" width="800" height="1000" type="image/avif" />
  <source srcset="/hero-800.avif 800w, /hero-1200.avif 1200w"
    sizes="(max-width: 1200px) 100vw, 1200px" width="1200" height="600" type="image/avif" />
  <img src="/hero.jpg" width="1200" height="600" fetchpriority="high" alt="Hero" />
</picture>

<!-- Below-the-fold image: lazy loaded, async decoding -->
<img src="/content.webp" width="800" height="400" loading="lazy" decoding="async" alt="..." />
```

## Acceptance checks (stack-neutral)

- No database query runs inside a loop in the changed files.
- `EXPLAIN` on any new join/filter query uses an index (no full scan on a large table).
- Every new list endpoint has a page-size limit.
- For a frontend build, the bundle size shows no unexpected increase.
- For frontend INP work: long tasks (>50ms) broken up with `scheduler.yield()` or `yieldToMain`.
- For frontend CLS work: images have explicit `width`/`height`; fonts use `size-adjust` if swapping.
