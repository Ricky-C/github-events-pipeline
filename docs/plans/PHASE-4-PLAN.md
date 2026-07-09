# Phase 4 — Story 4: Operability and Observability

**Issue:** #5 · **Branch:** `story-4-operability`

## Story

> As an operator, I want the service to be observable and resilient so that I can understand what it's doing and diagnose issues.

## Acceptance Criteria (from exercise, verbatim)

- [ ] Logs clearly indicate: ingestion behavior, successful processing, failures and retries
- [ ] Malformed or unexpected data is handled gracefully *(mechanism built in Phase 2; verified/standardized here)*
- [ ] The service does not crash-loop on transient failures

## Tasks

- [x] Structured logging finalized: one JSON object per line to stdout — `ts`, `level`, `component`, `event`, plus context keys; adopted everywhere. *(As planned, this named a `StructuredLogger` class; what ships is `JsonLogFormatter` (the unbypassable line-shape boundary, built in Phase 1) plus the `StructuredLogging` mixin stamping `component`/`event` at every call site — D-027 records why a wrapper class was rejected.)*
- [x] Canonical log events documented in docs/ARCHITECTURE.md § Observability — as a per-component table transcribed from what the code emits. Field names this plan guessed are corrected there: the sleep field is `sleep_for` (not `next_poll_in`/`sleep_seconds`), `enrich.cache_hit` is the *queuer's* event while a worker 304 logs `enrich.success` with `not_modified: true`, and `poll.cycle` also carries `status`, `malformed_skipped`, `structured_skipped`.
- [ ] Failure-path audit (checklist every external touchpoint): network timeout, DNS failure, 403/429, 404, 5xx, invalid JSON body, Postgres unavailable at boot → each path either retries with backoff, parks, or skips-and-logs. **No path exits nonzero on a transient *network* error.** (One deliberate exception, decided this phase: DB-shaped errors exit nonzero after a ~20-min consecutive streak so compose can recycle the container — D-026. One-shot mode still exits nonzero on any non-`:ok`/`:not_modified` poll — D-016.)
- [x] Distinguish persistent from transient failures in `IngestRunner`'s continuous-mode catch-all (from the Phase 1 review): done as D-026 — DB-availability shapes back off with a `consecutive` counter and escalate at `MAX_CONSECUTIVE_FAILURES`; everything else escalates immediately; both exit nonzero after a fatal `poll.escalated`, making compose's restart the replacement for the Phase 0 boot-time `SELECT 1`.
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

- **Much of this phase was already built by Phase 3 and needed verification, not code**: graceful shutdown (runner signal traps + slice-sleep + `shutdown.clean`; worker `shutdown_timeout` 20s / compose `stop_grace_period` 25s) and boot ordering (db healthcheck → `migrate` → services).
- **Three doc falsehoods found and closed** (the docs-describe-what-doesn't-exist defect class, third sighting): `poll.rate_limited` was documented and README-promised but never emitted (now emitted); `poll.error`/`shutdown.clean`/`auth.unexpected_401` were emitted but undocumented (now in the table); the README example showed `next_poll_in` where the code emits `sleep_for`.
- **The 403 chaos fixture is synthesized, not captured** — a deliberate, recorded exception to the capture-real rule: capturing a real 403 requires burning the entire shared 60/hr budget first. The `X-Fixture-Note` header inside the fixture records this where the file is read.
- **What sharpened D-026**: tracing proved network failures cannot raise into the runner's rescue (the client returns them as `Result` values), so the classification only has to distinguish DB-availability shapes from bugs.
