---
skill: apex-github
backend: deepseek
version: 1.1.0
last_updated: 2026-06-01
sources:
  - GitHub CLI Docs — cli.github.com/manual
  - GitHub Actions Docs — docs.github.com/en/actions
  - SP5 de-coupling (stack-neutral; CI workflow = Node illustration)
staleness_threshold: 30d
description: >
  Coding-mode rules for GitHub itself — branch+PR flow (never push to main), Actions security (pin
  third-party actions to a commit SHA, least-privilege `permissions:`, no secrets in YAML, no
  pull_request_target with untrusted code), gh CLI, Conventional Commits, branch naming, release on
  tag. Loaded on repo/CI/PR/release work. The CI workflow steps are stack-specific (setup-* +
  install/test/build) — see § Stack assumptions; the security rules are stack-neutral.
---

# GitHub Implementation Rules

## Stack assumptions

Everything here is **stack-neutral GitHub-platform knowledge** *except the CI/Release workflow
**steps***. The Actions security invariants (pin to SHA, least-privilege `permissions:`, no secrets
in YAML) apply to any stack. In the workflow examples below, swap the **language setup + the
install/lint/test/build commands** for the bound stack — they should come from the bound stack
skill's **Verification Recipe**:

- **Node (illustrated):** `actions/setup-node` + `npm ci` / `npm run lint` / `npm test` / `npm run build`.
- **Python:** `actions/setup-python` + `uv sync` / `ruff check` / `mypy` / `pytest`.
- **Swift/Apple:** a `macos-latest` runner + `xcodebuild` / `swift test`.

## NEVER do

- Push directly to main/master — always use a branch + PR
- Store secrets in `containerEnv`, `docker-compose.yml`, or workflow YAML as literals
- Use `pull_request_target` trigger with untrusted code (RCE risk via `${{ github.event }}` injection)
- Give workflows `write-all` permissions — declare only what each job needs
- Merge a PR with failing status checks unless explicitly overriding with documented reason
- Use `actions/checkout@v2` or older — always use `@v4`

## ALWAYS do

- Pin third-party GitHub Actions to a full commit SHA, not a tag (`uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683`)
- Use `actions/cache@v5` or `setup-*` built-in cache for dependency caching
- Set `permissions:` explicitly at workflow level (`contents: read`) and elevate per-job
- Reference issues in every PR body: `Closes #NNN`
- Update `CHANGELOG.md` in the same PR as the feature/fix

## GitHub Actions: Standard CI (Node illustration — swap steps per § Stack assumptions)

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'npm'
      - run: npm ci
      - run: npm run lint
      - run: npm test
      - run: npm run build
```

## GitHub Actions: Release on tag push

```yaml
name: Release
on:
  push:
    tags: ['v*.*.*']

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - run: npm ci && npm run build
      - run: gh release create "${{ github.ref_name }}" --generate-notes
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## GitHub Actions: Secrets

```yaml
# In workflow steps — never hardcode values
env:
  DATABASE_URL: ${{ secrets.DATABASE_URL }}
  API_KEY: ${{ secrets.API_KEY }}

# Create secrets via CLI
# gh secret set DATABASE_URL
# gh secret set API_KEY --body "value"
```

## gh CLI: Daily commands

```bash
# Issues
gh issue list --assignee "@me"
gh issue create --template bug_report.yml
gh issue edit 123 --add-label "priority: high" --remove-label "status: triage"
gh issue close 123 --comment "Fixed in #456"

# Pull requests
gh pr create --fill --draft
gh pr merge 123 --squash --delete-branch
gh pr merge 123 --auto --squash     # merge when checks pass

# Releases
gh release create v1.2.0 --generate-notes
gh release create v1.2.0-beta.1 --prerelease

# Workflow runs
gh run list
gh run view 12345678 --log
gh run rerun 12345678 --failed-only

# Secrets
gh secret list
gh secret set MY_SECRET
gh secret delete OLD_SECRET
```

## Branch naming pattern

```
feat/123-add-oauth-login
fix/456-null-pointer-in-export
chore/update-dependencies
docs/update-api-reference
```

## Commit message convention (Conventional Commits)

```
feat(auth): add Google OAuth2 login
fix(api): handle null response from payment gateway
chore(deps): upgrade Prisma to 5.14.0
docs(readme): add Docker setup instructions

# BREAKING CHANGE in body or footer:
feat(api)!: remove deprecated v1 endpoints

BREAKING CHANGE: /api/v1/* routes removed. Use /api/v2/*.
```

## Verification checklist

- [ ] Branch protection rules enabled on main (required: CI pass, 1 approval, no direct push)
- [ ] Dependabot alerts enabled
- [ ] Secret scanning + push protection enabled
- [ ] `GITHUB_TOKEN` permissions declared explicitly in all workflows
- [ ] No secrets in env vars or workflow YAML — all in GitHub Secrets
- [ ] CODEOWNERS file present for auto-review assignment
- [ ] PR template includes issue reference (`Closes #NNN`)
- [ ] CHANGELOG.md updated with this change
