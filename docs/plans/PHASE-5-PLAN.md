# Phase 5 — Extensions + Design Brief

**Issue:** #6 · **Branch:** `extensions-and-brief`

## Objective

Extension D (testing strategy) implemented; Extensions A & B — already structural in Phases 1–3 — articulated; design brief and README finalized. This phase is mostly writing, and the writing is a scored deliverable.

## Tasks — Extension D: Testing Strategy

- [x] Unit coverage confirmed/extended — confirmed; all four areas were already covered, no gaps to extend:
  - [x] `GithubClient`: ETag/304 handling, poll-interval respect, budget accounting, 403 sleep math *(poll_events_spec.rb — weak-ETag echo, header-less vs header-carrying 304s, the unstorable-ETag matrix; budget_spec.rb — reserve boundary + stale-mirror escape; rate_window_spec.rb — clamp/precedence sleep math; the 120s floor is the runner's policy and lives in ingest_runner_spec.rb § cadence policy)*
  - [x] TTL cache gate + in-flight dedup logic *(enrichable_spec.rb — claim wins at most once per window; enrichable_concurrency_spec.rb — claim/enqueue atomicity on the real adapter; enrichment_queuer_spec.rb — cache_hit / in_flight behavior)*
  - [x] `PushEventParser`: happy path + malformed matrix *(push_event_parser_spec.rb — data-driven matrix, ~33 malformed shapes incl. the created_at sub-matrix and the payload_scrubbed rebuild guard)*
  - [x] SSRF URL guard (allow/deny table) *(fetch_resource_spec.rb — 11-row deny table asserting `:rejected_url` + zero requests, plus bracket normalization and redirect re-guarding; enrichment_queuer_spec.rb — hostile-URL fixture at ingest. Deliberately no dedicated url_guard_spec: the table already exercises the guard through the seam production uses, and a second copy of the table is the drift D-025 exists to prevent)*
- [x] Integration spec: full ingest cycle against WebMock'd fixtures (captured real `/events` JSON) → asserts raw rows, structured rows, enqueued jobs, log events *(spec/integration/ingest_cycle_spec.rb — real GithubClient + EventIngester + EnrichmentQueuer through `IngestRunner#run(once: true)`; every count derived from the fixture, never a literal)*
- [x] One restart-safety spec: run ingestion twice over identical fixtures → identical DB state *(same file — two freshly composed runners, snapshot equality across raw/structured/entities/rate-mirror/jobs excluding the upsert-bumped timestamps (D-024), plus non-vacuousness pins: run 2 really sent If-None-Match, deduped the full page, and skipped every claim as in_flight)*
- [ ] `docker compose run --rm test` green from clean checkout
- [x] "What I tested and why" section drafted (goes in brief + PR body): tested the *decision logic* (budget, dedup, parsing) not the framework; skipped exhaustive model specs deliberately *(DESIGN.md § What I Tested and Why; reused in the PR body)*

## Tasks — Design Brief (`DESIGN.md`, 1–2 pages hard cap)

- [x] How I understood the problem (2–3 sentences; the rate budget as the central constraint; unattended internal service for an EdTech org's engineering analytics)
- [x] Architecture (small diagram + component paragraph, lifted from docs/ARCHITECTURE.md)
- [x] Key tradeoffs & assumptions (from docs/DECISIONS.md: Solid Queue over Sidekiq/Redis, polling over webhooks, columns over JSON views, 24h TTL, concurrency=1 worker)
- [x] Rate limits & durability (Extension A + B narrative: ETag/304s, X-Poll-Interval, budget gate + parking; unique-index idempotency, transactional writes, Postgres-backed queue restart safety)
- [x] What I intentionally did not build (from docs/PLAN.md's out-of-scope list, with one-line reasons)
- [x] Length check: ≤2 pages. Cut ruthlessly; link to docs/ARCHITECTURE.md for depth. *(999 words including the diagram; a "What I Tested and Why" section was added so Extension D has a brief-section anchor, per the exit criterion's traceability requirement)*

## Tasks — README Final Pass

- [ ] All three reviewer commands re-verified from a genuinely clean checkout (fresh clone, pruned Docker cache)
- [x] "How to verify it's working" complete with real log excerpts and SQL *(filled from real runs in Phase 4; the structure-lock comment above it was the last placeholder and is now removed)*
- [x] Doc map + link to DESIGN.md at top *(README line 5 carries brief/deep-dive/plan links; project-structure table maps the rest)*
- [x] Spell-check, link-check, remove any TODO/placeholder text project-wide *(hunspell over README/DESIGN/docs — only jargon and identifiers flagged; every relative markdown link resolves; grep for TODO/FIXME/TBD/HTML comments is clean)*

## Exit Criteria

- [ ] A reviewer with only the README can start, verify, and test the system in <10 minutes
- [ ] DESIGN.md covers all five required brief topics in ≤2 pages
- [ ] Extensions A, B, D each traceable: brief section ↔ code ↔ tests
- [ ] Final squash-merge; repo link ready to email with subject "Full Stack Developer Candidate — Enrique Caballero"

## Out of Scope

Extension C (recorded with rationale in the brief). New features of any kind — this phase adds tests and words only.

## Notes / Discovered Work

_(append during the phase)_
