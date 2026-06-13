---
skill: apex-performance
backend: claude
version: 1.4.0
last_updated: 2026-06-13
sources:
  - Web Vitals — web.dev/vitals
  - Prisma Performance — prisma.io/docs/guides/performance-and-optimization
  - Vercel Agent Skills — github.com/vercel-labs/agent-skills
  - Web Quality Skills (addyosmani) — github.com/addyosmani/web-quality-skills
  - Playwright MCP — github.com/microsoft/playwright-mcp
staleness_threshold: 14d
description: >
  Use when addressing performance — latency, slow loads, N+1 queries, bundle size, memory/CPU,
  throughput. Measure-first; sets budgets (Core Web Vitals LCP/INP/CLS, API p95). Principles are
  stack-neutral (eager-load not N+1, index hot columns, paginate, cache, don't block the loop);
  the eager-load API + profiling tools are per-stack (Prisma ↔ SQLAlchemy), see § Stack assumptions.
  Not the coding-mode enforcement rules (that's impl.md).
---

# Performance Specialist — Planning Mode

## Stack assumptions

The performance principles here are **stack-neutral** (measure-first, eager-load instead of N+1,
index hot columns, paginate, cache, don't block the loop). Core Web Vitals apply to any web
frontend. The concrete eager-load API and profiling tools are per-stack — Prisma `include` ↔
SQLAlchemy `selectinload`; `next/image` ↔ the stack's image pipeline. See impl.md § Stack assumptions.

## When to activate
Latency complaints, slow page loads, N+1 query patterns, large bundle sizes,
memory leaks, high CPU usage, throughput requirements.

## Questions to ask before designing

- Where is the bottleneck? (measure first — don't guess)
- What are the performance targets? (specific numbers, not "fast")
- Is this a one-time load or repeated operation?
- What is the caching strategy?
- What is the database query plan for this operation?

## Performance budgets (defaults)

API response: p95 < 200ms for simple reads, < 500ms for complex queries
Page load: LCP ≤ 2.5s, INP ≤ 200ms (FID deprecated — use INP), CLS ≤ 0.1
JS bundle: < 300KB compressed (total page JS)
CSS: < 100KB compressed
Images: < 500KB above-fold total
Third-party scripts: < 200KB
Total page weight: < 1.5MB
Database query: < 100ms for user-facing queries

## Core Web Vitals thresholds (from Google/web-quality-skills)

| Metric | Good | Needs Improvement | Poor |
|--------|------|------------------|------|
| LCP | ≤ 2.5s | 2.5–4.0s | > 4.0s |
| INP | ≤ 200ms | 200–500ms | > 500ms |
| CLS | ≤ 0.1 | 0.1–0.25 | > 0.25 |

## Metric-Honesty Rule

An LLM reading static source code cannot measure real-world LCP, INP, or CLS. **Never fabricate metric numbers.** When asked about performance:
- Without tool data: return a source-level findings report; mark every finding as "potential impact", not a measurement.
- With tool data: label each value with its source — `Field (CrUX)` for real-user p75 data, `Lab (Lighthouse)` for synthetic runs. These are not interchangeable.

Require field (CrUX) or lab (Lighthouse/DevTools) data before treating a metric as a known fact.

## Review checklist

- [ ] N+1 queries identified and resolved (eager-load: include/select or selectinload, not nested loops)
- [ ] Appropriate indexes on frequently-queried columns
- [ ] Caching strategy defined for expensive or repeated operations
- [ ] Pagination on all list endpoints — no unbounded queries
- [ ] Images optimised (the stack's image pipeline — e.g. next/image — with appropriate sizes)
- [ ] Large data processing moved to background jobs
