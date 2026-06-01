---
skill: apex-storage
backend: claude
version: 1.1.0
last_updated: 2026-06-01
sources:
  - AWS SDK v3 Docs — docs.aws.amazon.com/sdk-for-javascript/v3
  - MinIO Docs — min.io/docs
  - Cloudflare R2 Docs — developers.cloudflare.com/r2
  - file-type — github.com/sindresorhus/file-type
  - SP5 de-coupling (stack-agnostic; § Stack assumptions)
staleness_threshold: 30d
description: >
  Use when a project needs to store, upload, or serve files — object storage (S3/MinIO/R2),
  presigned URLs, MIME validation, image/document/attachment upload, multipart upload, file
  download. Concepts are stack-neutral (MIME-from-bytes, opaque UUID keys, store-before-record,
  time-limited private access, soft-delete + async GC); the S3-SDK examples adapt to the bound
  stack (Python boto3, or a local-filesystem backend for a single-user hub) via § Stack
  assumptions. Not the storage *decision* of whether to use files at all.
---

# File Storage Specialist — Planning Mode

## Stack assumptions

Concepts below are **stack-neutral**; concrete examples assume an **S3-compatible object store via
the AWS S3 SDK + TypeScript** (MinIO / S3 / R2 — the default illustration). Planning checks this
against the bound `stack_skills` and adapts on mismatch; the **stack skill's Verification Recipe is
the verifier**.

| Concept (keep) | S3-SDK + TS (illustrated) | Swap point on the bound stack |
|---|---|---|
| Storage client | `@aws-sdk/client-s3` (MinIO/S3/R2, one SDK) | **Python:** boto3 / aioboto3 (same 3 providers). **Local single-user hub (Mac):** the local filesystem — no SDK, write under a base dir. |
| MIME from bytes | `file-type` (npm) | **Python:** python-magic / filetype. Read first ~4 KB, classify by magic bytes. |
| Private-file access | presigned GET URL | boto3 `generate_presigned_url`. **Local fs:** no host to presign → authenticated streaming route + short-lived signed token. |
| Direct large upload | presigned PUT (client→store) | boto3 presigned PUT. **Local fs:** stream multipart through the app to disk (no direct hop). |
| Local dev store | MinIO via docker-compose | MinIO works for any object-store stack. **Local-fs backend needs no service at all.** |
| Config | `STORAGE_*` keys/endpoint env | same env contract; **local fs:** a single `STORAGE_BASE_DIR`. |

**Local filesystem is a genuinely different code path, not an endpoint swap** (object stores
MinIO/S3/R2 share one SDK — local fs does not). Two rules invert on it: private files must be
served *through* the app (no signed-URL host exists), and path traversal becomes a live threat
(opaque object keys can't escape; `../` filesystem keys can — add a resolved-path containment
check). Stack-neutral and never swapped: MIME-from-bytes, opaque UUID keys, store-before-DB-record,
time-limited private access, soft-delete + async GC, env-var config.

## Research findings

Research was performed before writing this skill. Findings are tagged with confidence:

