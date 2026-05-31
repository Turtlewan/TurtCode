---
skill: apex-search
backend: claude
version: 1.2.0
last_updated: 2026-05-31
sources:
  - pgvector — github.com/pgvector/pgvector
  - Ollama — ollama.com/library
  - OpenAI Embeddings — platform.openai.com/docs/guides/embeddings
  - Typesense Docs — typesense.org/docs
  - PostgreSQL FTS — postgresql.org/docs/current/textsearch.html
  - SP5 de-coupling (stack-agnostic; § Stack assumptions)
staleness_threshold: 30d
description: >
  Use when designing search or retrieval — full-text/keyword search, vector/semantic search,
  embeddings + chunking, or RAG retrieval feeding an AI/LLM. Triggers: "vector search",
  "semantic search", "RAG", "retrieval", "embeddings", "hybrid search", "search my notes/data".
  Concepts are stack-neutral (chunking, hybrid RRF, idempotent ingest, dimension-locking); concrete
  DDL illustrates Postgres + pgvector and adapts to the bound stack (e.g. SQLite + sqlite-vec) via
  § Stack assumptions. Not the LLM generation/eval layer (apex-ai-systems) or the stack choice
  itself (apex-stack).
---

# apex-search — Search & RAG

## Stack assumptions

Concrete DDL/index examples below assume **Postgres + pgvector + `tsvector`** (the *default-stack
illustration*). The **concepts are stack-neutral** — only the store's DDL and nearest-neighbour
syntax change. Planning checks this against the bound `stack_skills` and adapts on mismatch; the
**stack skill's Verification Recipe is the verifier, not this file**.

| Concept (keep) | Postgres + pgvector (illustrated) | Swap point on the bound store |
|---|---|---|
| Vector column + similarity | `VECTOR(n)` + HNSW index, `<=>` cosine | **SQLite + sqlite-vec:** `vec0` virtual table, `FLOAT[n]`, KNN via `embedding MATCH :q AND k = :n` — exact/brute-force (no ANN index; correct at single-user scale). **LanceDB / Qdrant:** native vector API. |
| Keyword search | `tsvector` + GIN, `ts_rank` | **SQLite:** FTS5 virtual table + `bm25()`. **Dedicated:** Typesense / Elastic. |
| Hybrid fusion (RRF) | one SQL query, FULL OUTER JOIN + COALESCE | **SQLite (no FULL OUTER JOIN):** `UNION` of id-sets + two `LEFT JOIN`s; identical `1/(60+rank)` math. |
| Store enablement | `CREATE EXTENSION vector` once per DB | **sqlite-vec:** load the extension **per connection**, not once per DB. |
| ID / JSON / time types | `UUID` / `JSONB` / `TIMESTAMPTZ` | **SQLite:** app-generated `TEXT` UUID / `TEXT` JSON / ISO-8601 `TEXT`. |

Stack-neutral — never swap these out: chunking, hybrid RRF, content-hash idempotency, exact
embedding-dimension locking, local-vs-API embedding choice.

## Research findings (default-stack reference — Postgres/pgvector/Prisma specifics)

| Technology | Finding | Tag |
|------------|---------|-----|
| pgvector | Current stable v0.8.1. HNSW index recommended over IVFFlat at all scales (better recall, faster queries). SQL: `CREATE INDEX ON chunks USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64)`. | [VERIFIED] |
| Prisma + pgvector | No native VECTOR type in schema.prisma. Requires `Unsupported("vector")`. Similarity queries must use `$queryRaw`. Prisma Studio cannot display vector columns. Prisma 7 (roadmap 2025/2026) promised first-class support. | [VERIFIED] |
| Ollama embeddings | nomic-embed-text v1.5 (768d, 8K context) recommended as default. mxbai-embed-large (1024d, 512 token limit) for better retrieval. all-minilm (384d, 256 limit) for speed. nomic-embed-text supports Matryoshka dims (512/256/128/64). | [VERIFIED] |
| OpenAI embeddings | text-embedding-3-small (1536d, $0.02/1M) and text-embedding-3-large (3072d, $0.13/1M). Both support `dimensions` parameter for reduction. Batch API: 50% discount. | [VERIFIED] |
| Hybrid RRF pattern | Single SQL query using CTEs with FULL OUTER JOIN + COALESCE. RRF formula: score = 1/(60 + rank_fts) + 1/(60 + rank_vector). ~84% retrieval precision (vs ~62% vector-only). | [VERIFIED] |
| Typesense | Latest server v30.2. npm package: `typesense` v2.x. Docker image works on Mac Mini ARM. No native macOS ARM64 binary confirmed. | [ASSUMED] |
| LangChain vs direct pgvector | For personal AI brain projects, LangChain is overkill. Direct pgvector + raw SQL + plain fetch() is simpler, fewer deps, better performance. Skip LangChain. | [VERIFIED] |

