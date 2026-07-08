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

- [ ] Solid Queue setup: migrations, `worker` compose service (`bin/jobs`), queue config (`enrichment` queue, bounded concurrency = 1 to serialize budget spend)
  - [ ] **Explicitly set** `config.active_job.queue_adapter = :solid_queue` — the development default is the async adapter, which would fake-pass everything in-process
  - [ ] Point Solid Queue at the **primary database** (override Rails 8's separate-queue-db default) — one system of record is the durability story (docs/DECISIONS.md D-010)
- [ ] `actors` migration: `github_id` (unique), `login`, `url`, `avatar_url`, `data` (jsonb), `etag`, `fetched_at`, `fetch_status` (pending/fetched/not_found)
- [ ] `repositories` migration: `github_id` (unique), `full_name`, `url`, `data` (jsonb), `etag`, `fetched_at`, `fetch_status`
- [ ] Enqueue logic in ingest pipeline:
  - [ ] Upsert stub actor/repo rows from payload (id, login/name, url) — enrichment is additive
  - [ ] **TTL gate:** skip enqueue if `fetched_at` within 24h (fan-out control; log as `cache_hit`)
  - [ ] Dedup in-flight via **atomic `fetch_status` claim** (Solid Queue has no native enqueue-uniqueness): `UPDATE ... SET fetch_status='enqueued' WHERE id=? AND fetch_status='pending'` — enqueue the job only if the claim won; job resets status to `pending` on transient give-up so a later event can re-claim
- [ ] `EnrichActorJob` / `EnrichRepositoryJob`:
  - [ ] **SSRF guard:** refuse any URL whose host isn't exactly `api.github.com` (payload URLs are untrusted input)
  - [ ] **Budget gate:** check remaining via `GithubClient`; if exhausted, reschedule for `reset_at` + jitter — park, don't fail; when `reset_at` unknown (rate-limited before any budget observation), park `now + 60s`
  - [ ] Conditional fetch with stored per-record ETag where present
  - [ ] `404` → mark `fetch_status: not_found`, never retry (deleted users/repos are routine in the public firehose)
  - [ ] `5xx`/timeouts → retry with exponential backoff, capped attempts, then discard with error log
- [ ] Budget allocation decision recorded in `docs/DECISIONS.md` (e.g., polling reserves ~1 req per poll-interval; enrichment consumes the remainder)

## Exit Criteria

- [ ] End-to-end: ingest → jobs enqueued → actors/repos rows gain enrichment `data` + `fetched_at`
- [ ] Same actor appearing in many pushes triggers ≤1 fetch per TTL window (visible in logs)
- [ ] With budget forced to 0 (test/fixture), jobs park and later run — no failures, no crash-loop
- [ ] A fixture payload with a non-github URL is rejected by the SSRF guard with a security log line
- [ ] Worker survives restart mid-queue; no lost or duplicated enrichment (Solid Queue in Postgres)

## Out of Scope

Avatar downloads / object storage (Extension C — intentionally not built). Final log schema (Phase 4).

## Notes / Discovered Work

- (from Phase 2) `push_events` deliberately carries no actor/repo URL columns (D-020): the enrichment enqueue reads URLs from the in-memory event payload at ingest time per the Tasks list, or joins `raw_events.payload` for backfill. Every payload-sourced URL passes UrlGuard regardless of where it was read from.
