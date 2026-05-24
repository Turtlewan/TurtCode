---
skill: apex-devops
version: 1.0.0
last_updated: 2026-05-24
sources:
  - Docker Best Practices — docs.docker.com/develop/dev-best-practices
  - GitHub Actions Docs — docs.github.com/en/actions
staleness_threshold: 14d
---

# DevOps Implementation Rules

## NEVER do

- Hardcode environment variables in Dockerfiles or CI YAML
- Run as root in Docker containers
- Copy .env files into Docker images
- Use latest tag for base images in production — pin exact versions
- Run migrations and app startup in the same container entrypoint

## ALWAYS do

- Use multi-stage Dockerfile (builder stage + production stage)
- Add non-root user in Dockerfile
- Pin base image versions (node:20.11-alpine, not node:latest)
- Add .dockerignore (exclude node_modules, .env, .git)
- Add HEALTHCHECK to Dockerfile for services
- Use GitHub Actions secrets for all CI credentials

## Dockerfile pattern (Node.js)

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
  push:
    branches: [main]
  pull_request:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - run: npm run lint
      - run: npm test
```

## Verification checklist

- [ ] docker build completes without errors
- [ ] docker run starts and health check passes
- [ ] No secrets visible in: docker inspect, docker history, git log
- [ ] .env is in .gitignore
