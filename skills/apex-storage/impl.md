---
skill: apex-storage
backend: deepseek
version: 1.2.0
last_updated: 2026-06-01
sources:
  - AWS SDK v3 Docs — docs.aws.amazon.com/sdk-for-javascript/v3
  - MinIO Docs — min.io/docs
  - Cloudflare R2 Docs — developers.cloudflare.com/r2
  - file-type — github.com/sindresorhus/file-type
  - SP5 de-coupling (stack-neutral core; references/ illustration)
staleness_threshold: 30d
description: >
  Coding-mode rules for file storage — stack-neutral invariants (MIME-from-bytes, opaque
  UUID keys, store-before-DB-record, time-limited private access, soft-delete + async GC,
  env-var config). Loaded when a task uploads/stores/serves files. Concrete code is
  backend-specific — the S3-SDK + TypeScript worked examples live in references/s3-typescript.md;
  a local-filesystem backend (single-user hub) is a distinct code path, see § Stack assumptions.
---

# apex-storage — file-storage implementation rules

Capability skill — **stack-neutral**. The bound stack skill's Verification Recipe is the verifier;
the concrete storage client + language come from the bound stack (see § Stack assumptions).

## Stack assumptions

Rules below are stack-neutral; the worked examples assume an **S3-compatible object store via the
AWS S3 SDK + TypeScript** (`references/s3-typescript.md`, covering MinIO / S3 / R2). On the bound
stack, swap:

- **Storage client:** `@aws-sdk/client-s3` → **Python:** `boto3` / `aioboto3` (same MinIO/S3/R2). **Local single-user hub (Mac):** the **local filesystem** — no SDK, write under an app-data base dir.
- **MIME-from-bytes:** `file-type` (npm) → **Python:** `python-magic` / `filetype`. Same idea: read the first ~4 KB, classify by magic bytes.
- **Private-file access:** presigned GET URL (`getSignedUrl`) → boto3 `generate_presigned_url`. **Local fs:** there is no storage host to presign against → serve through an **authenticated app route that streams the file** (session/authz check + a short-lived signed token); do **not** expose the filesystem path.
- **Direct large-file upload:** presigned PUT (client → store) → boto3 presigned PUT. **Local fs:** no direct-to-store hop exists → stream multipart through the app to disk.
- **Config:** `STORAGE_ENDPOINT/BUCKET/ACCESS_KEY/SECRET` env vars → same contract; **local fs:** a single `STORAGE_BASE_DIR` env var instead of keys.

Two rules invert on a **local-filesystem** backend — call them out per § NEVER / § ALWAYS:
1. The "issue a signed URL, don't proxy through the server" rule **reverses**: with no separate
   storage host, you *must* serve private files through the authenticated app route.
2. **Path traversal becomes a live threat.** Object-store keys are opaque; a filesystem key like
   `../../etc/passwd` escapes the base dir. The UUID-key rule plus a resolved-path containment
   check are both mandatory on local fs.

## NEVER do

- Trust the `Content-Type` header or file extension for type validation — detect from the file's bytes (magic bytes).
- Use the user-supplied filename as the storage key or any part of the storage path.
- Store storage credentials / secrets in code — environment variables only.
- For a **remote object store**, proxy large downloads through the app server at scale — issue a time-limited signed URL instead. (Inverts on local fs — see below.)
- Delete from storage synchronously inside a request handler — soft-delete in the DB, an async job removes the object.
- Expose the internal storage key/path in API responses — return a DB record id.
- For a **local-filesystem** backend: write or read a path without confirming the *resolved absolute path* stays inside the storage base dir (path-traversal containment); and never serve files by handing out the filesystem path.

## ALWAYS do

- Generate an opaque UUID-based key, never derived from user input: `${ownerId}/${date}/${uuid}.${ext}`.
- Validate MIME from the first bytes (~4 KB) of the file, not the header/extension; block executable/script types.
- Write the object to storage FIRST, then insert the DB record (an orphan object is cheap to GC; an orphan DB record points at nothing).
- Serve private files via **time-limited access**: a signed URL on an object store, or an authenticated streaming route + short-lived signed token on local fs.
- Soft-delete in the DB first (`deletedAt`), then let an async worker remove the stored object.
- Keep all storage config (endpoint/bucket/keys, or the local base dir) in environment variables.
- Store file metadata (key, mime, size, owner, isPublic, timestamps) in the DB; look files up by record, never reconstruct the key from user input.
- On a local-filesystem backend, resolve the final path and assert it is contained within the base dir before any read/write.

## Acceptance checks (stack-neutral)

- Upload any file → object exists in the store under a UUID key; a DB metadata record is created.
- Upload an `.exe` / script → rejected (type detected from bytes, not header).
- Upload a file with a spoofed `Content-Type` → still classified by its bytes.
- Fetch a private file → only reachable via time-limited access; the link/route 403s after expiry.
- Soft-delete a file → DB row flagged, object still present until the async cleanup runs.
- (Object store) swap the backend by env only → upload/download code unchanged across MinIO/S3/R2.
- (Local fs) a key containing `../` cannot escape the base dir; private files are unreachable without auth.

## Worked examples (load on demand)

> The concrete **S3-SDK + TypeScript** implementation (S3 client for MinIO/S3/R2, server-side upload
> with MIME validation, presigned GET/PUT, MinIO docker-compose, `.env`, large-file streaming
> detection) is in **`references/s3-typescript.md`** — load it **only when the bound stack uses the
> AWS S3 SDK + TypeScript**. On a Python object-store app use the boto3/aioboto3 equivalents; for a
> **local-filesystem** backend there is no SDK and no presigning — follow the local-fs swaps in
> § Stack assumptions (authenticated streaming route + path-containment check).
