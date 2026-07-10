---
skill: apex-devops
backend: coding
version: 1.2.0
last_updated: 2026-06-10
sources:
  - Docker Best Practices — docs.docker.com/develop/dev-best-practices
  - GitHub Actions security hardening — docs.github.com/en/actions/security-guides
staleness_threshold: 14d
description: >
  Coding-mode enforcement for CI/CD + containers — multi-stage Dockerfile, non-root, pinned
  bases, no baked secrets, SHA-pinned Actions, OIDC. Examples Node-default; Python swaps via
  § Stack assumptions; CI steps from the bound stack recipe. Loads when writing Dockerfiles/CI.
---

# DevOps Implementation Rules

## Stack assumptions

Dockerfile + CI examples are **Node**. **Python** → `python:3.x-slim` base, `uv sync`/`pip
install`, copy `.venv` or install in builder; `.dockerignore` excludes `.venv`/`__pycache__`.
**CI lint/test/build steps come from the bound stack's `## Verification Recipe`** — never
default to `npm` for a non-JS stack. Container/supply-chain rules below are stack-neutral.

## NEVER do

- Hardcode environment variables in Dockerfiles or CI YAML
- Run as root in Docker containers
- Copy .env / secrets files into Docker images
- Use `latest` tag for base images in production — pin exact versions
- Run migrations and app startup in the same container entrypoint
- Reference GitHub Actions by mutable tag for security-sensitive workflows — pin to a commit SHA
- Put long-lived cloud keys in CI secrets when OIDC federation is available

## ALWAYS do

- Use multi-stage Dockerfile (builder stage + production stage)
- Add non-root user in Dockerfile
- Pin base image versions (e.g. `node:24-alpine` / `python:3.13-slim`, not `:latest`)
- Add .dockerignore (exclude deps dir, .env, .git)
- Add HEALTHCHECK to Dockerfile for services
- Pin Actions to commit SHA; set least-privilege `permissions:` per workflow
- Use OIDC for cloud auth; GitHub Actions secrets only for what OIDC can't cover

## Dockerfile pattern (Node.js — Python swaps base + install per § Stack assumptions)

```dockerfile
FROM node:20.11-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20.11-alpine AS production
WORKDIR /app
RUN addgroup -S app && adduser -S app -G app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY package*.json ./
USER app
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "dist/index.js"]
```

## GitHub Actions pattern

```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }
permissions:
  contents: read            # least privilege; widen only per-job as needed
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>     # pin to SHA, comment the version (# v4.x)
      - uses: actions/setup-node@<sha>   # pin to SHA
        with: { node-version: '24', cache: 'npm' }
      # build/test/lint = the bound stack's Verification Recipe (npm shown; Python: uv run ...)
      - run: npm ci
      - run: npm run lint
      - run: npm test
```

## Verification checklist

- [ ] docker build completes without errors — check: `docker build -t app-verify .` (exit 0)
- [ ] Container runs as non-root — check: `docker run --rm --entrypoint whoami app-verify` (output must NOT be `root`)
- [ ] Health check passes — check: `docker run -d --name app-verify app-verify`, then `docker inspect --format '{{.State.Health.Status}}' app-verify` (expect `healthy`); clean up with `docker rm -f app-verify`
- [ ] No secrets visible in: docker inspect, docker history, git log
- [ ] .env / secrets in .gitignore and .dockerignore
- [ ] No mutable-tag Actions — check: `grep -rnE 'uses:.*@v[0-9]' .github/workflows/` (any match = fail; pin to commit SHA + version comment)
- [ ] Base images digest-pinned or exact-version — check: `grep -nE 'FROM .*:(latest|[0-9]+)$' Dockerfile` (any match = fail; `:latest` and bare major tags like `:20` are mutable)
- [ ] Workflow `permissions:` least-privilege — check: `grep -rLn 'permissions:' .github/workflows/` (any file listed = fail)
- [ ] CI steps match the bound stack's Verification Recipe (not assumed npm)
