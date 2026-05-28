---
skill: apex-devcontainer
backend: claude
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Dev Container Spec — containers.dev
  - devcontainers/spec — github.com/devcontainers/spec
  - devcontainers/features — github.com/devcontainers/features
  - Docker Best Practices — docs.docker.com
staleness_threshold: 30d
---

# Dev Container Specialist — Planning Mode

## When to activate
Setting up an isolated development environment, containerising Claude Code or other AI assistants,
designing reproducible developer environments, isolating project dependencies from the host machine,
or running Claude with full skill access inside a secure container boundary.

## Questions to ask before designing

- What is the primary threat model? Accidental host writes, credential leakage, or dependency isolation?
- Does the container need to build/run Docker images? (determines DinD vs DooD)
- Should the AI assistant's session state (history, cache) persist to the host, or stay in the container?
- Is this for a single developer (personal) or shared/CI use?
- Are there OS-level dependencies (USB devices, Bluetooth, GPU) that must cross the boundary?
- Windows host? (changes mount strategy — keep source in WSL2, not C:\)

## Architecture decision: what crosses the container boundary

| Resource | Recommended | Rationale |
|----------|-------------|-----------|
| Project source code | Bind-mount read-write | Dev workflow requires live edits |
| `~/.claude` skills/config | Copy-on-start (see below) | Skills read-only; runtime writes need writable path |
| `~/.ssh` keys | Bind-mount read-only | Git/SSH needs keys; container must not modify them |
| `~/.gitconfig` | Bind-mount read-only | Git identity inside container |
| Host Docker socket | DooD only if building images | Sharing docker.sock = root-equivalent on host |
| `node_modules`, `.venv` | Named Docker volume | Never bind-mount package dirs on Windows — 9P performance |
| API secrets | `secrets:` property | Tool prompts user; value never in config file |

## The `~/.claude` mount challenge

Claude Code writes session state, history, and cache to `~/.claude` at runtime.
A pure read-only mount will crash. The recommended pattern:

**Copy-on-start** (recommended for personal dev containers):
```
Mount ~/.claude as ~/.claude-host (read-only)
postCreateCommand: cp -r ~/.claude-host ~/.claude
~/.claude is now writable inside the container
Session state stays in the container (or named volume for persistence)
```

**Full read-write bind** (simpler, writes go back to host):
```
Mount ~/.claude read-write
AI writes go back to host
Fine for personal dev; not for shared/CI containers
```

## Choosing the base image

| Need | Image |
|------|-------|
| General purpose, add tools via Features | `mcr.microsoft.com/devcontainers/base:ubuntu` |
| Node.js project | `mcr.microsoft.com/devcontainers/javascript-node:22` |
| Python project | `mcr.microsoft.com/devcontainers/python:3.12` |
| Multi-language / Codespaces | `mcr.microsoft.com/devcontainers/universal:2` |
| Custom OS deps | `mcr.microsoft.com/devcontainers/base:ubuntu` + Dockerfile |

All MCR base images include a pre-created non-root `vscode` user. Always use it — never run as root.

## Features — standard addons

Features are OCI-distributed install scripts. Prefer Features over RUN commands in Dockerfiles for additive tooling:

```jsonc
"features": {
  "ghcr.io/devcontainers/features/common-utils:2": {},
  "ghcr.io/devcontainers/features/node:2": { "version": "22" },
  "ghcr.io/devcontainers/features/github-cli:1": {},
  "ghcr.io/devcontainers/features/docker-in-docker:3": {}  // only if need full isolation
}
```

## Docker-in-Docker vs Docker-outside-of-Docker

| Approach | When | Trade-off |
|----------|------|-----------|
| DinD (`docker-in-docker:3`) | Container must build/run containers in full isolation | Requires `privileged: true` or cgroup v2; fully isolated from host Docker |
| DooD (`docker-outside-of-docker:1`) | Container builds images but host Docker OK | Mounts `/var/run/docker.sock` — container has root-equivalent on host Docker |
| Neither | Container doesn't need to build images | Most secure; default for AI coding containers |

**Default recommendation:** No Docker socket in AI coding containers unless you're building images as part of the project.

## Lifecycle hooks — when to use each

```
initializeCommand  → HOST, every start. Pre-flight checks only.
onCreateCommand    → Container, first creation. Install heavy deps. Cacheable.
postCreateCommand  → Container, once. User-specific setup (copy ~/.claude, seed DB).
postStartCommand   → Container, every start. Start dev servers, background services.
postAttachCommand  → Container, each tool attach. Set terminal prompt, print hints.
```

Run expensive operations in parallel using object syntax:
```jsonc
"postCreateCommand": {
  "install-deps": "npm install",
  "copy-ai-config": "cp -r ~/.claude-host ~/.claude || true"
}
```

## Windows-specific: WSL2 performance

On Windows, source code **must** live inside the WSL2 filesystem (`~/projects/`), not on `C:\`.
Mounting from `C:\Users\...` crosses the 9P filesystem boundary → `npm install` is 3-5x slower.

**Workflow:**
1. Clone project into WSL2: `~/projects/myapp`
2. Open VS Code from WSL2: `code .`
3. "Reopen in Container" → container gets a fast Linux bind-mount

## Security checklist

- [ ] `remoteUser: vscode` — never root inside container
- [ ] `updateRemoteUserUID: true` — sync UID to host on Linux (prevents permission issues)
- [ ] `privileged: false` — only set true if DinD with cgroup v2 required
- [ ] Secrets in `secrets:` property — never in `containerEnv`
- [ ] `~/.ssh` mounted read-only — container cannot modify host SSH keys
- [ ] `~/.claude` read-write strategy documented and deliberate
- [ ] No host Docker socket unless explicitly needed
- [ ] Named volumes for package directories (not bind-mounted from Windows)

## Review checklist

- [ ] Base image pinned to a specific tag (not `latest` for production)
- [ ] Non-root user configured with `remoteUser`
- [ ] `.devcontainer/` directory at repo root (not hidden in subfolder)
- [ ] `secrets:` property used for all API keys
- [ ] Port forwarding declared in `forwardPorts`
- [ ] `ANTHROPIC_BASE_URL` passed via `remoteEnv` if backend-switching is needed
- [ ] Windows performance pitfall documented if project is Windows-hosted

## Standards

Dev Container Spec: containers.dev
Dev Container Features: github.com/devcontainers/features
Microsoft Container Registry: mcr.microsoft.com
Docker Security: docs.docker.com/engine/security
