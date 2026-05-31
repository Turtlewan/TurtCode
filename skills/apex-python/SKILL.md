---
skill: apex-python
backend: claude
version: 1.0.0
last_updated: 2026-05-31
sources:
  - docs/research/python-stack-best-practices.md
  - Context7 /fastapi/fastapi (fetched 2026-05-31)
staleness_threshold: 30d
description: >
  Use when building or designing a typed Python service — FastAPI APIs, project tooling (uv / ruff /
  mypy), async I/O boundaries, typed config. The language/stack layer for a Python backend or RAG
  engine. Not RAG/vector retrieval itself (apex-ai-systems / apex-search), auth mechanics
  (apex-auth), DB schema (apex-data), or whether to pick Python at all (apex-stack).
---

# apex-python — Typed Python / FastAPI (planning)

Stack skill (ADR-005) for **Python 3.12+** services: `uv` tooling, `mypy --strict`, FastAPI,
pydantic v2. The meat is in `impl.md`; this file is the planning "what to weigh."

## Boundary — what this skill is NOT

- **RAG / vector search / embeddings / LLM orchestration → `apex-ai-systems` / `apex-search`.** This
  skill is the Python *language/framework* layer they compose *onto*.
- **Auth mechanics (providers, sessions, JWT) → `apex-auth`.** Here: only *where* the check goes.
- **DB schema / migrations / ORM modelling → `apex-data`.** Here: only schema-vs-entity separation.
- **Whether to choose Python at all → `apex-stack`.** This skill assumes Python is chosen.

## Research findings (verified 2026-05-31 — see docs/research/python-stack-best-practices.md)

| Fact | Implication |
|------|-------------|
| Astral toolchain is the 2026 default: `uv` (env/deps) + `ruff` (lint+format) | One tool family, `pyproject.toml` single source of truth; no pip/poetry by reflex |
| Type checker: **`mypy --strict`** is the stable gate; Astral's `ty` is fast but still beta | Use `mypy --strict` now; re-evaluate `ty` at the 60-day mark |
| Verifiability is a *language* property — Python is dynamic | Buy it back with `mypy --strict` from day one; it is the load-bearing quality gate |
| FastAPI is async-first; sync routes run in a threadpool | Plan the async boundary explicitly — no blocking I/O inside `async def` |
| pydantic v2 + `pydantic-settings` for typed config | Misconfig caught at startup; schemas separate from ORM models |

## What to weigh (planning)

1. **Async vs sync per endpoint.** I/O-bound + async client → `async def`; sync/CPU work → plain
   `def` (threadpool). Decide per route — a blocking call in `async def` stalls the event loop.
2. **`mypy --strict` is non-negotiable** for an AI-built codebase — it's the self-correction signal
   the developer can't provide. Plan for typed signatures everywhere from the first commit.
3. **Typed config boundary** — what's env-driven (`pydantic-settings`), what's a secret (`SecretStr`
   + `hmac.compare_digest`).
4. **Schema ≠ entity** — request/response Pydantic models are not the persistence models.
5. **Composition** — for a RAG engine, this skill provides the FastAPI/uv/typing spine; the
   retrieval/vector layer is planned via `apex-ai-systems` / `apex-search` and unions its recipe.

## Hard blocks (planning)

- Never sign off a Python plan that uses `pip`/`poetry`/`venv` instead of `uv` for a new project.
- Never plan a Python service without `mypy --strict` as a gate.
- Never plan blocking I/O inside an `async def` route.
- Never duplicate RAG/vector guidance here — that's `apex-ai-systems` / `apex-search`.

## Review checklist

- [ ] `uv` project (`pyproject.toml`); dev tools in `[dependency-groups].dev`
- [ ] `mypy --strict` planned as a gate; typed signatures expected
- [ ] Async boundary decided per endpoint (no blocking I/O in `async def`)
- [ ] Typed config (`pydantic-settings`); secrets as `SecretStr`, compared with `hmac.compare_digest`
- [ ] Pydantic schemas separate from persistence entities
- [ ] Boundaries respected (RAG→apex-ai-systems/apex-search, auth→apex-auth, data→apex-data, choice→apex-stack)
- [ ] Verification Recipe present in impl.md and empirically run
