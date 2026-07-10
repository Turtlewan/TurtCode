---
skill: apex-devcontainer
backend: coding
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Dev Container Spec — containers.dev
  - Docker Docs — docs.docker.com
  - SP5 de-coupling (stack-neutral core; Node devcontainer illustration)
staleness_threshold: 30d
description: >
  Coding-mode rules for dev containers — stack-neutral invariants (non-root remoteUser, secrets via
  the `secrets:` property not ENV, named volume for the dependency dir, updateRemoteUserUID, SSH
  read-only, pass ANTHROPIC_BASE_URL via remoteEnv for backend-switching). Loaded on .devcontainer
  work. The language Feature + dependency volume + install command are stack-specific (Node feature /
  node_modules / npm ci → Python feature / uv cache / uv sync); see § Stack assumptions.
---

# Dev Container Implementation Rules

## Stack assumptions

The container-hygiene invariants here are **stack-neutral** (non-root user, `secrets:` not ENV,
named volume for the dependency dir, `updateRemoteUserUID`, read-only SSH). The example below is a
**Node devcontainer**; on the bound stack swap three things:

- **Language Feature:** `features/node` → **Python:** `features/python` (+ install uv); **Go:** `features/go`. (Swift/Apple apps generally build on macOS/Xcode, not a Linux devcontainer.)
- **Dependency volume:** `node-modules-${devcontainerId}` on `/workspace/node_modules` → **Python:** a named volume for `.venv` or the uv cache.
- **Install command:** `postCreateCommand` `npm ci` → `uv sync` / `pip install -e .` / `go mod download`.

The `~/.claude` mount + `ANTHROPIC_BASE_URL` remoteEnv (APEX backend-switching) are stack-neutral — keep.

## NEVER do

- Run the container as root — always set `remoteUser: vscode`
- Put secrets in `containerEnv` or as Docker `ENV`/`ARG` — use `secrets:` property
- Bind-mount `node_modules` or `.venv` from a Windows host — use named volumes
- Mount `~/.claude` as read-only without a copy-on-start workaround
- Set `privileged: true` unless DinD is truly required and cgroup v2 is confirmed
- Use `docker-compose` V1 — use `docker compose` (V2, built into Docker CLI)

## ALWAYS do

- Use an official MCR base image or Dockerfile that creates a non-root user
- Set `updateRemoteUserUID: true` on Linux (prevents bind-mount UID mismatch)
- Add a named volume for the dependency dir (`node-modules-${devcontainerId}` for Node; `.venv` / uv-cache volume for Python) — never bind-mount it from the host
- Use the `secrets:` spec property for all API keys and tokens
- Mount `~/.ssh` read-only for git access
- Pass `ANTHROPIC_BASE_URL` via `remoteEnv` so backend-switching works inside container

## Complete AI-assisted devcontainer.json (Node illustration — swap the 3 items in § Stack assumptions)

```jsonc
// .devcontainer/devcontainer.json
{
  "name": "AI-Assisted Project",
  "build": { "dockerfile": "Dockerfile" },

  "features": {
    "ghcr.io/devcontainers/features/common-utils:2": {},
    "ghcr.io/devcontainers/features/node:2": { "version": "22" },
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },

  "remoteUser": "vscode",
  "containerUser": "vscode",
  "updateRemoteUserUID": true,

  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "workspaceFolder": "/workspace",

  "mounts": [
    // AI config: mount read-only as .claude-host; postCreateCommand copies to writable .claude
    {
      "source": "${localEnv:HOME}${localEnv:USERPROFILE}/.claude",
      "target": "/home/vscode/.claude-host",
      "type": "bind",
      "readonly": true
    },
    // SSH keys: read-only
    {
      "source": "${localEnv:HOME}${localEnv:USERPROFILE}/.ssh",
      "target": "/home/vscode/.ssh",
      "type": "bind",
      "readonly": true
    },
    // Named volume for node_modules (avoids Windows 9P performance issue)
    {
      "source": "node-modules-${devcontainerId}",
      "target": "/workspace/node_modules",
      "type": "volume"
    }
  ],

  "forwardPorts": [3000],
  "portsAttributes": {
    "3000": { "label": "App", "onAutoForward": "openPreview" }
  },

  "containerEnv": {
    "NODE_ENV": "development"
  },

  "remoteEnv": {
    "ANTHROPIC_BASE_URL": "${localEnv:ANTHROPIC_BASE_URL}"
  },

  "secrets": {
    "ANTHROPIC_API_KEY": { "description": "Anthropic API key for Claude Code." },
    "OPENAI_API_KEY":   { "description": "OpenAI API key (if used)." }
  },

  "postCreateCommand": {
    "copy-ai-config": "cp -r /home/vscode/.claude-host /home/vscode/.claude 2>/dev/null || true",
    "install-deps":   "npm ci"
  },
  "waitFor": "postCreateCommand",

  "customizations": {
    "vscode": {
      "extensions": ["dbaeumer.vscode-eslint", "esbenp.prettier-vscode"],
      "settings": { "editor.formatOnSave": true }
    }
  },

  "privileged": false,
  "capAdd": ["SYS_PTRACE"],
  "securityOpt": ["seccomp=unconfined"]
}
```

## Minimal Dockerfile

```dockerfile
# .devcontainer/Dockerfile
FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Project-specific OS deps only — tools go in Features
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# vscode user already created by base image — don't recreate
```

## Docker Compose multi-service

```yaml
# .devcontainer/docker-compose.dev.yml
services:
  app:
    build: { context: .., dockerfile: .devcontainer/Dockerfile }
    volumes:
      - ../..:/workspace:cached
      - node-modules-dev:/workspace/node_modules
    command: sleep infinity
    environment:
      DATABASE_URL: postgresql://postgres:password@db:5432/mydb
    depends_on: [db]
  db:
    image: postgres:16
    volumes: [postgres-data:/var/lib/postgresql/data]
    environment:
      POSTGRES_PASSWORD: password
volumes:
  postgres-data:
  node-modules-dev:
```

```jsonc
// devcontainer.json additions for Compose
{
  "dockerComposeFile": ["../docker-compose.yml", "docker-compose.dev.yml"],
  "service": "app",
  "workspaceFolder": "/workspace",
  "runServices": ["app", "db"],
  "shutdownAction": "stopCompose"
}
```

## CLI commands

```bash
# Build and start
devcontainer up --workspace-folder .

# Execute command inside
devcontainer exec --workspace-folder . npm test

# Build image (for CI caching)
devcontainer build \
  --workspace-folder . \
  --image-name "ghcr.io/myorg/dev:cache" \
  --cache-from "ghcr.io/myorg/dev:cache" \
  --push
```

## Verification checklist

- [ ] `docker build` completes without errors
- [ ] Container starts as `vscode` user (verify: `whoami` inside terminal)
- [ ] `~/.claude` exists and is writable inside container
- [ ] Skills directory accessible: `ls ~/.claude/skills`
- [ ] SSH keys readable: `ssh-add -l` or `git fetch` succeeds
- [ ] Secrets available as env vars: `echo $ANTHROPIC_API_KEY` (not empty)
- [ ] `node_modules` lives in named volume (not bind-mounted from host)
- [ ] Port 3000 forwarded and accessible from host browser