- [VERIFIED] `@aws-sdk/client-s3` + `@aws-sdk/s3-request-presigner` work with MinIO. Requires `forcePathStyle: true` and custom `endpoint`. Known issue: presigned URLs for MinIO on non-standard ports may produce `SignatureDoesNotMatch` — override the `Host` header. (Sources: AWS SDK v3 Docs, MinIO GitHub issues #13779, #2726)
- [VERIFIED] MinIO Docker image is `minio/minio`. API port 9000, console port 9001. Command: `server /data --console-address ":9001"`. Health check: `/minio/health/live`. (Source: MinIO Docs)
- [VERIFIED] `file-type` v19.6.0 (latest). ESM-only. API: `fileTypeFromBuffer(buffer)`, `fileTypeFromStream(stream)`, `fileTypeFromFile(path)`. Returns `{ ext, mime }`. Uses 4100 bytes minimum (`minimumBytes`). (Source: file-type GitHub)
- [VERIFIED] Multer is **not** abandoned — v2.1.1 released March 2025, v3.0.0-alpha in progress. However, it buffers files in memory by default and is Express-only. For Fastify, prefer `@fastify/multipart`. For custom pipelines, use `busboy` directly. (Sources: npm, GitHub expressjs/multer)
- [VERIFIED] Presigned upload URLs are best practice for files >10 MB. Thresholds: <10 MB server-side, 10 MB–5 GB presigned PUT, >5 GB multipart presigned. Multipart requires S3 lifecycle rule for abandoned uploads. (Source: AWS docs, community benchmarks)
- [VERIFIED] Cloudflare R2 uses `@aws-sdk/client-s3` with `endpoint: 'https://<ACCOUNT_ID>.r2.cloudflarestorage.com'` and `region: 'auto'`. Requires `requestChecksumCalculation: "WHEN_REQUIRED"` and `responseChecksumValidation: "WHEN_REQUIRED"` in newer SDK v3 versions. R2 does not support direct browser SDK usage — always sign requests via backend. EU buckets need `https://<ACCOUNT_ID>.eu.r2.cloudflare.com`. (Source: Cloudflare R2 Docs)

## When to activate

Any time a project needs to store, upload, or serve files:

- "file upload" / "upload files" / "store files"
- "S3" / "R2" / "MinIO" / "object storage"
- "presigned URL" / "signed URL"
- "image upload" / "document upload" / "attachment"
- "file storage" / "serve files" / "download file"
- "multipart upload"
- "how to handle file uploads"

## Questions to ask before designing

1. **Local-first or cloud-first?** MinIO for self-hosted (Docker on dev machine or home server), S3/R2 for cloud. Same `@aws-sdk/client-s3` code — only the `endpoint` env var changes.
2. **Who can access uploaded files?** Public files (profile images, public assets) serve via direct URL or CDN. Private files (documents, personal data) require presigned GET URLs with short expiry.
3. **Expected file size range?** <10 MB is fine for server-side upload. 10 MB–5 GB needs presigned PUT directly from client. >5 GB requires multipart presigned upload.
4. **Any file type restrictions?** Images-only, documents-only, specific MIME allowlist, or generic with a blocklist for executables/scripts. Always validate from file bytes, never from Content-Type header.
5. **Multi-tenant?** Are files scoped per user, per tenant, or globally shared? Key naming and access control differ significantly.

## Storage provider decision table

| Scenario | Provider | Why |
|----------|----------|-----|
| Single-user / local-first hub (e.g. Mac mini) | Local filesystem | Zero infra — write under a base dir; no Docker, no daemon. Best default when there's exactly one node and no sharing. |
| Self-hosted / dev / home server | MinIO | Docker, S3-compatible API, free, runs locally, full control |
| Cloud scale, AWS infra | AWS S3 | Native integration, mature ecosystem, deep AWS service integration |
| Cloud scale, any infra | Cloudflare R2 | Zero egress fees, S3-compatible, global CDN, pay-per-operation |
| Self-hosted team / multi-node | MinIO or Garage | Open source, S3-compatible, no vendor lock-in |

**Key insight — one SDK for all *object-store* providers:**
MinIO, S3, and R2 all use `@aws-sdk/client-s3` (or boto3). The only difference is the `endpoint`:

```
MinIO:   endpoint: 'http://localhost:9000', forcePathStyle: true
S3:      (no endpoint override needed — use default)
R2:      endpoint: 'https://<ACCOUNT_ID>.r2.cloudflarestorage.com', region: 'auto'
```

Migrating between these three = change environment variables, not code. **The local-filesystem
backend is the exception** — it is a separate code path (no SDK, no presigning; serve via an
authenticated app route, and add a path-containment check). See § Stack assumptions.

## Upload strategy decision table

| File size | Strategy | Why |
|-----------|----------|-----|
| < 10 MB | Server receives — validates — streams to storage | Simple, one hop, easy MIME/size validation |
| 10 MB – 5 GB | Presigned PUT URL — client uploads direct to storage | Server not a data bottleneck |
| > 5 GB | Multipart presigned upload — client uploads chunks in parallel | S3 5 GB single PUT limit, resumes on failure |

For multipart uploads, always configure an S3 lifecycle rule to abort incomplete multipart uploads after N days — otherwise abandoned parts accrue storage costs.

## File metadata — always store in DB

```sql
CREATE TABLE files (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key          TEXT NOT NULL UNIQUE,          -- S3/MinIO/R2 object key
  originalName TEXT NOT NULL,                 -- user-supplied filename (for display only)
  mimeType     TEXT NOT NULL,                 -- validated by file-type from bytes
  sizeBytes    BIGINT NOT NULL,
  bucket       TEXT NOT NULL DEFAULT 'default',
  uploadedBy   UUID NOT NULL REFERENCES users(id),
  isPublic     BOOLEAN NOT NULL DEFAULT false,
  createdAt    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deletedAt    TIMESTAMPTZ                     -- soft-delete column
);

CREATE INDEX idx_files_uploaded_by ON files(uploadedBy);
CREATE INDEX idx_files_deleted_at ON files(deletedAt) WHERE deletedAt IS NULL;
```

Never serve files by guessing the S3 key from user input — always look up via DB record. The `key` is an internal identifier; never expose it directly to API responses.

## File validation rules (server-side — never trust client)

1. **Validate MIME from bytes** — use `file-type` package. Read first 4100 bytes (`fileTypeFromBuffer`), detect MIME type from magic bytes. Never trust `Content-Type` header or filename extension.
2. **Enforce size limit before reading** — check `Content-Length` header or stream size before buffering. For server-side upload, reject early.
3. **Blocklist dangerous types** — `.exe`, `.sh`, `.bat`, `.ps1`, `.php`, `.jar`, `.dll`, and any script/executable MIME types.
4. **Optional allowlist** — only accept specific MIME types for the use case (e.g., `image/*` for avatar uploads, `application/pdf` for document uploads).

## Access control patterns

- **Public files** (profile images, public assets): store without restrictions, serve via direct URL or CDN. Mark `isPublic = true` in DB.
- **Private files** (documents, personal data): generate presigned GET URL with short expiry (15 minutes / 900 seconds). The URL is time-bound and scoped to one object.
- Never serve private files by proxying through your server at scale (bandwidth is double: client to server to storage).

## File key naming convention

```
{userId}/{date}/{uuid}.{ext}
```

Examples:
- `user_abc123/2026-05-28/a1b2c3d4-5678-90ab-cdef-1234567890ab.jpg`
- `user_abc123/2026-05-28/fedcba98-7654-3210-abcdef-0123456789ab.pdf`

Never use the original filename as the storage key — path traversal (`../../etc/passwd`), encoding tricks, and collision risk.

## Deletion pattern

1. **Soft-delete in DB first** — set `deletedAt = now()` on the file record.
2. **Async job deletes from storage** — a background worker periodically scans for records where `deletedAt IS NOT NULL` and the object still exists in storage, then deletes.

Never delete from S3 synchronously inside a request handler — if the DB transaction succeeds but the S3 delete fails, you have an orphaned object. If S3 delete succeeds but DB fails, you have an orphaned record.

## Hard blocks

- Never validate file type from the `Content-Type` header or filename extension alone — always check the file's bytes (`file-type` / `python-magic` / the stack equivalent).
- Never use the user-supplied filename as the storage key.
- Never expose the internal storage key/path directly in API responses — return a DB record ID.
- Never proxy large file downloads through the server **on an object store** — use a presigned GET URL. (On a **local-filesystem** backend this inverts: there is no presign host, so you *must* serve via an authenticated streaming route + short-lived token.)
- On a **local-filesystem** backend, never read/write a path without confirming the resolved absolute path is contained within the storage base dir (path-traversal guard), and never hand out the filesystem path to clients.
- Never delete from storage without first marking `deletedAt` in the DB.
- Never hardcode storage credentials (object-store keys, or any secret) in source code — environment variables only.

## Gotchas and edge cases

_Object-store / S3-SDK ecosystem (illustration — applies when the bound stack is MinIO/S3/R2; a
local-filesystem backend has none of these, but adds the path-containment concern in § Stack
assumptions)._

- **Multer is not abandoned** (v2.1.1, March 2025) but buffers files in memory by default, which is problematic for large files. For Fastify, use `@fastify/multipart`. For custom streaming pipelines, use `busboy` directly. Evaluate based on framework choice.
- **`forcePathStyle: true` is required for MinIO**: Without this, the SDK constructs virtual-hosted URLs (`bucket.localhost:9000`) which MinIO does not support. S3 and R2 use virtual-hosted style by default, so this flag is `false` for them.
- **`file-type` works on buffers, not streams directly**: For large files, read only the first 4100 bytes for type detection (`fileTypeFromBuffer`), then stream the rest to storage. Do not buffer the entire large file in memory just for MIME detection.
- **Partial upload failure**: Upload to S3 first, then insert the DB record. If DB insert fails, enqueue an async cleanup job to delete the S3 object. This prevents orphaned DB records pointing to non-existent files.
- **MinIO does not auto-create buckets**: A setup script, docker-compose init container, or app startup check must create the bucket before the first upload.
- **R2 zero egress but not zero cost**: R2 charges per operation (PUT, GET, DELETE). For high-read workloads, add Cloudflare CDN in front to reduce operation costs.
- **R2 EU regions need a different endpoint**: `https://<ACCOUNT_ID>.eu.r2.cloudflare.com` instead of the default `*.r2.cloudflarestorage.com`.
- **R2 + SDK v3 checksum**: Newer SDK v3 versions require `requestChecksumCalculation: "WHEN_REQUIRED"` and `responseChecksumValidation: "WHEN_REQUIRED"` in the S3Client config for R2 compatibility.
- **MinIO presigned URL + non-standard port**: Presigned URLs for MinIO on port 9000 can cause `SignatureDoesNotMatch`. Workaround: override the `Host` header to include the port, or proxy MinIO behind a reverse proxy on port 80/443.

## Review checklist

- [ ] File type validated from bytes (not filename or Content-Type header)
- [ ] Size limit enforced before full file is read into memory
- [ ] Storage key uses UUID-based naming, not original filename
- [ ] File metadata record created in DB (upload-to-storage-first pattern)
- [ ] Private files served via presigned GET URL with expiry <= 15 minutes
- [ ] Deletion follows soft-delete-first pattern (DB then async storage cleanup)
- [ ] MinIO/S3/R2 credentials in environment variables, not in code
- [ ] `forcePathStyle` is correctly set based on provider
- [ ] Multipart uploads have S3 lifecycle rule for aborting incomplete uploads
- [ ] R2-specific config (region: 'auto', checksum flags) applied when using R2
