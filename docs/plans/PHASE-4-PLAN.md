# Phase 4 — Story 4: Operability and Observability

**Issue:** #5 · **Branch:** `story-4-operability`

## Story

> As an operator, I want the service to be observable and resilient so that I can understand what it's doing and diagnose issues.

## Acceptance Criteria (from exercise, verbatim)

- [x] Logs clearly indicate: ingestion behavior, successful processing, failures and retries *(live run 2026-07-09: poll.cycle / enrich.enqueued / enrich.success narrate a healthy run; poll.error with a climbing `consecutive` narrates an outage; poll.escalated narrates the exit)*
- [x] Malformed or unexpected data is handled gracefully *(mechanism built in Phase 2; chaos spec pins a garbage 200 body as a warned transient cycle, not a crash)*
- [x] The service does not crash-loop on transient failures *(network failures absorbed as Result values indefinitely; a dead DB is paced backoff for ~23 min, then one visible container recycle per streak — observed live, D-026)*

## Tasks

- [x] Structured logging finalized: one JSON object per line to stdout — `ts`, `level`, `component`, `event`, plus context keys; adopted everywhere. *(As planned, this named a `StructuredLogger` class; what ships is `JsonLogFormatter` (the unbypassable line-shape boundary, built in Phase 1) plus the `StructuredLogging` mixin stamping `component`/`event` at every call site — D-027 records why a wrapper class was rejected.)*
- [x] Canonical log events documented in docs/ARCHITECTURE.md § Observability — as a per-component table transcribed from what the code emits. Field names this plan guessed are corrected there: the sleep field is `sleep_for` (not `next_poll_in`/`sleep_seconds`), `enrich.cache_hit` is the *queuer's* event while a worker 304 logs `enrich.success` with `not_modified: true`, and `poll.cycle` also carries `status`, `malformed_skipped`, `structured_skipped`.
- [x] Failure-path audit (checklist every external touchpoint): network timeout, DNS failure, 403/429, 404, 5xx, invalid JSON body, Postgres unavailable at boot → each path either retries with backoff, parks, or skips-and-logs. **No path exits nonzero on a transient *network* error.** (One deliberate exception, decided this phase: DB-shaped errors exit nonzero after a ~20-min consecutive streak so compose can recycle the container — D-026. One-shot mode still exits nonzero on any non-`:ok`/`:not_modified` poll — D-016.) Outcomes recorded in ARCHITECTURE.md § Failure Handling Matrix; the DB rows executed live (see Notes).
- [x] Distinguish persistent from transient failures in `IngestRunner`'s continuous-mode catch-all (from the Phase 1 review): done as D-026 — DB-availability shapes back off with a `consecutive` counter and escalate at `MAX_CONSECUTIVE_FAILURES`; everything else escalates immediately; both exit nonzero after a fatal `poll.escalated`, making compose's restart the replacement for the Phase 0 boot-time `SELECT 1`.
- [x] Boot resilience: compose healthcheck gates `migrate` gates the services (Phase 3); in-app, a db unavailable at first cycle is the same DB-shaped rescue as mid-run — backoff, then a paced container recycle (D-026). Worker: the Solid Queue supervisor exits against a dead db and `restart: unless-stopped` paces the retry — observed live, recovered unattended when the db returned.
- [x] Graceful shutdown: SIGTERM finishes the in-flight event/job before exit — observed live on `docker compose down`: `shutdown.clean` logged, ingester exit code 0, worker deregistered inside its 25s grace
- [x] README "**How to verify it's working**" section:
  - [x] Expected log lines (with real examples) at 0–2 min, and after first poll interval — real captured lines pasted
  - [x] Tables to check + copy-paste SQL — and the SQL now names the real database: the locked structure said `app_development`, the actual database is `github_events_pipeline_development` (fourth doc falsehood this phase; the copy-paste block failed verbatim)
  - [x] Expected timing corrected to the 120s poll floor (D-022) — the locked text still said ~60s

## Exit Criteria

