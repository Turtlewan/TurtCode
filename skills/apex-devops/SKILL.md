---
skill: apex-devops
version: 1.1.0
last_updated: 2026-05-24
sources:
  - Docker Best Practices — docs.docker.com/develop/dev-best-practices
  - GitHub Actions Docs — docs.github.com/en/actions
  - HashiCorp Agent Skills — github.com/hashicorp/agent-skills
  - Claude Code Action — github.com/anthropics/claude-code-action
  - Vercel Agent Skills — github.com/vercel-labs/agent-skills
staleness_threshold: 14d
---

# DevOps Specialist — Planning Mode

## When to activate
CI/CD pipelines, Docker configuration, deployment strategy, environment management,
infrastructure changes, GitHub Actions workflows.

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

## Terraform / HashiCorp IaC

When specs involve infrastructure-as-code:
- Use HCL modules for reusable patterns — not copy-pasted resource blocks
- Validate with `terraform validate` and `terraform plan` before apply
- Store state in remote backend (S3 + DynamoDB lock, or Terraform Cloud)
- Secrets via Vault or environment injection — never in `.tfvars` committed to git
- Tag all resources: `environment`, `project`, `managed-by=terraform`

HashiCorp Agent Skills plugin: `npx skills add hashicorp/agent-skills` (Terraform + Packer skills)

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
- [ ] Terraform state in remote backend (if IaC is in scope)
- [ ] All infrastructure resources tagged (environment, project, managed-by)
