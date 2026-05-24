---
skill: apex-docs-product
version: 1.0.0
last_updated: 2026-05-24
sources:
  - Keep a Changelog — keepachangelog.com
staleness_threshold: 30d
---

# Product Documentation Implementation Rules

## NEVER do

- Describe implementation details in user-facing docs — describe what users can do
- Use technical jargon in user guides — write for the end user
- Leave [TODO] or placeholder text in published docs
- Update the changelog with internal changes (refactors, tests, config) — only user-facing changes
- Write "fixed a bug" — describe what broke and what works now

## ALWAYS do

- Write from the user's perspective: "You can now..." not "We added..."
- Keep README concise — link to docs/product/ for detail
- Use imperative mood in guides: "Click Save" not "You should click Save"
- Add code examples to API reference for every endpoint
- Keep a Changelog format: Added / Changed / Fixed / Removed / Deprecated

## Changelog entry format (Keep a Changelog)

```markdown
## [Unreleased]

### Added
- Users can now reset their password from the login screen

### Changed
- API responses now include a `requestId` field for support requests

### Fixed
- Users with special characters in their name are no longer logged out on refresh
```

## JSDoc pattern (TypeScript)

```typescript
/**
 * Creates a new user account and sends a verification email.
 * @param data - User registration data
 * @returns The created user with id assigned
 * @throws {ValidationError} If email is already registered
 */
export async function createUser(data: CreateUserInput): Promise<User> {
  // ...
}
```

## OpenAPI endpoint pattern

```yaml
/api/auth/refresh:
  post:
    summary: Refresh access token
    description: Exchange a valid refresh token for a new access token.
    requestBody:
      required: true
      content:
        application/json:
          schema:
            type: object
            properties:
              refreshToken:
                type: string
                example: "eyJhbGciOiJIUzI1NiJ9..."
    responses:
      '200':
        description: New access token issued
      '401':
        description: Refresh token invalid or expired
```

## Verification checklist

- [ ] Check: all exported functions in changed files have JSDoc
- [ ] Check: changelog entry written under [Unreleased]
- [ ] Check: no placeholder text ([TODO], TBD) in any doc file
- [ ] Check: README updated if user-facing behaviour changed
