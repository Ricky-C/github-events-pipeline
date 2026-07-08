# Phase 2 — Story 2: Persist Raw and Structured Data

**Issue:** #3 · **Branch:** `story-2-structured-persistence`

## Story

> As an analyst, I want key push attributes stored in a structured form so that I can query them without parsing raw JSON.

## Acceptance Criteria (from exercise, verbatim)

- [x] Raw event payloads are retained for audit/debug purposes *(done in Phase 1 — `raw_events`)*
- [x] Queryable without JSON parsing: repository identifier, push identifier, ref, head, before
- [x] Data modeling choices are documented at a high level

## Tasks

- [x] `push_events` migration:
  - `github_event_id` (string, unique index, FK-by-convention to `raw_events`)
  - `push_id` (bigint, indexed), `ref`, `head_sha`, `before_sha`
  - `repository_github_id` (bigint, indexed), `repository_name`
  - `actor_github_id` (bigint, indexed), `actor_login`
  - `event_created_at` (indexed — "over time" analysis is the stated business goal)
- [x] `PushEventParser` service: raw payload → attribute hash; returns a result object (`ok` / `malformed` + reason); length-validates string fields (see docs/THREAT-MODEL.md)
- [x] Ingest pipeline: raw insert + structured insert in **one transaction**; structured upsert keyed on `github_event_id`
- [x] Malformed-payload path: raw row always persists; structured row skipped; single warn-level log with reason and event id (graceful — no raise)
- [x] Data-modeling rationale written into PR body and `docs/DECISIONS.md` (why columns-not-views, why keep raw + structured, index choices) — D-020

## Exit Criteria

All executed live on 2026-07-08 (observed output in the PR):

- [x] The five required fields answerable via plain SQL, no JSON operators — `SELECT repository_github_id, push_id, ref, head_sha, before_sha FROM push_events ORDER BY event_created_at DESC LIMIT 5` returned 5 rows, no JSON operators
- [x] A deliberately mangled fixture payload ingests without error: raw persisted, structured skipped, warning logged — spec-level by design (real fixture PushEvent with `push_id` deleted): raw kept, no structured row, one `ingest.structured_skipped` warn, nothing raised
- [x] Re-running ingestion over the same events yields zero structured duplicates — live: GitHub re-served the same page (`duplicates_skipped: 25, push_events_new: 0`), then `count(*) = count(DISTINCT github_event_id) = 52`; deterministic proof in the re-ingest and self-heal specs
- [x] Parser unit specs cover happy path + ≥3 malformed shapes (missing keys, wrong types, oversized strings) — 29 parser examples: 5 missing-key, 4 wrong-type, 3 oversized, plus NUL, hex-discipline, and storability-range cases; suite total 123 examples, 0 failures; RuboCop and Brakeman clean

## Out of Scope

Actor/repo enrichment tables (Phase 3) — this phase only extracts what's already in the push payload.

## Notes / Discovered Work

- Pre-Phase-2 `raw_events` rows get no automatic backfill: the structured insert runs for every parsed-ok row on each ingest (D-020), so events that re-appear in the feed self-heal; the remainder is dev data, covered by a one-off console rebuild from raw if ever needed. Deliberately not built. Any such rebuild skips `payload_scrubbed` rows by construction — the parser rejects them (D-021).
- Composite index `(repository_github_id, event_created_at)` considered and deferred until a real query needs it — the plan's single-column indexes stand.
- Post-review remediations landed in this PR (D-021): UTF-8 validity joined the storability contract (`StorableString` shared predicate, `JSON::GeneratorError` handled row-scoped, scrub repairs invalid bytes); in-page repeats parse once; `structured_skipped` warns/counts settle after the raw insert so they never contradict persistence; transient per-row failures retry unscrubbed. The Tasks line's "structured upsert" is `ON CONFLICT DO NOTHING` (insert-ignore): existing structured rows are never rewritten (divergence tradeoff documented in D-021).
