---
skill: apex-search
backend: coding
version: 1.3.0
last_updated: 2026-06-10
sources:
  - pgvector — github.com/pgvector/pgvector
  - Ollama — ollama.com/library
  - OpenAI Embeddings — platform.openai.com/docs/guides/embeddings
  - SP5 de-coupling (stack-neutral core; references/ illustration)
staleness_threshold: 30d
description: >
  Coding-mode rules for search/RAG retrieval — stack-neutral invariants (native vector type, ANN
  index where the store has one, chunk-before-embed, content-hash idempotency, dimension-locking).
  Loaded when a task does vector/keyword/hybrid retrieval. Concrete code is bound-stack-specific —
  the Postgres + TypeScript worked examples live in references/postgres-typescript.md.
---

# apex-search — retrieval implementation rules

Capability skill — **stack-neutral**. The bound stack skill's Verification Recipe is the verifier;
the concrete vector store + language come from the bound stack (see § Stack assumptions).

## Stack assumptions

Rules below are stack-neutral; the concrete worked examples assume **Postgres + pgvector +
TypeScript** (`references/postgres-typescript.md`). On the bound store, swap:

- **Vector + similarity:** pgvector `VECTOR(n)` / HNSW / `<=>` → **sqlite-vec** `vec0` / `FLOAT[n]` / `MATCH … k=` (exact brute-force, no ANN index); LanceDB / Qdrant native API.
- **Keyword:** Postgres `tsvector` / GIN / `ts_rank` → **SQLite** FTS5 / `bm25()`.
- **Hybrid:** Postgres `FULL OUTER JOIN` → **SQLite** `UNION` of id-sets + two `LEFT JOIN`s (same `1/(60+rank)` math).
- **Store enablement:** `CREATE EXTENSION vector` once per DB → **sqlite-vec** loaded **per connection**.
- **Language:** the embed / chunk / ingest code follows the bound language (TS examples → Python on `apex-python`).

## NEVER do

- Store embeddings as `float[]` / JSON / TEXT — use the store's native vector type (pgvector `VECTOR(n)`, sqlite-vec `FLOAT[n]`).
- Run similarity search without the store's ANN index where it has one (pgvector HNSW/IVFFlat) on tables > 10k rows. *(sqlite-vec has none — exact brute-force, correct at single-user/desktop scale.)*
- Embed the same content twice — check the content hash before calling the embedding API.
- Send a whole document to the embedding API without chunking first.
- Return raw embedding vectors in API responses — internal only.

## ALWAYS do

- Enable the vector store before use (pgvector: `CREATE EXTENSION vector` per DB; sqlite-vec: load **per connection**).
- Match the vector column dimension to the exact embedding-model output (e.g. 768 for `nomic-embed-text`).
- Chunk content before embedding, with overlap.
- Store a SHA-256 `content_hash` per chunk to skip re-embedding unchanged content.
- Check the embedding service (e.g. Ollama) is healthy before starting an ingest run.

## Acceptance checks (stack-neutral)

- Insert a chunk → embedding stored as the store's native vector type (not JSON/TEXT).
- Ingest the same document twice → no duplicate chunks (content-hash idempotency).
- Hybrid search → results combine keyword + vector scores via RRF (not vector-only).
- Embedding dimension matches the vector column definition.
- Similarity query uses the ANN index where the store has one. Verify: Postgres — run `EXPLAIN ANALYZE <query>` and confirm an Index Scan on the HNSW/IVFFlat index (not Seq Scan); SQLite — run `EXPLAIN QUERY PLAN <query>` (sqlite-vec is exact brute-force, no ANN index expected).

## Worked examples (load on demand)

> The concrete **Postgres + TypeScript** implementation (enable pgvector, Ollama embed,
> chunk-with-overlap, hybrid RRF SQL, idempotent ingest) is in
> **`references/postgres-typescript.md`** — load it **only when the bound stack is Postgres +
> TypeScript**. On another stack, follow the bound stack skill's patterns and the swaps in
> § Stack assumptions.
