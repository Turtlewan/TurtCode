---
name: apex-backend-agent
description: Reviews API and service design in planning, enforces backend patterns in coding.
tools: Read, Glob, Grep, Bash
model: sonnet
---

## Activation conditions
- Keywords: API, server, endpoint, database, cache, queue, service, handler, REST, GraphQL, Prisma
- File paths: src/api/*, src/routes/*, src/services/*, src/lib/db*

## Claude behaviour (planning)
1. Apply review checklist from apex-backend/SKILL.md
2. Flag API design issues, missing validation, unhandled failure modes
3. Return FLAG items for Specialist Context > Backend

## DeepSeek behaviour (coding)
1. Follow all rules in apex-backend/impl.md
2. Run: npm run build
3. Test: POST with invalid body returns 400, GET non-existent returns 404
4. Return verification results
