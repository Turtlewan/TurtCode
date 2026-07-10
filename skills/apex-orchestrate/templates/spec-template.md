---
spec: {short-name}
status: draft
token_profile: balanced
autonomy_level: L2
# cross_model_review: true   # optional — high-stakes builds (auth / security / data). Runs an
#                              independent 2nd review by a DIFFERENT model family than the builder
#                              (family-aware: Codex-built → Opus reviews; Opus-built → Codex reviews).
#                              Runs via headless `codex exec` on any host (ADR-027). Advisory only.
# coder_model: codex         # optional — pin this WHOLE spec to one coder. Value from status.md
#                              coder_models {codex|opus}. Absent → Codex (the default); opus pins the
#                              whole spec to the Opus fallback coder (ADR-027).
# coder_effort: medium       # optional — Codex reasoning effort {low|medium|high|xhigh|max|ultra}.
#                              Absent → medium (default). low = trivial/mechanical; high = risk:high /
#                              auth / security / data / hard; xhigh = hardest async/eval work only;
#                              max = hardest single tasks (state migrations, IAM/auth-critical, gnarly
#                              concurrency); ultra = RARE per-task escalation above max — spawns
#                              in-model subagents, counts DOUBLE against max_parallel_codex, not for
#                              routine use pending head-to-head eval vs max (ADR-030).
# max_parallel_codex: 3      # optional — cap on concurrent `codex exec` subprocesses per wave
#                              (ADR-028). 1 = sequential. Absent → status.md default (auto-sized
#                              min(4, floor(cores/2)−1), fallback 3). Machine-protection, not a quota cap.
---

# Spec: {title}

**Identity:** {one line — what this builds, for routing/review/recall. NOT rationale.}
<!-- Optional, on its own line: → why: see docs/technical/adr/ADR-NNN-*.md (a pointer, never the content). -->

<!-- A spec is an EXECUTION SCRIPT, not a design doc: rich on the *what* (exact files,
     copy-paste-ready detail, per-task verify), stripped of the *why*. The coder executes against
     frozen acceptance criteria; build-changing judgment is resolved in planning, not the build. Spec-authoring rules:
     - No why inline. Litmus when tempted: does it change what gets built? No → cut it
       (home = ADR / planning discussion). Yes → don't add the why, make the *what* explicit.
     - List files per task — every task names its exact files (see ## Tasks). Never "update the auth flow."
     - Cross-cutting conventions live in the relevant skill's impl.md, never copied into the spec. -->

<!-- Split rule: if this spec touches >3 files OR has >2 logical phases, split it into separate specs. -->

## Intent
<!-- Optional for single-task specs, recommended otherwise. ≤10 lines, what-bearing — the ONE
     sanctioned home for load-bearing intent; it travels to the coder in the dispatch pack
     (ADR-031) so mismatches resolve against stated invariants instead of guesses.
     Never an ADR essay — rationale lives in the ADR. -->
- **Intent:** {1-2 lines — the outcome this spec exists to produce}
- **Invariants:** {properties that must hold when done — behavioural/structural, testable where possible}
- **Non-goals:** {adjacent work this spec deliberately does NOT do}

## Assumptions
<!-- Planning mode fills this. Coding mode verifies each item before executing. -->
<!-- Format: assumption → impact if wrong (Stop | Caution | Low) -->
- {Assumption 1} → impact: {Stop | Caution | Low}
- {Assumption 2} → impact: {Stop | Caution | Low}

<!-- Simplicity check (planning fills this): -->
<!-- "Is there a simpler spec? ___. Why this version: ___." -->
Simplicity check: {considered simpler approach? yes/no — if yes, why this version instead}

## Prerequisites
<!-- Build-load-bearing for cross-spec parallelism (ADR-029): at a batch "build specs", two specs
     run concurrently only when BOTH dependency-independent (this list, transitive) AND file-disjoint
     (their ## Files to Change don't intersect). List every prerequisite spec precisely — a missing
     edge, or a shared file unlisted here/below (e.g. two specs both editing one types.py or
     re-exporting into one package __init__.py), costs a needless serialization or a clobbering build.
     Design FOR this: give each shared file ONE owning spec and list that spec here, rather than
     co-editing it from two specs. -->
- Specs that must be complete first (or "none")
- Environment setup required (or "none")

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| {full/path/to/file.ts} | create \| modify \| delete | {what changes} |

## Tasks
<!-- Every task names its exact files — never "update the auth flow" (forces the worker to explore = context cost + scope creep; the file list is also the wave grouping + scope lock). -->
- [ ] Task 1: {description} — files: {full/path/a.ts, full/path/b.ts} — done when: {observable outcome}
- [ ] Task 2: {description} — files: {full/path/c.ts} — done when: {observable outcome}
- [ ] Task 3: {description} — files: {full/path/d.ts} — done when: {observable outcome}

## Wave plan
<!-- Required for specs with ≥3 tasks. Planning derives this from stated dependencies; coding
     executes it verbatim (no dependency inference). Tasks in the same wave run in parallel.
     Under ADR-027 the coder is Codex by default for every task (Opus is the manual fallback,
     handled at build time by apex-code) — emit the normal untagged wave plan; don't tag ▸opus
     proactively. Full rubric in apex-plan § Model-routing build planning. -->
Wave 1: [task 1, task 2] | Wave 2: [task 3]

## Permissions

The following actions will run autonomously during build.
Approving this spec approves all of them.

### File Operations
| Action | Paths |
|--------|-------|
| Create | {full/path/to/new-file.ts} |
| Modify | {full/path/to/existing.ts} |
| Delete | (none) |

### Commands
| Command | Purpose |
|---------|---------|
| `{exact command}` | {what it does} |

### Git Operations
| Operation | Scope |
|-----------|-------|
| `git add` | {path pattern} |
| `git commit` | "{conventional commit message}" |

### Environment Access
| Variable | Purpose |
|----------|---------|
| `{VAR_NAME}` | {what it's used for} |

### Network
| Action | Purpose |
|--------|---------|
| `npm install` | Package installation |

## Specialist Context
### Security
(none — or findings from apex-security review)

### Performance
(none — or constraints/budgets)

### Accessibility
(none — or a11y requirements if frontend change)

## Documentation
| Doc type | File | Action |
|----------|------|--------|
| Inline | {path} | JSDoc/TSDoc all exports |
| API | docs/product/api/{name}.md | {add/update} section |
| Changelog | CHANGELOG.md | Add entry under Unreleased |
| ADR | docs/technical/adr/ADR-{NNN}-{title}.md | Write (if architectural decision) |

## Acceptance Criteria
<!-- Use step→verify format. "Done" must be observable, not vague. -->
- [ ] {Step 1} → verify: {what to check — specific, observable}
- [ ] {Step 2} → verify: {what to check — specific, observable}
- [ ] {Step 3} → verify: {what to check — specific, observable}

## Progress
_(Coding mode writes here — do not edit manually)_
