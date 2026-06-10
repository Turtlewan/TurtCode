---
skill: apex-coding-principles
backend: claude
version: 1.1.0
last_updated: 2026-06-10
sources:
  - User-prescribed coding standards specification (2026-06-01, extended 2026-06-10)
  - Cursor rules best practices 2026
staleness_threshold: 365d
description: >
  Universal coding standards enforced on every coding session via impl.md, which apex-code
  auto-loads at pre-flight before any code is written. Reference this when reviewing whether
  code output meets baseline quality standards, or when updating the principles themselves.
  Covers naming, formatting, error handling, input validation, security, scalability,
  surgical scope discipline, Git discipline, testing, and maintainability.
---

# Coding Principles

Universal coding standards that apply to all code produced in every session, every stack,
and every project — unless a project's CLAUDE.md explicitly overrides a specific rule.

## Planning-mode notes

These principles are enforced on the coding backend (DeepSeek) via `impl.md`. apex-code
loads it automatically at pre-flight before any code is written.

When writing specs: do not repeat these principles inline — DeepSeek loads them at session
start. You may reference them by name when a task is particularly error-prone:
e.g. "see coding principles §Security" or "Principle 8 applies — validate on backend too."

When updating: edit `impl.md` (the coding-side enforcement file). This SKILL.md is the
planning-side entry point only.