## When to activate

- "search" / "full-text search" / "find relevant"
- "vector search" / "semantic search" / "similarity search"
- "RAG" / "retrieval" / "embeddings" / "pgvector"
- "AI brain retrieval" / "search my data" / "find documents"
- "autocomplete" / "faceted search" / "typo-tolerant"
- "Typesense" / "Algolia" / "Elasticsearch"
- "chunking" / "chunk documents" / "embedding pipeline"

## 5 questions to ask before designing

1. **What data is being searched?** — user notes, transactions, messages, documents, sensor history
2. **Query type?** — keyword exact match / typo-tolerant / semantic meaning / hybrid
3. **Is this feeding an AI/LLM?** — yes → vector search + chunking required
4. **Privacy requirement?** — local embeddings via Ollama vs OpenAI API
5. **Scale?** — < 1M chunks → pgvector fine; > 1M → consider dedicated search engine

## Search type decision table

| Use case | Approach | Default illustration (adapt per § Stack assumptions) |
|----------|----------|-------|
| Find exact keywords, moderate scale | PostgreSQL FTS | `tsvector` + `GIN` index |
| Typo-tolerant, facets, autocomplete | Typesense | Self-hosted, Docker |
| Semantic / meaning-based search | pgvector + embeddings | pgvector `HNSW` index |
| AI brain retrieval (RAG) | Hybrid: FTS + vector + RRF | pgvector + `ts_rank` + RRF |
| Hosted, no infra | Algolia | Paid, excellent DX |

**Primary recommendation: hybrid search (keyword + vector + RRF)** — it beats either alone (~84% vs ~62% precision). Implement it in whatever store the bound stack provides; a single DB doing both keyword + vector is ideal (Postgres `tsvector` + pgvector, *or* SQLite FTS5 + sqlite-vec) — zero extra infra. Reach for a dedicated engine (Typesense) only if typo-tolerance/facets become a priority.

## Embedding provider decision table

| Provider | Model | Dimensions | Privacy | Cost |
|----------|-------|-----------|---------|------|
| Ollama (local) | nomic-embed-text v1.5 | 768 (Matryoshka: 512/256/128/64) | ✅ fully local | Free |
| Ollama (local) | mxbai-embed-large | 1024 | ✅ fully local | Free |
| OpenAI | text-embedding-3-small | 1536 (reducible) | ❌ leaves device | ~$0.02/1M tokens |
| OpenAI | text-embedding-3-large | 3072 (reducible) | ❌ leaves device | ~$0.13/1M tokens |

**Recommendation for Mac Mini / personal AI brain:** Ollama local embeddings (privacy, no cost). `nomic-embed-text` as default with 8K context window. OpenAI as opt-in for higher quality when needed.

## DB schema for RAG (Postgres illustration — adapt DDL per § Stack assumptions)

The *shape* is the point — documents → chunks, `content_hash` for idempotent ingest, a
dimension-locked vector column, and a keyword index. On SQLite this becomes `chunks` + an FTS5
virtual table + a sqlite-vec `vec0` table keyed by a shared integer rowid (see § Stack assumptions).

```sql
-- Source documents (one row per ingested item)
CREATE TABLE documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source TEXT NOT NULL,        -- 'note', 'telegram', 'finance', 'home_sensor'
  title TEXT,
  content TEXT NOT NULL,
  metadata JSONB DEFAULT '{}', -- arbitrary source-specific fields
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Chunks (split documents before embedding)
CREATE TABLE chunks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id UUID REFERENCES documents(id) ON DELETE CASCADE,
  content TEXT NOT NULL,
  chunk_index INT NOT NULL,
  -- FTS column (update via trigger or on insert)
  fts_vector TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
  -- Vector column (dimension matches your embedding model)
  embedding VECTOR(768),       -- 768 for nomic-embed-text; update if model changes
  content_hash TEXT,           -- SHA-256 for idempotent ingest
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Indexes
CREATE INDEX chunks_fts_idx ON chunks USING GIN(fts_vector);
CREATE INDEX chunks_embedding_idx ON chunks USING HNSW(embedding vector_cosine_ops);
```

