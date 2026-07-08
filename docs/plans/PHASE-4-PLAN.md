# Phase 4 — Story 4: Operability and Observability

**Issue:** #5 · **Branch:** `story-4-operability`

## Story

> As an operator, I want the service to be observable and resilient so that I can understand what it's doing and diagnose issues.

## Acceptance Criteria (from exercise, verbatim)

- [ ] Logs clearly indicate: ingestion behavior, successful processing, failures and retries
- [ ] Malformed or unexpected data is handled gracefully *(mechanism built in Phase 2; verified/standardized here)*
- [ ] The service does not crash-loop on transient failures

## Tasks

- [ ] `StructuredLogger` finalized: one JSON object per line to stdout — `ts`, `level`, `component`, `event`, plus context keys; adopted everywhere (replace Phase 1's basic logging)
- [ ] Canonical log events documented in docs/ARCHITECTURE.md § Observability:
  - `poll.cycle` — `events_seen`, `push_events_new`, `duplicates_skipped`, `not_modified`, `budget_remaining`, `next_poll_in`
  - `poll.rate_limited` — `reset_at`, `sleep_seconds`
  - `enrich.success` / `enrich.cache_hit` / `enrich.parked` / `enrich.retry` / `enrich.terminal` — with `kind`, `github_id`, `reason`, `attempt`
  - `ingest.malformed` — `github_event_id`, `reason`
  - `security.url_rejected` — `host`
- [ ] Failure-path audit (checklist every external touchpoint): network timeout, DNS failure, 403/429, 404, 5xx, invalid JSON body, Postgres unavailable at boot → each path either retries with backoff, parks, or skips-and-logs. **No path exits nonzero on a transient error.** (Applies to the continuous service; one-shot mode deliberately exits nonzero on any non-`:ok`/`:not_modified` poll — D-016.)
- [ ] Distinguish persistent from transient failures in `IngestRunner`'s continuous-mode catch-all (from the Phase 1 review): a dead DB or programming error currently backs off silently forever, and because the container never exits, compose's `restart: unless-stopped` can never fire. Define an escalation policy (e.g. exit after N consecutive identical failures, or a health signal an operator can alert on) and a replacement for the Phase 0 boot-time `SELECT 1` fail-fast that the runner's catch-all absorbed.
- [ ] Boot resilience: ingester/worker wait-and-retry for db readiness (compose healthcheck + in-app retry)
- [ ] Graceful shutdown: SIGTERM finishes the in-flight event/job before exit (docker compose down leaves consistent state)
- [ ] README "**How to verify it's working**" section:
  - [ ] Expected log lines (with real examples) at 0–2 min, and after first poll interval
  - [ ] Tables to check + copy-paste SQL (`SELECT count(*) FROM raw_events;` etc.)
  - [ ] Expected timing: first rows within ~1 poll cycle; enrichment within ~2–3 min subject to budget

## Exit Criteria

- [ ] `docker compose logs -f` alone tells the full story of a healthy run to someone who has never seen the code
- [ ] Chaos checks pass: stop db mid-run → service retries and recovers; feed 403 fixture → sleeps and resumes; feed garbage JSON → warn + continue
- [ ] `docker compose up` → wait → verify section's SQL returns growing counts, no manual intervention

## Out of Scope

Metrics endpoints / Prometheus (noted in brief as production next-step, not built).

## Notes / Discovered Work

_(append during the phase)_
