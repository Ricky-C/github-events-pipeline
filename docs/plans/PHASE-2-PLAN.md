# Phase 2 — Story 2: Persist Raw and Structured Data

**Issue:** #3 · **Branch:** `story-2-structured-persistence`

## Story

> As an analyst, I want key push attributes stored in a structured form so that I can query them without parsing raw JSON.

## Acceptance Criteria (from exercise, verbatim)

- [ ] Raw event payloads are retained for audit/debug purposes *(done in Phase 1 — `raw_events`)*
- [ ] Queryable without JSON parsing: repository identifier, push identifier, ref, head, before
- [ ] Data modeling choices are documented at a high level

## Tasks

- [ ] `push_events` migration:
  - `github_event_id` (string, unique index, FK-by-convention to `raw_events`)
  - `push_id` (bigint, indexed), `ref`, `head_sha`, `before_sha`
  - `repository_github_id` (bigint, indexed), `repository_name`
  - `actor_github_id` (bigint, indexed), `actor_login`
  - `event_created_at` (indexed — "over time" analysis is the stated business goal)
- [ ] `PushEventParser` service: raw payload → attribute hash; returns a result object (`ok` / `malformed` + reason); length-validates string fields (see docs/THREAT-MODEL.md)
- [ ] Ingest pipeline: raw insert + structured insert in **one transaction**; structured upsert keyed on `github_event_id`
- [ ] Malformed-payload path: raw row always persists; structured row skipped; single warn-level log with reason and event id (graceful — no raise)
- [ ] Data-modeling rationale written into PR body and `docs/DECISIONS.md` (why columns-not-views, why keep raw + structured, index choices)

## Exit Criteria

- [ ] The five required fields answerable via plain SQL, no JSON operators
- [ ] A deliberately mangled fixture payload ingests without error: raw persisted, structured skipped, warning logged
- [ ] Re-running ingestion over the same events yields zero structured duplicates
- [ ] Parser unit specs cover happy path + ≥3 malformed shapes (missing keys, wrong types, oversized strings)

## Out of Scope

Actor/repo enrichment tables (Phase 3) — this phase only extracts what's already in the push payload.

## Notes / Discovered Work

_(append during the phase)_
