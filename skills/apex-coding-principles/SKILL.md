---
skill: apex-coding-principles
version: 1.1.2
last_updated: 2026-07-29
sources:
  - User-prescribed coding standards specification (2026-06-01, extended 2026-06-10)
  - Cursor rules best practices 2026
staleness_threshold: 365d
description: >
  Universal coding standards (naming, formatting, error handling, input validation,
  security, scalability, scope discipline, Git discipline, testing, maintainability)
  apex-code auto-loads via impl.md before writing code; also used to review code quality.
---

# Coding Principles

Universal coding standards that apply to all code produced in every session, every stack,
and every project — unless a project's CLAUDE.md explicitly overrides a specific rule.

## Planning-mode notes

These principles are enforced via `impl.md`, which apex-code loads automatically at pre-flight
before any code is written.

When writing specs: do not repeat these principles inline — the coder loads them at session
start. You may reference them by name when a task is particularly error-prone:
e.g. "see coding principles §Security" or "Principle 8 applies — validate on backend too."

When updating: edit `impl.md` (the coding-side enforcement file). This SKILL.md is the
planning-side entry point only.
