---
skill: apex-search
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - pgvector — github.com/pgvector/pgvector
  - Ollama — ollama.com/library
  - OpenAI Embeddings — platform.openai.com/docs/guides/embeddings
staleness_threshold: 30d
---

## NEVER do

- Store embedding vectors as `float[]` or JSON — use `VECTOR(n)` type (requires pgvector extension)
- Run `ORDER BY embedding <-> $1 LIMIT 10` without an HNSW or IVFFlat index on large tables
- Embed the same content twice — always check content hash before calling embedding API
- Send raw document text to embedding API without chunking
- Return embedding vectors in API responses — they're internal only
- Use IVFFlat index if table has fewer than 1M rows — HNSW is better for small-medium scale

## ALWAYS do

- Enable pgvector extension before running migrations: `CREATE EXTENSION IF NOT EXISTS vector`
- Match `VECTOR(n)` dimension to the exact model output dimension
- Chunk content before embedding, with overlap
- Store `contentHash` (SHA-256) on each chunk to skip re-embedding unchanged content
- Apply HNSW index after initial bulk insert (faster than indexing during insert)
- Check Ollama health before starting the ingest pipeline

## Code example — enable pgvector in migration

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

## Code example — generate embedding with Ollama

```typescript
async function embed(text: string): Promise<number[]> {
  const res = await fetch('http://localhost:11434/api/embeddings', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'nomic-embed-text', prompt: text }),
  })
  const { embedding } = await res.json()
  return embedding
}
```

## Code example — chunk text with overlap

```typescript
function chunkText(text: string, chunkSize = 512, overlap = 50): string[] {
  const words = text.split(/\s+/)
  const chunks: string[] = []
  let i = 0
  while (i < words.length) {
    chunks.push(words.slice(i, i + chunkSize).join(' '))
    i += chunkSize - overlap
  }
  return chunks
}
```

## Code example — hybrid search query (RRF)

```sql
WITH fts AS (
  SELECT id, ts_rank(fts_vector, query) AS rank,
         ROW_NUMBER() OVER (ORDER BY ts_rank(fts_vector, query) DESC) AS rn
  FROM chunks, plainto_tsquery('english', $1) query
  WHERE fts_vector @@ query
  LIMIT 20
),
vec AS (
  SELECT id,
         ROW_NUMBER() OVER (ORDER BY embedding <=> $2::vector) AS rn
  FROM chunks
  ORDER BY embedding <=> $2::vector
  LIMIT 20
),
rrf AS (
  SELECT
    COALESCE(fts.id, vec.id) AS id,
    COALESCE(1.0 / (60 + fts.rn), 0) + COALESCE(1.0 / (60 + vec.rn), 0) AS score
  FROM fts FULL OUTER JOIN vec ON fts.id = vec.id
)
SELECT chunks.content, chunks.document_id, rrf.score
FROM rrf JOIN chunks ON chunks.id = rrf.id
ORDER BY rrf.score DESC
LIMIT $3;
```

## Code example — ingest document (chunk + embed + store)

```typescript
import { createHash } from 'crypto'

async function ingestDocument(docId: string, content: string) {
  const chunks = chunkText(content)

  for (let i = 0; i < chunks.length; i++) {
    const hash = createHash('sha256').update(chunks[i]).digest('hex')

    // Skip if already embedded (idempotent ingest)
    const existing = await db.query(
      'SELECT id FROM chunks WHERE document_id = $1 AND chunk_index = $2 AND content_hash = $3',
      [docId, i, hash]
    )
    if (existing.rows.length > 0) continue

    const embedding = await embed(chunks[i])

    await db.query(
      `INSERT INTO chunks (document_id, content, chunk_index, content_hash, embedding)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (document_id, chunk_index) DO UPDATE
       SET content = $2, content_hash = $4, embedding = $5`,
      [docId, chunks[i], i, hash, JSON.stringify(embedding)]
    )
  }
}
```

## Verification checklist

- [ ] `CREATE EXTENSION IF NOT EXISTS vector` runs without error
- [ ] Insert a chunk with embedding → stored as `VECTOR` type, not JSON
- [ ] `EXPLAIN` on similarity query shows index scan (not seq scan)
- [ ] Ingest same document twice → no duplicate chunks (idempotent)
- [ ] Hybrid search returns results combining both FTS and vector scores
- [ ] Embedding dimensions match `VECTOR(n)` column definition
- [ ] Ollama running locally: `curl http://localhost:11434/api/embeddings` responds
