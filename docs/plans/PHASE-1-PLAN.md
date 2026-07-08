# Phase 1 — Story 1: Ingest GitHub Push Events

**Issue:** #2 · **Branch:** `story-1-ingest`

## Story

> As a data consumer, I want GitHub Push activity ingested so that it can be analyzed later.

## Acceptance Criteria (from exercise, verbatim)

- [x] Events are ingested from the GitHub Public Events API or deterministic equivalent
- [x] Only PushEvent items are processed
- [x] Each event is persisted durably
- [x] Events can be uniquely identified and inspected later
- [x] Ingestion is repeatable or continuous

## Tasks

- [x] `GithubClient` service — the single chokepoint for all API traffic. **Build to contract: `docs/specs/GITHUB-CLIENT.md`** (interface, Result taxonomy, URL guard, redirect policy, header discipline). Highlights:
  - [x] `poll_events` with persisted ETag; `304` → `:not_modified` (but see D-017: a live 304 was observed carrying a decremented remaining)
  - [x] Parse and expose `X-Poll-Interval`; persist `X-RateLimit-Remaining`/`Reset` (shared budget in Postgres)
  - [x] Returns `Result` values — the client never sleeps, retries, or raises for expected outcomes
- [x] Ingester loop owns cadence policy (per spec § Caller Contracts): sleeps `poll_interval` normally, sleeps until `reset_at` + jitter on `:rate_limited`, capped backoff on `:transient_error` — never exits nonzero (`IngestRunner`)
- [x] `rate_limit_states` table (or single-row state): last etag, remaining, reset_at — singleton via guard column + partial upsert (D-014)
- [x] `raw_events` migration: `github_event_id` (string, **unique index**), `event_type`, `payload` (jsonb), `received_at`
- [x] `EventIngester` service: fetch page → filter `type == "PushEvent"` → `insert_all`/upsert with `ON CONFLICT DO NOTHING` → return counts
- [x] **Single page per poll — no pagination** (docs/DECISIONS.md D-009): `/events` is a sliding-window sample either way; paginating multiplies budget spend up to 10× for marginal completeness. Sampling accepted, stated in brief.
- [x] `ingest` compose service: continuous poll loop honoring poll interval; also runnable one-shot via runner argument in the compose command (D-016)
- [x] Log per cycle: `events_seen`, `push_events_new`, `duplicates_skipped`, `budget_remaining`, `not_modified` (basic version; Phase 4 standardizes format) — plus `malformed_skipped` and `sleep_for`

## Exit Criteria

All executed live on 2026-07-08 (observed output in PR #10):

- [x] `docker compose run --rm ingest` (one-shot) populates `raw_events`; rows inspectable via console/psql — 30 seen, 28 new PushEvents; payload/etag/rate state inspected via runner console
- [x] Running it twice produces zero duplicate rows (unique index proof) — live re-ingest of 10 persisted payloads: `push_events_new: 0, duplicates_skipped: 10`; `GROUP BY github_event_id HAVING COUNT(*) > 1` → 0 rows over 188 events
- [x] Continuous mode visibly honors `X-Poll-Interval` in logs — three cycles at 17:52:48/17:53:49/17:54:49, `sleep_for: 60` matching the header
- [x] Killing and restarting the ingester loses nothing and re-ingests nothing — SIGTERM → `shutdown.clean`, exit 0; restart resumed polling, row count monotonic (135 → 188), duplicate SQL still 0
- [x] Full contract test checklist from `docs/specs/GITHUB-CLIENT.md` green (WebMock fixtures) — 77 examples, 0 failures; RuboCop/Brakeman/bundler-audit clean

## Out of Scope

Structured `push_events` columns (Phase 2). Enrichment (Phase 3). Final log format (Phase 4).

## Notes / Discovered Work

- **D-017 (for Phase 3/4 attention):** during fixture capture, a real 304 arrived with a decremented `x-ratelimit-remaining` (59 → 58), contradicting the documented "304s are free" behavior the budget policy leans on. Client code mirrors headers and assumes nothing; re-measure across several 304s before Phase 3 sets enrichment budget policy — if it holds, the effective poll interval needs stretching.
- ~~From Phase 0 security review: harden `JsonLogFormatter`.~~ **Done in Phase 0** during code-review remediation: reserved `ts`/`level` keys now win over hash-message keys, all string values (including hash keys/values, recursively) are scrubbed to valid UTF-8 so `JSON.generate` can't raise mid-loop, and exceptions log via `msg2str` (class + backtrace). Spec matrix covers newline injection, reserved-key collision, duplicate string keys, invalid UTF-8 (string and nested hash), and exceptions.
