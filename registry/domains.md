# APEX Domain Registry

Maps domain names to skills, agents, and activation keywords.
Phase 3 fills in the skill/agent content. This file defines the routing table.

| Domain | SKILL.md | impl.md | Agent | Keywords |
|--------|----------|---------|-------|---------|
| security | apex-security/SKILL.md | apex-security/impl.md | apex-security-agent | auth, crypto, secret, password, token, permissions, SQL, injection, XSS, CORS, API key, vulnerability |
| frontend | apex-frontend/SKILL.md | apex-frontend/impl.md | apex-frontend-agent | React, Next, Vue, component, UI, CSS, browser, client-side, bundle, tailwind, shadcn |
| backend | apex-backend/SKILL.md | apex-backend/impl.md | apex-backend-agent | API, server, endpoint, database, cache, queue, service, handler, REST, GraphQL, FastAPI, pydantic, Fastify |
| architecture | apex-architecture/SKILL.md | — | apex-architecture-agent | system design, scalability, microservices, monolith, event-driven, domain model, ADR, bounded context |
| devops | apex-devops/SKILL.md | apex-devops/impl.md | apex-devops-agent | Docker, CI/CD, deploy, pipeline, Kubernetes, infra, environment, container, GitHub Actions |
| testing | apex-testing/SKILL.md | apex-testing/impl.md | apex-testing-agent | TDD, test pyramid, e2e, unit, integration, coverage, mock, vitest, Playwright, axe-core, Storybook |
| performance | apex-performance/SKILL.md | apex-performance/impl.md | apex-performance-agent | slow, latency, throughput, N+1, memory, bundle size, cache, profiling, lighthouse |
| observability | apex-observability/SKILL.md | apex-observability/impl.md | apex-observability-agent | logging, tracing, metrics, alert, monitor, Prometheus, OpenTelemetry, Sentry |
| accessibility | apex-accessibility/SKILL.md | apex-accessibility/impl.md | apex-accessibility-agent | a11y, WCAG, ARIA, screen reader, keyboard nav, colour contrast, focus management |
| ai-systems | apex-ai-systems/SKILL.md | apex-ai-systems/impl.md | apex-ai-systems-agent | LLM, embedding, RAG, vector, prompt, eval, model, agent, inference, fine-tuning |
| data | apex-data/SKILL.md | apex-data/impl.md | apex-data-agent | migration, schema, pipeline, ETL, warehouse, query optimisation, Prisma, Alembic, SQLAlchemy, SQLModel, SwiftData, PostgreSQL |
| docs-technical | apex-docs-technical/SKILL.md | — | apex-docs-technical-agent | ADR, runbook, architecture doc, decision record, setup guide |
| docs-product | apex-docs-product/SKILL.md | apex-docs-product/impl.md | apex-docs-product-agent | changelog, README, user guide, API reference, release notes, tutorial |
| ui-ux-design | apex-ui-ux-design/SKILL.md | apex-ui-ux-design/impl.md | apex-ui-ux-design-agent | UX, user flow, wireframe, design system, onboarding, visual hierarchy, interaction design |
| design-system | apex-design-system/SKILL.md | apex-design-system/impl.md | apex-design-system-agent | component library, design tokens, shadcn, Radix, Tailwind, Storybook, Chromatic, Tremor |
| animation | apex-animation/SKILL.md | apex-animation/impl.md | apex-animation-agent | animation, motion, transition, scroll effect, GSAP, Framer Motion, spring, gesture |
| figma | apex-figma/SKILL.md | apex-figma/impl.md | apex-figma-agent | Figma, design file, design-to-code, design token, MCP, Framelink |
| ui-testing | apex-ui-testing/SKILL.md | apex-ui-testing/impl.md | apex-ui-testing-agent | visual regression, Chromatic, Storybook testing, Playwright, axe, snapshot |
| github | apex-github/SKILL.md | apex-github/impl.md | — | GitHub, repo setup, branch protection, issue labels, PR workflow, Conventional Commits, semver, Dependabot, CodeQL, CODEOWNERS, release, changelog |
| system-design | apex-system-design/SKILL.md | apex-system-design/impl.md | — | distributed systems, CAP theorem, consistency, caching, message queue, rate limiting, circuit breaker, idempotency, Kafka, SQS, Redis, pub/sub, scalability |
| devcontainer | apex-devcontainer/SKILL.md | apex-devcontainer/impl.md | — | dev container, devcontainer, devcontainer.json, isolated environment, postCreateCommand, Features, DinD, container tooling |
| aws | apex-aws/SKILL.md | apex-aws/impl.md | — | AWS, Lambda, ECS, Fargate, EC2, S3, DynamoDB, RDS, IAM, CDK, CloudFormation, SQS, SNS, CloudFront, EKS, ECR, Secrets Manager, Control Tower |
| azure | apex-azure/SKILL.md | apex-azure/impl.md | — | Azure, AKS, App Service, Container Apps, Azure Functions, Bicep, Managed Identity, Key Vault, Entra ID, Cosmos DB, Service Bus |
| gcp | apex-gcp/SKILL.md | apex-gcp/impl.md | — | GCP, Google Cloud, Cloud Run, GKE, Cloud SQL, BigQuery, Pub/Sub, Cloud Functions, Artifact Registry, Workload Identity, Secret Manager |
| homelab | apex-homelab/SKILL.md | apex-homelab/impl.md | — | Home Assistant, ESPHome, smart home, IoT, ESP32, Zigbee, MQTT, automation, smart device, presence detection, mmWave, Node-RED |
| k8s | apex-k8s/SKILL.md | apex-k8s/impl.md | — | Kubernetes, K8s, kubectl, Helm, ArgoCD, Flux, GitOps, pod, deployment, ingress, namespace, RBAC, HPA, StatefulSet |
| iac | apex-iac/SKILL.md | apex-iac/impl.md | — | Terraform, Pulumi, Ansible, infrastructure as code, remote state, tfvars, drift detection, Infracost, provisioning |
| mobile | apex-mobile/SKILL.md | apex-mobile/impl.md | — | React Native, Expo, iOS, Android, mobile app, EAS Build, EAS Update, OTA update, push notifications, app store, TestFlight |
| research | apex-research/SKILL.md | — | — | research, compare options, best practices, look up, investigate, explore options, technology comparison, deep dive |
| skill-author | apex-skill-author/SKILL.md | — | — | skill authoring, create skill, new skill, SKILL.md, write skill, update skill, skill writing, authoring, skill quality, register skill, impl.md |
| google | apex-google/SKILL.md | apex-google/impl.md | — | Google, OAuth2, Sign in with Google, GIS, googleapis, google-auth-library, Gmail API, Calendar API, Drive API, Workspace, service account, Google SSO, OIDC Google |
| stack | apex-stack/SKILL.md | apex-stack/impl.md | — | tech stack, framework selection, database choice, ORM, which framework, which language, project start, new project, stack decision, Python vs Go, Next.js vs, FastAPI, Django, Rails, Go vs Rust, Prisma vs Drizzle, Clerk vs Auth.js, what stack, stack_skills, coverage gate |
| auth | apex-auth/SKILL.md | apex-auth/impl.md | — | authentication, auth, login, signup, logout, password, session, JWT, OAuth2, RBAC, roles, permissions, multi-tenant, passkeys, WebAuthn, MFA, magic link, invite |
| jobs | apex-jobs/SKILL.md | apex-jobs/impl.md | — | background job, job queue, worker, BullMQ, Bull, Redis queue, arq, Celery, APScheduler, cron job, scheduled task, async task, task queue, retry, dead letter queue, queue worker |
| realtime | apex-realtime/SKILL.md | apex-realtime/impl.md | — | real-time, WebSocket, Socket.io, SSE, Server-Sent Events, live updates, push, streaming, presence, live dashboard, finance ticker, AI streaming |
| storage | apex-storage/SKILL.md | apex-storage/impl.md | — | file upload, file storage, S3, MinIO, R2, object storage, local filesystem storage, presigned URL, signed URL, multipart upload, file download, attachment, image upload |
| search | apex-search/SKILL.md | apex-search/impl.md | — | search, full-text search, vector search, semantic search, RAG, retrieval, embeddings, pgvector, sqlite-vec, similarity search, chunking, hybrid search, Typesense, Algolia |
| nextjs | apex-nextjs/SKILL.md | apex-nextjs/impl.md | — | Next.js, Next, App Router, Server Components, Server Actions, React 19, RSC, caching, revalidation, SSR, ISR, Static Generation |
| python | apex-python/SKILL.md | apex-python/impl.md | — | Python, FastAPI, uv, ruff, mypy, pydantic, pydantic-settings, async, asyncio, uvicorn, ASGI, pytest, typed Python, type hints |
| swift | apex-swift/SKILL.md | apex-swift/impl.md | — | Swift, SwiftUI, Xcode, xcodebuild, Swift 6, strict concurrency, @Observable, SwiftData, NavigationStack, actor, Sendable, MainActor, macOS app, iPadOS, native iOS, SPM, Swift Package |