- [x] `docker compose logs -f` alone tells the full story of a healthy run to someone who has never seen the code *(live 2026-07-09: boot → poll.cycle with counts → enrich.enqueued → enrich.success, every line component+event tagged)*
- [x] Chaos checks pass: stop db mid-run → service retries and recovers *(executed live, full arc: poll.error consecutive 1→10 over 23 min of capped backoff → fatal poll.escalated → exit 1 → Docker restart → fresh streak → recovery 20s after db start)*; feed 403 fixture → sleeps and resumes; feed garbage JSON → warn + continue *(both as executable WebMock chaos specs, spec/services/ingest_runner_chaos_spec.rb)*
- [x] `docker compose up` → wait → verify section's SQL returns growing counts, no manual intervention *(raw_events 568 → 623 across the phase's runs; actors 156 fetched / 175 pending, repositories 154/1/200 — all states healthy)*

## Out of Scope

Metrics endpoints / Prometheus (noted in brief as production next-step, not built).

## Notes / Discovered Work

- **Much of this phase was already built by Phase 3 and needed verification, not code**: graceful shutdown (runner signal traps + slice-sleep + `shutdown.clean`; worker `shutdown_timeout` 20s / compose `stop_grace_period` 25s) and boot ordering (db healthcheck → `migrate` → services).
- **Three doc falsehoods found and closed** (the docs-describe-what-doesn't-exist defect class, third sighting): `poll.rate_limited` was documented and README-promised but never emitted (now emitted); `poll.error`/`shutdown.clean`/`auth.unexpected_401` were emitted but undocumented (now in the table); the README example showed `next_poll_in` where the code emits `sleep_for`.
- **The 403 chaos fixture is synthesized, not captured** — a deliberate, recorded exception to the capture-real rule: capturing a real 403 requires burning the entire shared 60/hr budget first. The `X-Fixture-Note` header inside the fixture records this where the file is read.
- **What sharpened D-026**: tracing proved network failures cannot raise into the runner's rescue (the client returns them as `Result` values), so the classification only has to distinguish DB-availability shapes from bugs. *(The pre-merge review then showed the premise held only per-class, not per-surface — see the remediation bullet below and D-028.)*
- **Live escalation timeline (2026-07-09, zero API spend — the cycle raises at the `RateLimitState` read before any HTTP)**: db stopped 19:11 → `poll.error` consecutive 1 at 19:12:35 (`ActiveRecord::DatabaseConnectionError`, a `ConnectionNotEstablished` subclass — the transient arm caught it) → 10 at 19:35:37 with fatal `poll.escalated reason=transient_failures_exhausted` → exit 1 → Docker restart (`RestartCount` 1) → fresh process, new streak at 1 → db started 19:35:58 → recovery `poll.cycle status=ok` 19:36:12, worker resumed enriching unattended at 19:36:25.
- **Worker vs dead db, observed**: the Solid Queue supervisor fails boot-time config validation against an unreachable db and exits; `restart: unless-stopped` paces the retry loop. Loud in `docker compose ps`, self-heals when the db returns. Left as-is: adding an in-app db wait to `bin/jobs` would duplicate what the restart policy already provides.
- **README's copy-paste SQL named a nonexistent database** (`app_development`; real name `github_events_pipeline_development`) — found because exit criterion 3 executed the block verbatim and it failed. Falsehood #4; the criterion's whole point.
- **Trap: capturing log lines via `rails runner` in the test env poisons the test database.** The `poll.rate_limited` capture ran the real loop against the 403 fixture, and its rate-mirror upsert persisted outside any transaction — four "nil before any response" specs failed at the final gate until the leftover `rate_limit_states` row was deleted. Wrap future capture scripts in a rolled-back transaction or clean up after them.
- **Post-review remediation (D-028)**: the pre-merge review found the escalation premises leaking — `GithubClient::NETWORK_ERRORS` missed the gzip/status-line/errno surface (a transient network blip would have crash-looped as `permanent_error`), the all-rows-refused re-raise let a data-shaped batch error drive D-026's classification, `escalate`'s raise dumped a non-JSON backtrace after the "last" fatal line, a SIGTERM racing a failing cycle exited dirty, and the garbage-JSON criterion said "warn" while nothing warned. All fixed on this branch: the client warns `body.unparseable` (the chaos spec now asserts it, making the criterion true as written), `escalate` exits 1 carrying a trimmed backtrace, a requested stop outranks escalation, and the stale claims the review caught (docker-compose's "never exits nonzero", the formatter's pre-D-027 usage example, the wrong `ConnectionFailed` hierarchy comment) now say what the code does — falsehoods #5–8 of the phase's defect class, caught by the same diff-docs-against-code habit.
