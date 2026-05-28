---
skill: apex-performance
backend: claude
version: 1.1.0
last_updated: 2026-05-28
sources:
  - Web Vitals — web.dev/vitals
  - Prisma Performance — prisma.io/docs/guides/performance-and-optimization
  - Vercel Agent Skills — github.com/vercel-labs/agent-skills
  - Web Quality Skills (addyosmani) — github.com/addyosmani/web-quality-skills
  - Playwright MCP — github.com/microsoft/playwright-mcp
staleness_threshold: 14d
---

# Performance Specialist — Planning Mode

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

## Review checklist

- [ ] N+1 queries identified and resolved (use include/select, not nested loops)
- [ ] Appropriate indexes on frequently-queried columns
- [ ] Caching strategy defined for expensive or repeated operations
- [ ] Pagination on all list endpoints — no unbounded queries
- [ ] Images optimised (next/image with appropriate sizes)
- [ ] Large data processing moved to background jobs
