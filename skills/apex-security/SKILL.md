---
skill: apex-security
version: 1.1.0
last_updated: 2026-05-24
sources:
  - OWASP Top 10 (2021) — owasp.org/Top10
  - NIST SP 800-63B — pages.nist.gov/800-63-3/sp800-63b
  - Trail of Bits Skills — github.com/trailofbits/skills
  - Claude Code Security Review — github.com/anthropics/claude-code-security-review
  - Snyk Agent Scan — github.com/snyk/agent-scan
staleness_threshold: 14d
---

# Security Specialist — Planning Mode

## When to activate
Any spec involving: authentication, authorisation, user data, external APIs,
file uploads, cryptography, secrets management, session handling, SQL queries,
user-generated content rendered as HTML.

## Questions to ask before designing

- What is the trust boundary? Where does user input enter the system?
- What data is sensitive? Where is it stored and transmitted?
- What is the blast radius if this component is compromised?
- Are we building auth from scratch or extending existing?
- What third-party services have access to user data?

## Trade-off frameworks

Session tokens vs JWTs:
- Sessions: server-side revocation, simpler, requires session store
- JWTs: stateless, harder to revoke, suitable for microservices
- Default recommendation: sessions for monoliths, JWTs for distributed systems

RBAC vs ABAC:
- RBAC: simple, role-based, good for most apps
- ABAC: flexible, attribute-based, needed for fine-grained permissions
- Default: RBAC unless requirements demand ABAC

## Review checklist

- [ ] No secrets in source code or spec files
- [ ] Input validated at system boundary (not only client-side)
- [ ] Auth check on every protected route, not inherited by convention
- [ ] Rate limiting on all auth endpoints (5 attempts / 15 min minimum)
- [ ] Errors reveal no internal state (no stack traces, no "user not found")
- [ ] Passwords hashed with bcrypt/argon2 (min cost 12)
- [ ] Tokens have expiry (access: ≤15min, refresh: ≤7d)
- [ ] HTTPS enforced — no mixed content
- [ ] CORS configured explicitly — no wildcard in production
- [ ] SQL parameterised — no string concatenation

## Escalation rules

BLOCK (halt spec, must resolve before coding):
- Plaintext password storage
- Hardcoded secrets in spec or code
- Auth bypass in any code path
- Direct user input in SQL without parameterisation

FLAG (note in spec, coding mode must address):
- Missing rate limiting
- Overly broad permissions (admin flag with no scope)
- JWT without expiry
- No CSRF protection on state-changing endpoints

## Beyond-OWASP patterns (Trail of Bits)

Standard OWASP covers injection, auth, and data exposure. Also check:

- **Timing side-channels**: cryptographic comparisons must use constant-time functions — string equality is NOT safe for secrets
- **Supply chain**: for every new dependency, verify the package name (typosquatting), active maintenance, and no known malicious versions; use `snyk agent-scan` in CI
- **Variant analysis**: when a vulnerability is found, search the entire codebase for similar patterns — don't fix just one instance
- **GitHub Actions workflow security**: check for script injection via `${{ github.event.* }}` in workflow files
- **Zeroization**: ensure secrets are zeroed from memory after use (especially in C/Rust)

## AI/LLM-specific security

- **Prompt injection defense**: multi-layer — ML classifier + canary tokens + transcript review
- **Tool poisoning**: audit MCP server tool descriptions for embedded instructions that could hijack agent behaviour
- **Eval injection**: never pass user input to `eval()`, `exec()`, or dynamic code execution
- **RCE via deserialization**: avoid `pickle.loads()`, `yaml.load()` on untrusted data — use `yaml.safe_load()`

## Automated security review (CI)

Use `anthropics/claude-code-security-review` GitHub Action on PRs:
- Provides contextual semantic analysis (not just pattern matching)
- Lower false positives than traditional SAST
- Auto-filters DoS, rate-limiting, and open-redirect findings as low-impact
- Configurable with `custom-security-scan-instructions` for project-specific rules
- ⚠️ Only use for trusted PRs — not hardened against prompt injection from external contributors

## Standards

OWASP Top 10 (2021) — owasp.org/Top10
NIST SP 800-63B — Authentication guidelines
Trail of Bits Skills — github.com/trailofbits/skills
