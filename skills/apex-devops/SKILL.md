---
skill: apex-devops
backend: claude
version: 1.2.0
last_updated: 2026-06-01
sources:
  - Docker Best Practices — docs.docker.com/develop/dev-best-practices
  - GitHub Actions Docs + security hardening — docs.github.com/en/actions
  - SLSA supply-chain framework — slsa.dev
  - Claude Code Action — github.com/anthropics/claude-code-action
  - Vercel Agent Skills — github.com/vercel-labs/agent-skills
staleness_threshold: 14d
description: >
  Use when setting up CI/CD, containerisation, or deployment — pipelines, Dockerfiles,
  GitHub Actions, environments/secrets, rollback, deploy gates, supply-chain hardening.
  Triggers: "set up CI", "Dockerfile", "GitHub Actions workflow", "deploy this", "rollback
  strategy", "pin/secure the pipeline". Docker/CI examples are Node-default; per-stack swaps
  (Python etc.) via § Stack assumptions; CI build/test steps come from the bound stack's
  Verification Recipe. IaC depth → apex-iac. Not the coding-mode enforcement (that's impl.md).
---

# DevOps Specialist — Planning Mode

## When to activate
CI/CD pipelines, Docker configuration, deployment strategy, environment management,
infrastructure changes, GitHub Actions workflows.

## Stack assumptions

The Docker + CI examples are **Node-default**. Per stack: **Python** → `python:3.x-slim` base,
`uv sync` / `pip install`, `.venv` not `node_modules`; the CI **build/test/lint steps come from
the bound stack's `## Verification Recipe`**, not hardcoded `npm` commands. Container hygiene
(multi-stage, non-root, pinned base, healthcheck, no secrets baked in) and the supply-chain
rules below are **stack-neutral**. Deep IaC (Terraform/OpenTofu/Pulumi) → **apex-iac**.

## Supply-chain hardening (current baseline)

- **Pin GitHub Actions to a commit SHA**, not a mutable tag (`@v4` → `@<sha>  # v4.x`) — a
  retagged action is a supply-chain attack vector (OWASP A03:2025).
- **Use OIDC for cloud auth** (GitHub → AWS/GCP/Azure) — short-lived federated tokens, **no
  long-lived cloud keys in CI secrets**.
- Set least-privilege `permissions:` on each workflow; never `pull_request_target` with untrusted code.
- Commit a lockfile; run a dependency audit in CI; consider SLSA provenance/attestations for releases.

## Questions to ask before designing

- What environments exist? (dev, staging, production)
- How are secrets managed across environments?
- What is the rollback strategy if a deployment fails?
- What triggers a deployment? (merge to main, tag, manual)
- Are there database migrations to coordinate with deployments?

## CI/CD pipeline design

Recommended pipeline order:
1. Lint + type check (fast — fail early)
2. Unit tests
3. Build (Docker image or static assets)
4. Integration tests
5. Deploy to staging
6. Smoke test staging
7. Deploy to production (manual gate for production)

## Infrastructure as Code

When specs involve IaC (Terraform/OpenTofu/Pulumi), **defer to apex-iac** for the depth —
module structure, remote state + locking, plan-before-apply, secrets, and resource tagging.
At the devops level just ensure the pipeline runs `plan` on PR and gates `apply` behind review.

## Claude Code Action (GitHub CI)

For automated PR review and CI integration:
- `anthropics/claude-code-action` responds to `@claude` mentions in PRs
- Supports AWS Bedrock, Google Vertex AI, Microsoft Foundry (not just Anthropic API)
- Progressive disclosure: use interactive mode for trusted PRs, automation mode for scheduled tasks
- Run `claude /install-github-app` for guided setup

## Vercel deployment

Auto-deploys from git push. `vercel-labs/agent-skills` provides `vercel-deploy-claimable` skill:
- Detects 40+ frameworks from `package.json` automatically
- Returns preview URL + claim URL for ownership transfer
- Audit deployed routes for cost, performance, and caching issues via `vercel-optimize` skill

## Review checklist

- [ ] Secrets in environment variables — not hardcoded, not in Docker image
- [ ] .env files in .gitignore — never committed
- [ ] Non-root user in Dockerfile
- [ ] Multi-stage Docker build — dev dependencies not in production image
- [ ] Health check endpoint defined for containerised services
- [ ] Database migrations run before app starts (not in same container)
- [ ] Rollback strategy documented (git revert + redeploy, or blue-green)
- [ ] GitHub Actions pinned to commit SHA; least-privilege `permissions:` set
- [ ] Cloud auth via OIDC (no long-lived keys in CI secrets) where supported
- [ ] IaC in scope → see apex-iac (remote state, tagging, plan-before-apply)
