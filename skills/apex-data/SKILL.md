---
skill: apex-data
version: 1.1.0
last_updated: 2026-05-24
sources:
  - Prisma Migrations — prisma.io/docs/guides/database/developing-with-prisma-migrate
  - Firecrawl — github.com/firecrawl/firecrawl
  - Firecrawl MCP — github.com/firecrawl/firecrawl-mcp-server
  - Repomix — github.com/yamadashy/repomix
  - Context7 — github.com/upstash/context7
staleness_threshold: 30d
---

# Data Specialist — Planning Mode

## When to activate
Database schema changes, migrations, Prisma model changes, data pipelines,
query optimisation, data integrity constraints.

## Questions to ask before designing

- Is this a breaking schema change? What is the migration strategy?
- Are there existing rows to backfill? How many?
- What indexes are needed for the expected query patterns?
- What are the data integrity requirements? (uniqueness, foreign keys, nullability)
- Can this migration run without downtime?

## Migration safety rules

Zero-downtime migration order for adding a required column:
1. Add column as nullable (migration 1, deploy)
2. Backfill existing rows (script)
3. Add NOT NULL constraint after backfill (migration 2, deploy)

Never rename a column in one migration — add new, backfill, remove old.

## Review checklist

- [ ] Migration is reversible (or rollback strategy documented)
- [ ] Indexes added for all foreign keys and frequently-queried columns
- [ ] NOT NULL columns have default values or migration handles backfill
- [ ] Unique constraints defined for business-unique fields
- [ ] Large table migrations reviewed for lock impact

## External data gathering tools

When specs require pulling data from external sources or the web:

**Firecrawl**: converts any URL to clean markdown/JSON for LLM consumption
- Single URL scraping, full site crawling, or batch processing thousands of URLs
- Agent endpoint: describe data needs in natural language — Firecrawl searches, navigates, and returns structured results
- Use for: scraping competitor data, ingesting documentation, pulling pricing data
- Output: markdown, structured JSON, or schema-validated extraction

**Repomix**: pack the entire codebase into a single AI-readable file
- Use for: cross-cutting data flow analysis, finding all usages of a schema field
- `repomix --include "prisma/**" --include "src/models/**"` for data-layer analysis

**Context7**: live library documentation — prevents hallucinated Prisma/SQL patterns
- Use before writing any migration to verify current Prisma schema syntax
