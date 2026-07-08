# Phase 5 — Extensions + Design Brief

**Issue:** #6 · **Branch:** `extensions-and-brief`

## Objective

Extension D (testing strategy) implemented; Extensions A & B — already structural in Phases 1–3 — articulated; design brief and README finalized. This phase is mostly writing, and the writing is a scored deliverable.

## Tasks — Extension D: Testing Strategy

- [ ] Unit coverage confirmed/extended:
  - [ ] `GithubClient`: ETag/304 handling, poll-interval respect, budget accounting, 403 sleep math
  - [ ] TTL cache gate + in-flight dedup logic
  - [ ] `PushEventParser`: happy path + malformed matrix
  - [ ] SSRF URL guard (allow/deny table)
- [ ] Integration spec: full ingest cycle against WebMock'd fixtures (captured real `/events` JSON) → asserts raw rows, structured rows, enqueued jobs, log events
- [ ] One restart-safety spec: run ingestion twice over identical fixtures → identical DB state
- [ ] `docker compose run --rm test` green from clean checkout
- [ ] "What I tested and why" section drafted (goes in brief + PR body): tested the *decision logic* (budget, dedup, parsing) not the framework; skipped exhaustive model specs deliberately

## Tasks — Design Brief (`DESIGN.md`, 1–2 pages hard cap)

- [ ] How I understood the problem (2–3 sentences; the rate budget as the central constraint; unattended internal service for an EdTech org's engineering analytics)
- [ ] Architecture (small diagram + component paragraph, lifted from docs/ARCHITECTURE.md)
- [ ] Key tradeoffs & assumptions (from docs/DECISIONS.md: Solid Queue over Sidekiq/Redis, polling over webhooks, columns over JSON views, 24h TTL, concurrency=1 worker)
- [ ] Rate limits & durability (Extension A + B narrative: ETag/304s, X-Poll-Interval, budget gate + parking; unique-index idempotency, transactional writes, Postgres-backed queue restart safety)
- [ ] What I intentionally did not build (from docs/PLAN.md's out-of-scope list, with one-line reasons)
- [ ] Length check: ≤2 pages. Cut ruthlessly; link to docs/ARCHITECTURE.md for depth.

## Tasks — README Final Pass

- [ ] All three reviewer commands re-verified from a genuinely clean checkout (fresh clone, pruned Docker cache)
- [ ] "How to verify it's working" complete with real log excerpts and SQL
- [ ] Doc map + link to DESIGN.md at top
- [ ] Spell-check, link-check, remove any TODO/placeholder text project-wide

## Exit Criteria

- [ ] A reviewer with only the README can start, verify, and test the system in <10 minutes
- [ ] DESIGN.md covers all five required brief topics in ≤2 pages
- [ ] Extensions A, B, D each traceable: brief section ↔ code ↔ tests
- [ ] Final squash-merge; repo link ready to email with subject "Full Stack Developer Candidate — Enrique Caballero"

## Out of Scope

Extension C (recorded with rationale in the brief). New features of any kind — this phase adds tests and words only.

## Notes / Discovered Work

_(append during the phase)_
