# APEX Domain Registry

Maps domain names to skills, impl files, and activation keywords.

**Scope: domain specialists only — deliberately.** Workflow/spine skills (apex-orchestrate,
apex-plan, apex-code, apex-init, apex-governance, apex-handoff, apex-debug, apex-refresh,
apex-deep-dive) are routed by apex-orchestrate's signal table, not keywords, and have no row
here. Their index home is `~/apex/SKILLS.md`. Do not "fix" their absence by adding rows.

**Agent column** = the planning-side reviewer dispatched for this domain. Every domain uses the one
generic **`apex-spec-reviewer`** (Agent tool, pointed at this row's SKILL.md); the prior per-domain
`apex-*-agent` stubs are retired (ADR-007). A `—` means no default reviewer is wired, but one can be
dispatched on judgment. Coding-side *enforcement* needs no agent — `apex-coder` wave-workers load the
domain `impl.md` inline. Two domains keep a dedicated coding-side agent for their own tooling:
**security** (`apex-security-agent`, Bash verification) and **figma** (`apex-figma-agent`, MCP/image
steps). The post-build doc pipeline agents (`apex-docs-product-agent`, `apex-docs-technical-agent`)
are spawned by `apex-code`, not from this table.

| Domain | SKILL.md | impl.md | Agent | Keywords |
|--------|----------|---------|-------|---------|
| security | apex-security/SKILL.md | apex-security/impl.md | apex-spec-reviewer · apex-security-agent | auth, crypto, secret, password, token, permissions, SQL, injection, XSS, CORS, API key, vulnerability, OWASP, supply chain, dependency audit, security headers |
| frontend | apex-frontend/SKILL.md | apex-frontend/impl.md | apex-spec-reviewer | React, React 19, Actions, React Compiler, component, UI, CSS, browser, client-side, bundle, tailwind, shadcn |
| backend | apex-backend/SKILL.md | apex-backend/impl.md | apex-spec-reviewer | API, server, endpoint, database, cache, queue, service, handler, REST, GraphQL, FastAPI, pydantic, Fastify |
| architecture | apex-architecture/SKILL.md | — | apex-spec-reviewer | system design, scalability, microservices, monolith, event-driven, domain model, ADR, bounded context |
| devops | apex-devops/SKILL.md | apex-devops/impl.md | apex-spec-reviewer | Docker, CI/CD, deploy, pipeline, container, GitHub Actions, supply-chain, OIDC, SHA pin, rollback |
| testing | apex-testing/SKILL.md | apex-testing/impl.md | apex-spec-reviewer | TDD, test pyramid, e2e, unit, integration, coverage, mock, vitest, Playwright, axe-core, Storybook |
| performance | apex-performance/SKILL.md | apex-performance/impl.md | apex-spec-reviewer | slow, latency, throughput, N+1, memory, bundle size, cache, profiling, lighthouse |
| observability | apex-observability/SKILL.md | apex-observability/impl.md | apex-spec-reviewer | logging, tracing, metrics, alert, monitor, Prometheus, OpenTelemetry, OTel GenAI, Sentry, structlog |
| accessibility | apex-accessibility/SKILL.md | apex-accessibility/impl.md | apex-spec-reviewer | a11y, WCAG 2.2, EAA, ARIA, screen reader, keyboard nav, colour contrast, focus management, target size |
| ai-systems | apex-ai-systems/SKILL.md | apex-ai-systems/impl.md | apex-spec-reviewer | LLM, RAG generation, prompt, structured output, agent, tool calling, MCP, eval, LLM-as-judge, streaming, model selection |
| data | apex-data/SKILL.md | apex-data/impl.md | apex-spec-reviewer | migration, schema, pipeline, ETL, warehouse, query optimisation, Prisma, Alembic, SQLAlchemy, SQLModel, SwiftData, PostgreSQL |
| docs-technical | apex-docs-technical/SKILL.md | — | apex-spec-reviewer | ADR, runbook, architecture doc, decision record, setup guide |
| docs-product | apex-docs-product/SKILL.md | apex-docs-product/impl.md | apex-spec-reviewer | changelog, README, user guide, API reference, release notes, tutorial |
| ui-ux-design | apex-ui-ux-design/SKILL.md | apex-ui-ux-design/impl.md | apex-spec-reviewer | UX, user flow, wireframe, onboarding, visual hierarchy, interaction design, conversational UI, Liquid Glass, calm UI |
| design-system | apex-design-system/SKILL.md | apex-design-system/impl.md | apex-spec-reviewer | component library, design tokens, shadcn, Radix, Base UI, Tailwind v4, Storybook, registry, theming |
| animation | apex-animation/SKILL.md | apex-animation/impl.md | apex-spec-reviewer | animation, motion, transition, scroll effect, GSAP, Motion, spring, gesture, SwiftUI animation, reduced motion |
| figma | apex-figma/SKILL.md | apex-figma/impl.md | apex-spec-reviewer · apex-figma-agent | Figma, design file, design-to-code, design token, MCP, Dev Mode, Code Connect, Figma Make, Framelink |
| ui-testing | apex-ui-testing/SKILL.md | apex-ui-testing/impl.md | apex-spec-reviewer | visual regression, Chromatic, Storybook testing, Vitest addon, Playwright, Playwright MCP, component testing, axe-core, axe, snapshot |
| github | apex-github/SKILL.md | apex-github/impl.md | — | GitHub, repo setup, branch protection, issue labels, PR workflow, Conventional Commits, semver, Dependabot, CodeQL, CODEOWNERS, release, changelog |
| system-design | apex-system-design/SKILL.md | apex-system-design/impl.md | — | distributed systems, CAP theorem, consistency, caching, message queue, rate limiting, circuit breaker, idempotency, Kafka, SQS, Redis, pub/sub, scalability |
| devcontainer | apex-devcontainer/SKILL.md | apex-devcontainer/impl.md | — | dev container, devcontainer, devcontainer.json, isolated environment, postCreateCommand, Features, DinD, container tooling |
| aws | apex-aws/SKILL.md | apex-aws/impl.md | — | AWS, Lambda, ECS, Fargate, EC2, S3, DynamoDB, RDS, IAM, CDK, CloudFormation, SQS, SNS, CloudFront, EKS, ECR, Secrets Manager, Control Tower |
| homelab | apex-homelab/SKILL.md | apex-homelab/impl.md | — | Home Assistant, ESPHome, smart home, IoT, ESP32, Zigbee, Z-Wave, Matter, Thread, MQTT, automation, smart device, presence detection, mmWave, Wyoming, Node-RED, homelab, self-hosting, Proxmox, Docker Compose, reverse proxy, Traefik, Caddy, Tailscale, backup |
| k8s | apex-k8s/SKILL.md | apex-k8s/impl.md | — | Kubernetes, K8s, kubectl, Helm, ArgoCD, Flux, GitOps, pod, deployment, ingress, Gateway API, namespace, RBAC, HPA, VPA, Karpenter, StatefulSet |
| iac | apex-iac/SKILL.md | apex-iac/impl.md | — | OpenTofu, Terraform, Pulumi, Ansible, infrastructure as code, remote state, state encryption, drift detection, Infracost, provisioning |
| mobile | apex-mobile/SKILL.md | apex-mobile/impl.md | — | React Native, Expo, Flutter, Kotlin Multiplatform, KMP, iOS, Android, mobile app, EAS, OTA, push notifications, app store, native vs cross-platform |
| research | apex-research/SKILL.md | — | — | research, compare options, best practices, look up, investigate, explore options, technology comparison, deep dive |
| skill-author | apex-skill-author/SKILL.md | — | — | skill authoring, create skill, new skill, SKILL.md, write skill, update skill, skill writing, authoring, skill quality, register skill, impl.md |
| context-budget | apex-context-budget/SKILL.md | — | — | context budget, token overhead, token budget, context window, how much context, context rot, leanness, headroom, too many skills, MCP overhead, what loads, prune skills, context audit |
| coding-principles | apex-coding-principles/SKILL.md | apex-coding-principles/impl.md | — | coding standards, naming conventions, clear naming, error handling, input validation, DRY, clean code, code quality, consistent formatting, git discipline, single responsibility, security basics, maintainability, coding principles |
| google | apex-google/SKILL.md | apex-google/impl.md | — | Google, OAuth2, Sign in with Google, GIS, googleapis, google-auth-library, google-api-python-client, Gmail API, Calendar API, Drive API, Workspace, service account, Google SSO, OIDC Google |
| stack | apex-stack/SKILL.md | apex-stack/impl.md | — | tech stack, framework selection, database choice, ORM, which framework, which language, project start, new project, stack decision, Python vs Go, Next.js vs, FastAPI, Django, Rails, Go vs Rust, Prisma vs Drizzle, Clerk vs Auth.js, what stack, stack_skills, coverage gate |
| auth | apex-auth/SKILL.md | apex-auth/impl.md | — | authentication, auth, login, signup, logout, password, session, JWT, OAuth2, RBAC, roles, permissions, multi-tenant, passkeys, WebAuthn, MFA, magic link, invite |
| jobs | apex-jobs/SKILL.md | apex-jobs/impl.md | — | background job, job queue, worker, BullMQ, Bull, Redis queue, arq, Celery, APScheduler, cron job, scheduled task, async task, task queue, retry, dead letter queue, queue worker |
| realtime | apex-realtime/SKILL.md | apex-realtime/impl.md | — | real-time, WebSocket, Socket.io, SSE, Server-Sent Events, sse-starlette, live updates, push, streaming, presence, live dashboard, finance ticker, AI streaming, LLM token streaming, WebRTC, voice agent, live voice, STT, TTS, barge-in, turn-taking, LiveKit, Pipecat, OpenAI Realtime API, realtime audio |
| storage | apex-storage/SKILL.md | apex-storage/impl.md | — | file upload, file storage, S3, MinIO, R2, object storage, local filesystem storage, presigned URL, signed URL, multipart upload, file download, attachment, image upload |
| search | apex-search/SKILL.md | apex-search/impl.md | — | search, full-text search, vector search, semantic search, RAG, retrieval, embeddings, pgvector, sqlite-vec, similarity search, chunking, hybrid search, Typesense, Algolia |
| nextjs | apex-nextjs/SKILL.md | apex-nextjs/impl.md | — | Next.js, Next, App Router, Server Components, Server Actions, React 19, RSC, caching, revalidation, SSR, ISR, Static Generation |
| python | apex-python/SKILL.md | apex-python/impl.md | — | Python, FastAPI, uv, ruff, mypy, pydantic, pydantic-settings, async, asyncio, uvicorn, ASGI, pytest, typed Python, type hints |
| swift | apex-swift/SKILL.md | apex-swift/impl.md | — | Swift, SwiftUI, Xcode, xcodebuild, Swift 6, strict concurrency, @Observable, SwiftData, NavigationStack, actor, Sendable, MainActor, macOS app, iPadOS, native iOS, SPM, Swift Package |
