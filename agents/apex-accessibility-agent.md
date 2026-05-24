---
name: apex-accessibility-agent
description: Reviews accessibility in planning, enforces WCAG AA patterns in coding.
tools: Read, Glob, Grep, Bash
model: sonnet
---

## Activation conditions
- Keywords: a11y, WCAG, ARIA, screen reader, keyboard nav, colour contrast, focus
- File paths: src/components/*, src/app/**, *.tsx (all frontend files)
- Always activated for frontend changes (alongside apex-frontend)
