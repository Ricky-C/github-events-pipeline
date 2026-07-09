# Phase 3 — Story 3: Enrich Push Events

**Issue:** #4 · **Branch:** `story-3-enrichment`

## Story

> As a data consumer, I want push events enriched with related actor and repository data so that I can better understand contributors and repositories.

## Acceptance Criteria (from exercise, verbatim)

- [x] Actor and repository data are retrieved using URLs provided in the event payload — `payload.actor.url` / `payload.repo.url`, SSRF-guarded at ingest and again at fetch time
- [x] Enriched data is persisted durably — `actors.data` / `repositories.data` (jsonb) in Postgres, written inside a savepointed transaction; 103 actors + 100 repositories enriched live
- [x] The solution avoids obviously unnecessary repeated fetches — 24h TTL gate folded into the atomic claim, per-record conditional ETags, in-flight dedup; max 1 fetch per entity per TTL window, observed live
- [ ] The approach is explained in the design brief — **Phase 5.** `DESIGN.md` is still a stub by design (doc map: "finalized in Phase 5"); the material it draws on is complete (D-022, D-023, D-024, D-025 + `ARCHITECTURE.md`)

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
- [x] **`EnrichmentSweep`** (post-review, D-024): Solid Queue *dead-letters* the claimed execution of a hard-killed worker rather than re-running it, stranding the record at `enqueued` forever. A 15-minute recurring job releases and re-claims any `enqueued` record with no live job; `shutdown_timeout` (20s) is raised above the worst-case fetch (15s) so a *graceful* restart releases the claim instead of racing to dead-letter it.

## Exit Criteria

- [x] End-to-end: ingest → jobs enqueued → actors/repos rows gain enrichment `data` + `fetched_at` — executed live 2026-07-09: 103 actors + 100 repositories enriched with full `data` jsonb across two budget windows; one real deleted repo landed `not_found` terminally
- [x] Same actor appearing in many pushes triggers ≤1 fetch per TTL window (visible in logs) — max `enrich.success` count per entity over the whole run: 1; 24 `enrich.cache_hit` lines for repeats
- [x] With budget forced to 0 (test/fixture), jobs park and later run — no failures, no crash-loop — spec-covered (forced 0), and observed live with *real* exhaustion: enrichment drained to the reserve, parked to reset+jitter, the backlog ran at window rollover, drained the fresh window to the reserve again, and re-parked to the next reset; 0 failed executions
- [x] A fixture payload with a non-github URL is rejected by the SSRF guard with a security log line — committed fixture `events_page_with_hostile_url.json` + queuer spec assert `security.url_rejected`, NULL url, zero jobs, zero HTTP
- [x] Worker survives restart mid-queue; nothing is lost (Solid Queue in Postgres, plus the D-024 sweep). Two windows, both executed:
  - **Scheduled (parked) job** — restarted with one in queue; it survived, ran post-reset, and no entity was fetched twice. A `scheduled_execution` is a plain row, so this always held.
  - **Claimed job** (never exercised until the review round; the criterion's real subject) — 2026-07-09, worker SIGKILLed mid-fetch, then restarted. Solid Queue pruned the dead process 5 min later and **dead-lettered** the claimed execution with `ProcessPrunedError`; the job kept `finished_at IS NULL` and no execution row, actor 50 stayed `enqueued` with `data` NULL, the budget mirror never moved (the fetch never completed), and a replayed event logged `enrich.skipped reason=in_flight` with zero new jobs. **The enrichment was silently lost.** With `EnrichmentSweep` deployed, the scheduler's next fire reclaimed it: `enrich.swept reason=dead_lettered reclaimed=true` → `enrich.sweep swept:1` → `enrich.success`, 260 ms end to end. Actor 50 settled `fetched` with 33 `data` keys, exactly one `enrich.success` for that entity across the whole run, budget 60 → 59 (one request), the dead-letter row kept as the audit trail, zero failed executions since.
  - **Re-executed at `f0f9f7a`**, because review round 2 rewrote the very code this criterion exercises — `reclaim` now calls the extracted `Enrichable.claim_and_enqueue`, `beyond_window?` is anchored to `job.created_at`, and `ENTITIES` derives its model from `job_class.record_class`. Same shape, same result, against the refactored sweep:

    ```
    16:39:06  SIGKILL while a claimed execution existed (container restarts=1)
    16:39:09  actor 317 enqueued, data NULL; job 1640 finished_at NULL; claim orphaned;
              failed_executions 1 (nothing dead-lettered it); budget mirror 59, unmoved;
              claim_for_enrichment(583231) => false
    16:44:16  Process.prune -> job 1640 dead-lettered (ProcessPrunedError), finished_at NULL;
              actor 317 STILL enqueued
    16:45:00  the recurring */15 sweep fires on its own (not triggered by hand):
              enrich.swept reason=dead_lettered reclaimed=true -> enrich.sweep swept:1
              -> enrich.success (+310 ms)
    16:45:07  actor 317 fetched, 33 data keys, real weak ETag; mirror 59 -> 58 (one request);
              failed_executions 2 (dead-letter row preserved); retry/retry_exhausted/sweep_aborted: 0
    ```

    `enrich.sweep_aborted: 0` is the live corroboration of the new fail-safe's assumption: the sweep read the record id out of a real Active Job envelope, exactly as the canary spec asserts against the real Solid Queue adapter (D-025).
  - The guarantee is *at-least-once*, not "no lost or duplicated": a graceful restart mid-fetch re-runs the job once (`shutdown_timeout` 20s > the 15s worst-case fetch, so the fork releases its claim rather than racing the supervisor's SIGQUIT to dead-letter it). Persists are idempotent `update!`s; the cost is one wasted request, and it is the right trade against losing the entity (D-024).

## Out of Scope

Avatar downloads / object storage (Extension C — intentionally not built). Final log schema (Phase 4).

## Notes / Discovered Work

- (post-review, D-024) The review round found three defects, two of them wrong in the decision record itself: D-023's "Solid Queue's process recovery re-runs it" is false (it dead-letters), `etag` was the one externally-sourced string reaching a column without `StorableString`, and `park_at`/`until_reset` clamped only their lower bound. `config.active_job.enqueue_after_transaction_commit` also turned out to be a no-op at application level in Rails 8.1 — the pin now lives on `ApplicationJob`.

- (from Phase 2) `push_events` deliberately carries no actor/repo URL columns (D-020): the enrichment enqueue reads URLs from the in-memory event payload at ingest time per the Tasks list, or joins `raw_events.payload` for backfill. Every payload-sourced URL passes UrlGuard regardless of where it was read from.
- D-017 re-measured at phase start (D-022): 304s **do** decrement the unauthenticated budget, so the poll floor was stretched to 120s before any enrichment code landed.
- The committed real fixture page surfaced a production case the plan missed: GitHub serves bot actor URLs with raw square brackets (RFC-3986-invalid). The queuer percent-escapes `[`/`]` before the guard (D-023) — without this, the firehose's most common actors would never enrich.
- Deviations from this plan's literal text (state count, claim predicate, guard layering, stale-mirror escape) are recorded with rationale in D-023.
