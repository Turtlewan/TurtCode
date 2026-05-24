---
skill: apex-observability
version: 1.1.0
last_updated: 2026-05-24
sources:
  - OpenTelemetry Docs — opentelemetry.io/docs
  - Sentry Docs — docs.sentry.io
  - Sentry for AI — github.com/getsentry/sentry-for-ai
  - Sentry MCP — github.com/getsentry/sentry-mcp
  - Grafana MCP — github.com/grafana/mcp-grafana
  - OpenTelemetry MCP — github.com/traceloop/opentelemetry-mcp-server
staleness_threshold: 14d
---

# Observability Specialist — Planning Mode

## When to activate
Adding logging, metrics, alerting, distributed tracing, error tracking,
or any production monitoring concern.

## Three pillars

Logs: what happened (structured JSON, not strings)
Metrics: how the system is behaving (counters, gauges, histograms)
Traces: where time was spent across a request (OpenTelemetry spans)

## Questions to ask before designing

- What questions will we need to answer in production when something goes wrong?
- What events should be logged? At what level?
- What metrics matter for this feature?
- Does this feature need a trace span?

## Logging levels

ERROR: unexpected failures that need immediate attention
WARN: expected failures or degraded states (retries, fallbacks)
INFO: significant business events (user created, order placed)
DEBUG: developer context — not logged in production

## Review checklist

- [ ] All ERROR/WARN logs include context (userId, requestId, relevant IDs)
- [ ] No PII in logs (no passwords, emails, tokens — use IDs only)
- [ ] Business events logged at INFO level
- [ ] External calls wrapped in trace spans
- [ ] Error tracking (Sentry) captures unexpected errors

## MCP-powered observability tools

When investigating production issues, these MCP servers unlock live data:

**Sentry MCP** (mcp.sentry.dev):
- `search_issues` — natural language query over Sentry issues
- `search_events` — raw events with stack traces and breadcrumbs
- Triage by user impact; correlate issues with recent deploys via PR context

**Grafana MCP** (github.com/grafana/mcp-grafana):
- Query Prometheus (PromQL), Loki (LogQL), ClickHouse, CloudWatch, and more
- Retrieve dashboard panels and alert states
- Create Sift investigations for automated anomaly detection
- Prefer dashboard summaries over full JSON to save context window

**OpenTelemetry MCP** (Jaeger/Tempo backend):
- Search traces by service, operation, duration, error status
- Filter by LLM-specific attributes: model type, token counts (via OpenLLMetry conventions)
- Identify bottlenecks and expensive spans in distributed requests

## AI/LLM observability

When the application uses LLM APIs (Anthropic, OpenAI), instrument:
- Token usage per request (input + output + cache hits)
- Model latency (time-to-first-token, total duration)
- Error rates by model and endpoint
- Cost per operation (token count × price)

Use OpenLLMetry semantic conventions for consistent attribute names across providers.