## Chunking strategies

| Strategy | When to use | Chunk size |
|----------|------------|------------|
| Fixed-size with overlap | General purpose, consistent data | 512 tokens, 50 token overlap |
| Sentence/paragraph boundary | Natural language (notes, messages) | Variable, split at `\n\n` or `.` |
| Document-level | Short documents (< 512 tokens) | No chunking needed |

Overlap rule: always overlap adjacent chunks by 10-15% to avoid cutting context at boundaries.

## Hybrid search flow (RRF — Reciprocal Rank Fusion)

1. Run the keyword/FTS query → ranked chunk IDs (Postgres `ts_rank`; SQLite FTS5 `bm25()`)
2. Run the vector similarity query → ranked chunk IDs by cosine distance (pgvector `<=>`; sqlite-vec `vec0` KNN)
3. Apply RRF formula: `score = 1/(k + rank_fts) + 1/(k + rank_vector)` where `k=60`
4. Sort by combined RRF score → return top N chunks
5. Inject top chunks into LLM context window (apex-ai-systems handles this step)

**Note on k=60:** The value 60 is widely used but tunable. Lower k gives more weight to top-ranked results; higher k distributes weight more evenly. Default 60 is a safe starting point.

## RAG retrieval → LLM handoff

apex-search returns: `{ chunks: Array<{ content, source, score }>, query }`
apex-ai-systems receives this and injects into prompt:

```
You have access to the following relevant context:
<context>
[chunk 1 content] (source: finance, score: 0.92)
[chunk 2 content] (source: telegram, score: 0.87)
</context>
Answer the user's question using this context where relevant.
```

## Hard blocks

- Never store embeddings as JSON/TEXT arrays — use the store's native vector type (pgvector `VECTOR`, sqlite-vec `FLOAT[n]`) so similarity search is optimised
- Never run similarity search **without the store's ANN index where it has one** (pgvector HNSW/IVFFlat) on tables > 10k rows — *exception:* sqlite-vec has no ANN index (exact brute-force KNN), which is correct at single-user/desktop scale
- Never embed full documents without chunking first — exceeds context window and degrades quality
- Never expose raw embedding vectors in API responses
- Never re-embed unchanged content — check content hash before calling embedding API
- On pgvector specifically: prefer HNSW over IVFFlat below ~1M rows (better recall, no training step)

## Review checklist

- [ ] `chunks` table has both `HNSW` index (vector) and `GIN` index (FTS)
- [ ] Embedding dimensions match the model being used (768 / 1024 / 1536 / 3072)
- [ ] Chunking splits on semantic boundaries, not arbitrary byte offsets
- [ ] Overlap applied between adjacent chunks
- [ ] Content hash stored to avoid re-embedding unchanged documents
- [ ] Hybrid RRF implemented — not relying on vector alone
- [ ] Retrieved chunks trimmed to fit LLM context window before injection

## Gotchas / edge cases

- **Vector store must be enabled before use** (stack-specific): pgvector → `CREATE EXTENSION IF NOT EXISTS vector` once per DB before any `VECTOR`-column table; **sqlite-vec → load the extension *per connection*** before any `vec0` query (it registers only on that connection). (Prisma: vector columns need `Unsupported("vector(n)")` + `$queryRaw` for similarity queries.)
- **HNSW vs IVFFlat** (pgvector): HNSW is faster at query time and needs no training step; IVFFlat needs `lists` tuning. HNSW is the default at this scale. (sqlite-vec offers neither — brute-force KNN.)
- **Embedding dimension must match exactly**: If you use `nomic-embed-text` (768 dims) and define `VECTOR(1536)`, queries will fail. The column definition and the model must be locked together. Changing models requires re-embedding all chunks.
- **Ollama must be running for ingest and query**: If Ollama is down, embedding generation fails. Include error handling for Ollama unavailability and recommend a health check before starting the ingest pipeline.
- **Idempotent ingest is critical**: Re-running ingest on the same document should not create duplicates. The content hash pattern handles this. Without it, every re-ingest doubles the chunk count.
- **Context window budgeting**: Retrieved chunks must fit in the LLM's context window alongside the system prompt and conversation history. The review checklist must include a token-count check before injection.
- **mxbai-embed-large truncation**: mxbai-embed-large silently truncates beyond 512 tokens with no error raised. Use nomic-embed-text (8K context) for longer content.
