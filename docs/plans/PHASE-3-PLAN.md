# Phase 3 — Story 3: Enrich Push Events

**Issue:** #4 · **Branch:** `story-3-enrichment`

## Story

> As a data consumer, I want push events enriched with related actor and repository data so that I can better understand contributors and repositories.

## Acceptance Criteria (from exercise, verbatim)

- [ ] Actor and repository data are retrieved using URLs provided in the event payload
- [ ] Enriched data is persisted durably
- [ ] The solution avoids obviously unnecessary repeated fetches
- [ ] The approach is explained in the design brief

## Tasks

- [x] Solid Queue setup: migrations, `worker` compose service (`bin/jobs`), queue config (`enrichment` queue, bounded concurrency = 1 to serialize budget spend)
  - [x] **Explicitly set** `config.active_job.queue_adapter = :solid_queue` — the development default is the async adapter, which would fake-pass everything in-process
  - [x] Point Solid Queue at the **primary database** (override Rails 8's separate-queue-db default) — one system of record is the durability story (docs/DECISIONS.md D-010)
- [x] `actors` migration: `github_id` (unique), `login`, `url`, `avatar_url`, `data` (jsonb), `etag`, `fetched_at`, `fetch_status` (five states — see D-023; the three listed here plus `enqueued`/`rejected`)
- [x] `repositories` migration: `github_id` (unique), `full_name`, `url`, `data` (jsonb), `etag`, `fetched_at`, `fetch_status`
- [x] Enqueue logic in ingest pipeline (`EnrichmentQueuer`, best-effort after raw persistence):
  - [x] Upsert stub actor/repo rows from payload (id, login/name, url) — enrichment is additive; identity-only `DO UPDATE` (D-023)
  - [x] **TTL gate:** skip enqueue if `fetched_at` within 24h (fan-out control; log as `cache_hit`)
  - [x] Dedup in-flight via **atomic `fetch_status` claim** — one UPDATE folds the TTL gate in (claimable from `pending` or TTL-expired `fetched`; the plan's pending-only predicate could never re-enrich — D-023); enqueue the job only if the claim won, in the same transaction; job resets status to `pending` on transient give-up so a later event can re-claim
- [x] `EnrichActorJob` / `EnrichRepositoryJob` (thin shells over `EnrichmentFetcher`):
  - [x] **SSRF guard:** refuse any URL whose host isn't exactly `api.github.com` — enforced at ingest (queuer pre-validation, security log, URL never persisted) and again inside `GithubClient#fetch_resource`; jobs consume `:rejected_url` as terminal `rejected` rather than re-implementing the guard
  - [x] **Budget gate:** check remaining via `GithubClient`; if exhausted, reschedule for `reset_at` + jitter — park, don't fail; when `reset_at` unknown (rate-limited before any budget observation), park `now + 60s`; stale-mirror escape once the observed window has rolled (D-023)
  - [x] Conditional fetch with stored per-record ETag where present
  - [x] `404` → mark `fetch_status: not_found`, never retry (deleted users/repos are routine in the public firehose)
  - [x] `5xx`/timeouts → retry with exponential backoff, capped attempts, then discard with error log (claim released to `pending`)
- [x] Budget allocation decision recorded in `docs/DECISIONS.md` (D-022: 304s cost budget, poll floor 120s ⇒ ~30 polls/hr, enrichment takes the remainder above a reserve of 5)

## Exit Criteria

- [x] End-to-end: ingest → jobs enqueued → actors/repos rows gain enrichment `data` + `fetched_at` — executed live 2026-07-09: 103 actors + 100 repositories enriched with full `data` jsonb across two budget windows; one real deleted repo landed `not_found` terminally
- [x] Same actor appearing in many pushes triggers ≤1 fetch per TTL window (visible in logs) — max `enrich.success` count per entity over the whole run: 1; 24 `enrich.cache_hit` lines for repeats
- [x] With budget forced to 0 (test/fixture), jobs park and later run — no failures, no crash-loop — spec-covered (forced 0), and observed live with *real* exhaustion: enrichment drained to the reserve, parked to reset+jitter, the backlog ran at window rollover, drained the fresh window to the reserve again, and re-parked to the next reset; 0 failed executions
- [x] A fixture payload with a non-github URL is rejected by the SSRF guard with a security log line — committed fixture `events_page_with_hostile_url.json` + queuer spec assert `security.url_rejected`, NULL url, zero jobs, zero HTTP
- [x] Worker survives restart mid-queue; no lost or duplicated enrichment (Solid Queue in Postgres) — restarted with a scheduled (parked) job in queue; it survived, ran post-reset, and no entity was fetched twice

## Out of Scope

Avatar downloads / object storage (Extension C — intentionally not built). Final log schema (Phase 4).

## Notes / Discovered Work

- (from Phase 2) `push_events` deliberately carries no actor/repo URL columns (D-020): the enrichment enqueue reads URLs from the in-memory event payload at ingest time per the Tasks list, or joins `raw_events.payload` for backfill. Every payload-sourced URL passes UrlGuard regardless of where it was read from.
- D-017 re-measured at phase start (D-022): 304s **do** decrement the unauthenticated budget, so the poll floor was stretched to 120s before any enrichment code landed.
- The committed real fixture page surfaced a production case the plan missed: GitHub serves bot actor URLs with raw square brackets (RFC-3986-invalid). The queuer percent-escapes `[`/`]` before the guard (D-023) — without this, the firehose's most common actors would never enrich.
- Deviations from this plan's literal text (state count, claim predicate, guard layering, stale-mirror escape) are recorded with rationale in D-023.
