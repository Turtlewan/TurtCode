---
skill: apex-devcontainer
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Dev Container Spec — containers.dev
  - Docker Docs — docs.docker.com
staleness_threshold: 30d
---

# Dev Container Implementation Rules

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
- Add `node-modules-${devcontainerId}` named volume for Node.js projects
- Use the `secrets:` spec property for all API keys and tokens
- Mount `~/.ssh` read-only for git access
- Pass `ANTHROPIC_BASE_URL` via `remoteEnv` so backend-switching works inside container

## Complete AI-assisted devcontainer.json

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
