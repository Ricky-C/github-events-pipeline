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
- [x] `docker compose run --rm test` green from clean checkout *(executed 2026-07-09 in a fresh clone with a `--no-cache --pull` image build: 315 examples, 0 failures)*
- [x] "What I tested and why" section drafted (goes in brief + PR body): tested the *decision logic* (budget, dedup, parsing) not the framework; skipped exhaustive model specs deliberately *(DESIGN.md § What I Tested and Why; reused in the PR body)*

## Tasks — Design Brief (`DESIGN.md`, 1–2 pages hard cap)

- [x] How I understood the problem (2–3 sentences; the rate budget as the central constraint; unattended internal service for an EdTech org's engineering analytics)
- [x] Architecture (small diagram + component paragraph, lifted from docs/ARCHITECTURE.md)
- [x] Key tradeoffs & assumptions (from docs/DECISIONS.md: Solid Queue over Sidekiq/Redis, polling over webhooks, columns over JSON views, 24h TTL, concurrency=1 worker)
- [x] Rate limits & durability (Extension A + B narrative: ETag/304s, X-Poll-Interval, budget gate + parking; unique-index idempotency, transactional writes, Postgres-backed queue restart safety)
- [x] What I intentionally did not build (from docs/PLAN.md's out-of-scope list, with one-line reasons)
- [x] Length check: ≤2 pages. Cut ruthlessly; link to docs/ARCHITECTURE.md for depth. *(999 words including the diagram; a "What I Tested and Why" section was added so Extension D has a brief-section anchor, per the exit criterion's traceability requirement)*

## Tasks — README Final Pass

- [x] All three reviewer commands re-verified from a genuinely clean checkout (fresh clone, pruned Docker cache) *(executed 2026-07-09: fresh `git clone` to a scratch dir, `docker compose build --no-cache --pull` — a scoped from-scratch build rather than a global cache prune, same guarantee without evicting unrelated images — then `run --rm test` (315/0), then `up` against the live API: cycle 1 `poll.cycle status=ok events_seen=30 push_events_new=29 budget_remaining=59`, worker drained 54 enrichments and parked at the reserve (`enrich.parked reason=budget run_at=<next window>`), cycle 2 `push_events_new=28 budget_remaining=4`; README verify SQL run verbatim: raw/push 29 → 57 across the two cycles, actors 29 fetched / 24 enqueued, repositories 25 / 31 — every state healthy, zero error/fatal lines)*
- [x] "How to verify it's working" complete with real log excerpts and SQL *(filled from real runs in Phase 4; the structure-lock comment above it was the last placeholder and is now removed)*
- [x] Doc map + link to DESIGN.md at top *(README line 5 carries brief/deep-dive/plan links; project-structure table maps the rest)*
- [x] Spell-check, link-check, remove any TODO/placeholder text project-wide *(hunspell over README/DESIGN/docs — only jargon and identifiers flagged; every relative markdown link resolves; grep for TODO/FIXME/TBD/HTML comments is clean)*

## Exit Criteria

- [x] A reviewer with only the README can start, verify, and test the system in <10 minutes *(rehearsed literally in the clean-checkout run above: the README's three commands, executed verbatim in a fresh clone, produced a green suite and the documented log lines + SQL counts; the from-scratch image build is the long pole at ~4 minutes)*
- [x] DESIGN.md covers all five required brief topics in ≤2 pages *(999 words including the diagram; a sixth "What I Tested and Why" section anchors Extension D)*
- [x] Extensions A, B, D each traceable: brief section ↔ code ↔ tests *(A: § Rate Limits & Durability ↔ GithubClient/Budget/RateWindow + IngestRunner cadence ↔ poll_events/budget/rate_window/ingest_runner specs · B: same section ↔ upserts, shared transaction, Enrichable claim, EnrichmentSweep ↔ enrichable/concurrency/sweep specs + the restart-safety spec · D: § What I Tested and Why ↔ spec/ ↔ spec/integration/ingest_cycle_spec.rb)*
- [ ] Final squash-merge; repo link ready to email with subject "Full Stack Developer Candidate — Enrique Caballero" *(reviewer's step, after PR review)*

## Out of Scope

Extension C (recorded with rationale in the brief). New features of any kind — this phase adds tests and words only.

## Notes / Discovered Work

- **The unit-coverage task was pure confirmation** — all four named areas were already covered by Phases 1–4's specs (the review remediations kept forcing coverage ahead of this phase's schedule). The phase's only new code is the one integration spec file; everything else was writing, as the objective predicted.
- **No dedicated `UrlGuard` unit spec, deliberately**: the 11-row allow/deny table in `fetch_resource_spec.rb` exercises the guard through the seam production uses, and a second copy of the table is exactly the policy-drift D-025 exists to prevent. Recorded here rather than in a new D-entry — it's an application of D-025, not a new decision.
- **The stale-image gotcha bit once more**: the first `docker compose run --rm test` after adding the new spec file reported 311 examples — the image bakes source at build time, so a new file needs `docker compose build` first. Known since Phase 0; noting the recurrence because a reviewer adding a spec will hit it too.
- **Live clean-checkout run doubled as a budget-arc observation**: from a cold boot with a full window, the worker drained 54 enrichment fetches in ~15s (concurrency 1, ~250ms/fetch), hit the reserve, and parked the remaining backlog to the next window — with polling continuing from the reserve (`budget_remaining=4` on cycle 2). The D-006/D-022 priority ordering, observed end-to-end from nothing.
