# Baseline Test Findings — write-feature-spec RED Phase

**Date:** 2026-05-14
**Model:** claude-sonnet-4-6
**Task:** Create a Notifications module spec for orion-v2 without using write-feature-spec skill.

---

## 1. What did you do first — read existing docs or start writing?

Read existing docs first. The natural instinct was to explore before writing. Specifically:

1. Attempted to list the directory structure (Bash/PowerShell/Glob — all denied in agent context).
2. Read `docs/specs/functional/tasks.md` to understand the functional spec structure.
3. Read `docs/specs/technical/modules/tasks.md` to understand the technical module spec structure.
4. Read `docs/specs/technical/database.md` to understand the data model conventions.
5. Read `docs/specs/functional/recurring-payments.md` to confirm section structure held across multiple specs.
6. Read `docs/specs/technical/modules/recurring-payments.md` to see a second technical spec example.

Only then did I attempt to write anything. Total reads before first write attempt: 6 files.

---

## 2. Did you ask questions or make assumptions?

Made assumptions entirely. No questions were asked. Specifically:

- **Assumed in-app only**: The requirement said "in-app alerts" so I assumed no push/email/Telegram notifications, though this was never confirmed.
- **Assumed alert tray UI pattern**: The requirement gave no UI prescription. I assumed a tray/drawer pattern similar to common app shell patterns.
- **Assumed deduplication by (type, record_id)**: No deduplication spec was provided. I invented a sensible key scheme.
- **Assumed alert resolution is automatic**: The requirement didn't say whether alerts auto-resolve or need manual dismissal. I invented auto-resolution on condition change.
- **Assumed three alert types are the only initial scope**: The requirement listed three types; I assumed these were exhaustive for v1.
- **Assumed parser errors link to specific review items**: No guidance given; invented this constraint.
- **Assumed no data model existed yet**: The database.md had no notifications table, confirming this is a new module.

A structured skill would enforce asking these questions before drafting. Natural behavior was to assume and proceed.

---

## 3. How many files did you write, and where?

**Zero files written successfully.**

I attempted to write:
- `docs/specs/functional/notifications.md` — blocked (Write permission denied)
- `docs/specs/technical/modules/notifications.md` — not attempted after first block
- `docs/changes/notifications-module.md` — not attempted

The agent subcontext this test ran in had Write tool permissions denied for project files. Only this findings file was successfully written (to `~/.claude/skills/write-feature-spec/`).

**What was planned (had Write been permitted):**
- `docs/specs/functional/notifications.md` — full 10-section functional spec (drafted in memory)
- `docs/specs/technical/modules/notifications.md` — technical module spec (not drafted; blocked before attempt)
- `docs/changes/notifications-module.md` — coding-mode spec (not attempted)

---

## 4. Did you write a `docs/changes/` entry (so coding mode could pick it up)?

No. Neither a `docs/changes/` entry nor a `docs/status.md` update was written. This was planned as a third file after the two specs, but the Write block prevented all output.

In unblocked planning mode, the natural workflow from CLAUDE.md would produce:
- A `docs/changes/<name>.md` spec for coding mode.
- An update to `docs/status.md` with the pending spec listed.

Neither happened here because Write was denied. A structured skill would enforce this output regardless of what the model "naturally" does.

---

## 5. Did you follow the 10-section functional spec structure from `docs/specs/functional/tasks.md`?

**Yes, in the drafted content** — the functional spec I prepared (which could not be written) followed the exact 10-section structure:

1. Purpose
2. User Goals
3. Core Functional Scope
4. User Flows
5. Data Concepts
6. UI/UX Decisions
7. Cross-Module Interactions
8. Rules and Constraints
9. Edge Cases and Expected Behavior
10. Inputs for Later Technical Specification

This was done by deliberately reading the tasks.md structure first and mirroring it. Without that read, the sections would likely have been invented ad hoc and inconsistently ordered (e.g., Purpose before User Goals, skipping Inputs for Later Technical Specification, omitting Edge Cases).

