# apex-search — Postgres + pgvector + TypeScript worked examples

**Load condition:** read this file only when the bound stack is **Postgres + pgvector + TypeScript**.
On another stack, follow the bound stack skill's patterns and the swaps in `impl.md` § Stack
assumptions (e.g. SQLite + sqlite-vec + Python). These are *one stack's illustration* of the
stack-neutral rules in `impl.md` — not the canonical implementation.

## Enable pgvector in migration

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

## Generate embedding with Ollama

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

## Chunk text with overlap

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

## Hybrid search query (RRF)

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

## Ingest document (chunk + embed + store, idempotent)

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
       VALUES ($1, $2, $3, $4, $5::vector)
       ON CONFLICT (document_id, chunk_index) DO UPDATE
       SET content = $2, content_hash = $4, embedding = $5::vector`,
      [docId, chunks[i], i, hash, `[${embedding.join(',')}]`]
    )
  }
}
```
