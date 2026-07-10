---
skill: apex-python
backend: coding
version: 1.0.0
last_updated: 2026-05-31
sources:
  - Context7 /fastapi/fastapi + /websites/fastapi_tiangolo (fetched 2026-05-31)
  - docs/research/python-stack-best-practices.md
  - Recipe empirically validated against a real FastAPI project (uv + ruff + mypy --strict + pytest)
staleness_threshold: 30d
description: >
  Coding-mode patterns for a typed Python / FastAPI service — uv project setup, pydantic-settings,
  async rules, and the Verification Recipe. Loaded when stack_skills includes apex-python.
---

# apex-python — Implementation patterns

Typed Python 3.12+ / FastAPI service. Pre-resolved defaults — apply directly. The base model already
writes good FastAPI structure; this file covers only what it gets wrong + the recipe.

## NEVER do

- Use `pip` / `poetry` / `python -m venv` / `conda` for a new project — use **`uv`**.
- Put dev tools (ruff, mypy, pytest) in `[project.optional-dependencies]` — `uv sync` skips extras by
  default. Put them in `[dependency-groups].dev` so plain `uv sync` installs them.
- Call **blocking I/O inside an `async def` route/dependency** (sync DB driver, `requests`,
  `time.sleep`, big CPU loop) — it stalls the single-thread event loop. Use an async client
  (`httpx.AsyncClient`, async SQLAlchemy) or a plain `def` route (FastAPI runs it in a threadpool).
- Reuse a Pydantic schema as the ORM/persistence model — keep request/response schemas separate from
  storage entities.
- Read config via bare `os.environ[...]` — use a typed `pydantic-settings` `BaseSettings`.
- Compare a secret/token with `==` — use `hmac.compare_digest` (timing-safe).
- Ship `mypy` errors silenced by scattered `# type: ignore` — isolate the rare unavoidable ignore
  to one place with a specific code (`# type: ignore[call-arg]`).

## ALWAYS do

- Manage the project with `uv`: `uv init`, `uv add <pkg>`, `uv add --dev ruff mypy pytest`,
  `uv sync`, `uv run <cmd>`. `pyproject.toml` is the single source of truth.
- Enforce `mypy --strict` from day one (this is the verifiability buy-back for dynamic Python).
- Use `async def` for I/O-bound routes with async clients; use plain `def` for sync/CPU work
  (threadpool). Don't mix blocking calls into `async def`.
- Type every function signature (params + return). `-> None` is not optional under strict.

## Pattern — typed settings (pydantic-settings)

```python
# config.py
from functools import lru_cache
from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="APP_", env_file=".env")
    db_url: str = "sqlite:///:memory:"
    api_key: SecretStr                      # required; never logs its value

@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]  # env-populated; one ignore, here only
```

- **The `call-arg` gotcha:** `mypy --strict` flags `Settings()` ("missing argument `api_key`")
  because it can't see env population. First-line fix: enable the plugin —
  `[tool.mypy] plugins = ["pydantic.mypy"]`. If the error persists for a required env field, keep
  **one** localized `# type: ignore[call-arg]` in this cached factory — never scatter it.

## Pattern — async route with an async client (no blocking I/O)

```python
import httpx
from fastapi import APIRouter, Depends
router = APIRouter()

@router.get("/fetch")
async def fetch(client: httpx.AsyncClient = Depends(get_client)) -> dict[str, str]:
    resp = await client.get("https://api.example.com/data")   # awaited, non-blocking
    resp.raise_for_status()
    return resp.json()
```

## Pattern — timing-safe token check

```python
import hmac
def token_ok(supplied: str, expected: SecretStr) -> bool:
    return hmac.compare_digest(supplied, expected.get_secret_value())
```

## Verification Recipe

**Layered: language carries the buildability weight (dynamic lang → bought back by `mypy --strict`).**

**Project layer (uv):**
```bash
uv sync                       # installs deps + [dependency-groups].dev; add --all-extras only if dev tools are extras
```

**Language + quality layer:**
```bash
uv run ruff format --check .  # format gate (apply: uv run ruff format .)
uv run ruff check .           # lint gate (autofix: uv run ruff check . --fix)
uv run mypy --strict src      # type gate — the verifiability buy-back
uv run pytest -q              # test gate
```

**The loop (per task):** `uv sync` once → `mypy --strict` (fix first error, re-run) → `ruff check`
→ `ruff format --check` → `pytest`. One hypothesis per failure (apex-debug discipline); don't
shotgun. `mypy` is authoritative for correctness; `pytest` for behaviour.

**Composition:** capability skills layered on top (`apex-ai-systems`, `apex-search`) add their own
checks; coding mode unions them with this recipe. RAG/vector specifics live there, not here.

## Common errors → fix

| Error fragment | Cause | Fix |
|----------------|-------|-----|
| `Missing named argument "…" for "Settings"` | mypy can't see env population | `plugins = ["pydantic.mypy"]`, or one localized `# type: ignore[call-arg]` in the factory |
| `No module named 'mypy'/'pytest'` after `uv sync` | dev tools are extras, not a dep-group | move to `[dependency-groups].dev`, or `uv sync --all-extras` |
| `ModuleNotFoundError: No module named '<pkg>'` in tests | src-layout package not installed | ensure `[tool.hatch.build.targets.wheel] packages = ["src/<pkg>"]`; `uv sync` |
| mypy: `Function is missing a return type annotation` | strict mode | add the return type (`-> None` if it returns nothing) |
| event loop stalls / requests pile up | blocking I/O in `async def` | use an async client, or make the route plain `def` |
