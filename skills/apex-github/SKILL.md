---
skill: apex-github
backend: claude
version: 1.1.0
last_updated: 2026-05-30
sources:
  - GitHub Docs — docs.github.com
  - GitHub CLI — cli.github.com
  - Conventional Commits — conventionalcommits.org
  - Keep a Changelog — keepachangelog.com
staleness_threshold: 30d
description: >
  Use when working with GitHub itself: repo setup, branch protection, PR/issue workflows,
  issue taxonomy & labels, Actions/CI, releases & changelogs, GitHub Projects, or filing a
  bug into Issues as the backlog. Triggers: "set up the repo", "PR workflow", "track this bug
  as an issue", "branch protection", "cut a release". Not for the debugging investigation
  itself (that's apex-debug) or for git mechanics unrelated to GitHub.
---

# GitHub Specialist — Planning Mode

## When to activate
Setting up a new repository, designing PR workflows, planning bug tracking and issue taxonomy,
configuring GitHub Actions, setting up releases and changelogs, branch protection rules,
or onboarding a project to GitHub Projects (v2).

## Questions to ask before designing

- Is this a solo project or will multiple contributors work on it?
- What is the branching strategy? (trunk-based, git-flow, GitHub flow)
- What should block a merge? (CI passing, review approval, specific checks)
- How are bugs tracked — GitHub Issues only, or alongside an external tool?
- What triggers a release? (tag push, manual, scheduled)

## Repository setup checklist

Every new repository should have these before the first feature:

**Branch protection (main/master):**
- Require PR before merging (no direct pushes)
- Require status checks to pass (CI, lint, type check)
- Require at least 1 approving review (2 for public repos)
- Dismiss stale reviews when new commits pushed
- Restrict force-pushes to admins only

**Repository files:**
- `README.md` — purpose, setup, usage
- `CONTRIBUTING.md` — branch naming, PR expectations, commit convention
- `CHANGELOG.md` — Keep a Changelog format
- `.github/CODEOWNERS` — auto-assign reviewers by path
- `.github/PULL_REQUEST_TEMPLATE.md` — standard PR structure
- `.github/ISSUE_TEMPLATE/bug_report.md` — structured bug reports
- `.github/ISSUE_TEMPLATE/feature_request.md` — feature requests
- `.gitignore` — project-appropriate ignores
- `SECURITY.md` — how to report vulnerabilities (even for private repos)

## Issue taxonomy — label system

A consistent label system across all repos:

**Type (what kind of work):**
- `bug` 🔴 — something broken
- `feature` 🟢 — new capability
- `chore` ⚪ — maintenance, dependency updates, refactor
- `docs` 🔵 — documentation only
- `security` 🟠 — security-related

**Priority (when to address it):**
- `P0-critical` — production broken, fix now
- `P1-high` — significant impact, fix this sprint
- `P2-medium` — important but can wait
- `P3-low` — nice to have

**Status (what's blocking):**
- `needs-triage` — not yet assessed
- `needs-repro` — cannot reproduce
- `blocked` — waiting on external dependency
- `good-first-issue` — suitable for contributors

**Area (which part of the system):**
- `area/frontend`, `area/backend`, `area/infra`, `area/data` etc.

## Bug tracking workflow

1. **Reporter** opens issue using bug template — fills: description, repro steps, expected vs actual, environment
2. **Triage** (within 24h for P0, 48h for P1): add type + priority labels, assign to milestone
3. **Investigation**: add `needs-repro` if can't reproduce; link related issues/PRs
4. **Fix**: reference issue in PR (`Fixes #123` auto-closes on merge); write failing test first
5. **Verify**: QA confirms fix in staging before closing

### Bug backlog → Issues (one home for unfixed bugs; routed from apex-debug)

Where a bug record lands depends on whether it was fixed:
- **Fixed in-session with a regression test** → git + test only. **Do NOT open an issue**
  (avoid created-and-closed noise). Root cause lives in the commit body; add `fixes #N` only
  if an issue already existed.
- **Known but unfixed** (deferred, escalated to planning, or recurrence-risk:high left
  unaddressed) → open a GitHub Issue. **Issues *is* the bug backlog** — `status.md` does not
  carry one. The eventual fix commit's `fixes #N` auto-closes it (the hub wiring ticket ↔
  commit ↔ test).

**Security / visibility gate — hard rail, runs BEFORE filing any bug issue:**
1. **Security / auth / data-loss bugs → never auto-file the details to an issue.** Keep them
   git-private; surface via a **private GitHub Security Advisory**, human-driven. Never write
   a working exploit or repro into a tracked issue.
2. **Check repo visibility first:** `gh repo view --json visibility`.
   - **public** → minimal, non-exploitable stub (or skip the issue entirely) — never a working repro.
   - **private** → full detail is acceptable.

**Bug report template:**
```markdown
## Description
<!-- What went wrong -->

## Steps to reproduce
1.
2.
3.

## Expected behaviour
## Actual behaviour

## Environment
- OS:
- Browser/Runtime:
- Version/SHA:

## Logs / screenshots
```

## PR workflow

**Branch naming:** `{type}/{issue-number}-short-description`
Examples: `fix/123-login-redirect`, `feat/456-export-csv`, `chore/update-deps`

**PR title convention (Conventional Commits):**
`{type}({scope}): {description}`
- `feat(auth): add OAuth2 Google login`
- `fix(api): correct pagination offset calculation`
- `chore(deps): upgrade Prisma to 5.14`

**PR template:**
```markdown
## What
<!-- What does this PR do? Link the issue: Fixes #NNN -->

## Why
<!-- Why is this change needed? -->

## How
<!-- Key implementation decisions -->

## Testing
- [ ] Unit tests added/updated
- [ ] Manual test steps: ...

## Checklist
- [ ] CHANGELOG.md updated
- [ ] No secrets or debug code left in
```

**Merge strategy:**
- Solo projects: Squash and merge (clean linear history)
- Team projects: Merge commit OR squash — pick one and enforce it

## GitHub Projects (v2) — issue board design

Recommended fields for a solo project board:
- **Status**: Backlog → In Progress → In Review → Done
- **Priority**: P0 / P1 / P2 / P3
- **Sprint**: current sprint label (or date-based iteration)
- **Estimate**: S / M / L / XL

Use **Workflows** to auto-move:
- Issue opened → Backlog
- PR merged → Done (if linked issue)
- Issue closed → Done

## Release management

**Semantic versioning:** `MAJOR.MINOR.PATCH`
- MAJOR: breaking change
- MINOR: new feature, backwards compatible
- PATCH: bug fix, backwards compatible

**Release process:**
1. Merge all changes for the release to main
2. Create tag: `git tag v1.2.3 && git push origin v1.2.3`
3. GitHub Action detects tag → runs tests → builds → creates GitHub Release
4. Draft release notes from CHANGELOG.md unreleased section
5. Move CHANGELOG.md `[Unreleased]` → `[1.2.3] — YYYY-MM-DD`

**Changelog format (Keep a Changelog):**
```markdown
## [Unreleased]
### Added
- New feature description

## [1.2.3] — 2026-05-27
### Fixed
- Bug description (#123)
```

## GitHub Security features

Enable on every repo:
- **Dependabot version updates**: auto-PRs for dependency upgrades
- **Dependabot security alerts**: alerts for known CVEs in dependencies
- **Secret scanning**: blocks committed secrets; push protection on
- **Code scanning (CodeQL)**: SAST on every PR for supported languages

## Review checklist

- [ ] Branch protection rules enabled on main/master
- [ ] Issue templates created (bug + feature minimum)
- [ ] CODEOWNERS defined — no orphaned code paths
- [ ] CHANGELOG.md present and up to date
- [ ] Dependabot enabled (security alerts minimum)
- [ ] Secret scanning + push protection enabled
- [ ] CI required status check blocks merge
- [ ] PR template references issue linking (`Fixes #NNN`)

## Standards

GitHub Docs: docs.github.com
Conventional Commits: conventionalcommits.org/en/v1.0.0
Keep a Changelog: keepachangelog.com/en/1.0.0
Semantic Versioning: semver.org