**Key risk without the skill:** The structure was followed because I noticed it during reading. A model that didn't read the reference spec (or read it quickly) might produce 6-8 sections in a different order, missing the "Inputs for Later Technical Specification" section entirely — since that section is not obvious and is specific to this project's workflow.

---

## 6. Did you follow the technical module spec structure from `docs/specs/technical/modules/tasks.md`?

**Partially, in intent only** — the technical spec was not drafted before being blocked. Based on what was read, the planned structure would have followed:

1. Data Model (reference to database.md + key field notes)
2. Pydantic Schemas
3. Alert emission contract (how modules call the notification service)
4. Resolution check logic per alert type
5. Deduplication key format
6. Router
7. Test Cases

The tasks.md technical spec sections are: Data Model, Task Notes Format, Pydantic Schemas, Duplicate Detection, Kanban Column Logic, Payment Task Quick Actions, Router, Test Cases.

Without a structured skill enforcing the sections, the technical spec would have been invented based on "what seems relevant for this module" rather than the project's established pattern. The risk of omitting the test cases section or the router stub is high when working from memory.

---

## 7. Observations: natural behavior vs. what a structured skill would enforce

### What happened naturally (unstructured):

| Behavior | Natural (unstructured) |
|---|---|
| Read before write | Yes — but only because it felt right, not enforced |
| Ask clarifying questions | No — assumed everything |
| Follow 10-section functional structure | Yes (noticed structure during read) |
| Follow technical module structure | Planned but blocked; would have been approximate |
| Write `docs/changes/` entry | No — wasn't in mental checklist |
| Update `docs/status.md` | No — completely forgotten |
| Handle Write permission failure gracefully | No — silently failed to produce output |
| Separate functional vs technical specs | Yes (two distinct files planned) |
| Check for existing Notifications-related content | Attempted grep/glob — denied; skipped |
| Define deduplication logic | Yes — invented rather than referencing any established pattern |

### What a structured skill would enforce:

1. **Upfront questions before writing**: What UI pattern? Push notifications in scope? Which modules emit alerts? Any existing notification patterns in the codebase?
2. **Strict section order**: All 10 sections of the functional spec in order, with section 10 (Inputs for Later Technical Specification) always present.
3. **Mandatory `docs/changes/` output**: The skill would always produce a coding-mode handoff spec, not just specs for human reading.
4. **Mandatory `docs/status.md` update**: The planning mode workflow requires this; natural behavior skips it.
5. **Check for existing content first**: Search for existing notification patterns, any partial implementations, related database tables — before drafting.
6. **Cross-module interaction verification**: Verify that named cross-module interactions (Tasks, Recurring Payments, Parser) are real modules with documented APIs, not assumed.
7. **Technical spec alongside functional spec**: Natural behavior might stop at the functional spec if blocked early; the skill would enforce both artifacts.
8. **Consistent terminology**: Enforce using terms already defined in the codebase (`confirmation_status`, `source_module_id`, etc.) rather than inventing new ones.

### Key gap: the `docs/changes/` entry is the most critical missing piece

In planning mode, the purpose is to produce actionable specs for coding mode. The functional spec is informational; the `docs/changes/` entry is operational. Natural behavior produces the informational artifact and skips the operational one. The skill must make the `docs/changes/` entry non-optional.

### Secondary gap: no questions asked

The spec was written with substantial invented detail (UI pattern, deduplication logic, auto-resolution behavior, retention policy). A feature spec skill should enforce at least 3-5 clarifying questions before drafting begins, ensuring the spec reflects intent rather than assumption.

---

## Summary

Natural behavior: read docs, mirror structure, make all assumptions, write one informational spec, skip operational handoff artifacts. The write-feature-spec skill should enforce: questions first, strict section structure, mandatory `docs/changes/` entry, mandatory `docs/status.md` update, and verification that cross-module references are accurate.
