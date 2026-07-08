# Phase 1 — Story 1: Ingest GitHub Push Events

**Issue:** #2 · **Branch:** `story-1-ingest`

## Story

> As a data consumer, I want GitHub Push activity ingested so that it can be analyzed later.

## Acceptance Criteria (from exercise, verbatim)

- [ ] Events are ingested from the GitHub Public Events API or deterministic equivalent
- [ ] Only PushEvent items are processed
- [ ] Each event is persisted durably
- [ ] Events can be uniquely identified and inspected later
- [ ] Ingestion is repeatable or continuous

## Tasks

- [ ] `GithubClient` service — the single chokepoint for all API traffic. **Build to contract: `docs/specs/GITHUB-CLIENT.md`** (interface, Result taxonomy, URL guard, redirect policy, header discipline). Highlights:
  - [ ] `poll_events` with persisted ETag; `304` → `:not_modified`, zero budget spent
  - [ ] Parse and expose `X-Poll-Interval`; persist `X-RateLimit-Remaining`/`Reset` (shared budget in Postgres)
  - [ ] Returns `Result` values — the client never sleeps, retries, or raises for expected outcomes
- [ ] Ingester loop owns cadence policy (per spec § Caller Contracts): sleeps `poll_interval` normally, sleeps until `reset_at` + jitter on `:rate_limited`, capped backoff on `:transient_error` — never exits nonzero
- [ ] `rate_limit_states` table (or single-row state): last etag, remaining, reset_at
- [ ] `raw_events` migration: `github_event_id` (string, **unique index**), `event_type`, `payload` (jsonb), `received_at`
- [ ] `EventIngester` service: fetch page → filter `type == "PushEvent"` → `insert_all`/upsert with `ON CONFLICT DO NOTHING` → return counts
- [ ] **Single page per poll — no pagination** (docs/DECISIONS.md D-009): `/events` is a sliding-window sample either way; paginating multiplies budget spend up to 10× for marginal completeness. Sampling accepted, stated in brief.
- [ ] `ingest` compose service: continuous poll loop honoring poll interval; also runnable one-shot via env flag or arg
- [ ] Log per cycle: `events_seen`, `push_events_new`, `duplicates_skipped`, `budget_remaining`, `not_modified` (basic version; Phase 4 standardizes format)

## Exit Criteria

- [ ] `docker compose run --rm ingest` (one-shot) populates `raw_events`; rows inspectable via console/psql
- [ ] Running it twice produces zero duplicate rows (unique index proof)
- [ ] Continuous mode visibly honors `X-Poll-Interval` in logs
- [ ] Killing and restarting the ingester loses nothing and re-ingests nothing
- [ ] Full contract test checklist from `docs/specs/GITHUB-CLIENT.md` green (WebMock fixtures)

## Out of Scope

Structured `push_events` columns (Phase 2). Enrichment (Phase 3). Final log format (Phase 4).

## Notes / Discovered Work

- ~~From Phase 0 security review: harden `JsonLogFormatter`.~~ **Done in Phase 0** during code-review remediation: reserved `ts`/`level` keys now win over hash-message keys, all string values (including hash keys/values, recursively) are scrubbed to valid UTF-8 so `JSON.generate` can't raise mid-loop, and exceptions log via `msg2str` (class + backtrace). Spec matrix covers newline injection, reserved-key collision, duplicate string keys, invalid UTF-8 (string and nested hash), and exceptions.
