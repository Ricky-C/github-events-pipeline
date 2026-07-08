# DECISIONS.md

ADR-lite log. One entry per consequential decision, appended when made. This file is the raw material for the design brief's "tradeoffs and assumptions" and "what I did not build" sections — write entries well once, reuse twice.

Format: **Context → Decision → Consequences (incl. what we gave up)**

---

## D-001: Rails 8, API-only mode

**Context:** Exercise prefers Rails; alternatives (Sinatra, plain Ruby + Sequel) would be lighter for a headless pipeline.
**Decision:** Rails 8 API-only.
**Consequences:** Migrations, ActiveRecord upserts, Solid Queue, and testing conventions for free; team-alignment with the reviewer's stack. Cost: heavier boot than a script — acceptable for a long-running service. Gave up: minimalism bragging rights.

## D-002: Solid Queue over Sidekiq/Redis

**Context:** Enrichment needs background, durable, restartable jobs. Sidekiq is the Rails default habit but requires Redis.
**Decision:** Solid Queue (Rails 8 default, Postgres-backed).
**Consequences:** Single stateful dependency; job durability = database durability; restart safety and the "system of record: PostgreSQL" requirement satisfied by one system. Cost: lower max throughput than Redis-backed queues — irrelevant here, since the rate limit (60/hr) is the throughput ceiling, not the queue.

## D-003: Polling with conditional requests, not webhooks

**Context:** Webhooks are the "real" production answer for GitHub activity but require a publicly reachable endpoint and repo-level configuration.
**Decision:** Poll `/events` with `If-None-Match`; honor `X-Poll-Interval`.
**Consequences:** Runs unattended on a laptop with zero inbound surface; 304s make idle polling free against the rate budget. Cost: bounded completeness — the public events feed is a sliding window, so quiet-period events between polls can be missed. Acceptable: the goal is activity analysis, not exhaustive capture. Noted in brief.

## D-004: Raw jsonb + structured columns (both), rebuildable one-way

**Context:** Story 2 demands queryability without JSON parsing; audit needs raw retention.
**Decision:** `raw_events` (jsonb, append-only) + `push_events` (real columns, real indexes), written in one transaction; structured is derivable from raw.
**Consequences:** Plain-SQL analytics, honest indexes, replay/backfill capability if the parser improves. Cost: ~2x storage per event — cheap at this scale, and raw could later age out to object storage (consciously deferred, see D-007).

## D-005: 24h enrichment TTL + in-flight dedup, worker concurrency = 1

**Context:** The public firehose repeats actors heavily (bots dominate); every duplicate fetch wastes irreplaceable budget.
**Decision:** Skip enrichment if `fetched_at` < 24h; dedup queued jobs per (type, github_id); single worker thread.
**Consequences:** Fan-out collapses to roughly unique-entities-per-day; budget spend is serialized and predictable. Cost: enrichment data can be up to 24h stale (fine for trend analysis) and backlog drains slowly under budget pressure (by design — parked, not lost).

## D-006: Budget policy — polling has priority, enrichment takes the remainder

**Context:** One 60/hr budget, two consumers.
**Decision:** Reserve budget for the poll cadence (cheap: 304s are free, real polls ~1/interval); enrichment spends down to a small reserve, then parks until `X-RateLimit-Reset`.
**Consequences:** The system never goes blind — observation continues even when enrichment is starved. Degradation is graceful and self-healing at window reset.

## D-007: Extension C (object storage) intentionally not built

**Context:** Optional extension; avatars/raw-events-to-S3 would add MinIO to compose.
**Decision:** Skip. Persist `avatar_url` references only.
**Consequences:** One fewer dependency, smaller review surface, compose stays trivially bootable. The brief documents the production path (age raw jsonb out to object storage; cache avatars with content-hash keys and TTL) to show the thinking without the plumbing.

## D-008: SSRF guard on payload-provided URLs

**Context:** Story 3 says to use URLs *from the event payload* — i.e., fetch targets arrive inside untrusted input.
**Decision:** Fetch only `https://api.github.com/...`; reject everything else with a security log.
**Consequences:** Payload mutation can't redirect the service at internal targets. Cost: none. (This is the kind of requirement-reading the exercise rewards.)

## D-009: Single page per poll — pagination intentionally skipped

**Context:** `/events` serves up to 10 pages × ~30 events; the feed is a sliding window regardless, so completeness is unattainable by design.
**Decision:** Fetch page 1 only, once per poll interval.
**Consequences:** Budget spend is ~1 request/interval instead of up to 10; the dataset is an explicit *sample* of public activity, which serves the stated goal (analyzing usage/behavior over time) fine. Stated plainly in the brief so it reads as judgment, not oversight.

## D-010: RAILS_ENV=development in containers; Solid Queue forced and pointed at the primary DB

**Context:** Production env demands SECRET_KEY_BASE and credentials ceremony (we have zero secrets by design); development env silently defaults Active Job to the async adapter and generates Solid Queue against a separate queue database in Rails 8.
**Decision:** Run development env for zero-secret boot, but configure explicitly what env defaults would get wrong: `queue_adapter = :solid_queue`, Solid Queue on the **primary** database, log level info with JSON-only formatting.
**Consequences:** Clean-checkout boot with no key generation steps; queue durability = database durability (one system of record, per the exercise); no async-adapter false positives during development. Cost: dev-env defaults must be consciously overridden — captured as explicit Phase 0/3 tasks so it can't be forgotten.

## D-011: No HTTP server, no credentials, no production environment

**Context:** `rails new` ships puma, encrypted credentials + master.key, and a production env config. This service has zero inbound surface (docs/THREAT-MODEL.md) and zero secrets by design; containers run the development env (D-010).
**Decision:** Delete all three at scaffold time: no puma/`config/puma.rb`, no `credentials.yml.enc`/`master.key`, no `config/environments/production.rb` or database.yml production section. Unused railties (mailer, mailbox, text, storage, cable) also removed. Review cleanup extended the trim: `config.ru`, the `/up` route, the CORS/inflections/locale scaffold files, the no-op `bin/docker-entrypoint`, and stale storage/credentials ignore rules are gone too (key-file ignore rules kept as defense-in-depth).
**Consequences:** The repo contains nothing that can leak and nothing listening; the "no secrets" claim is verifiable by absence, not policy. Cost: a future inbound surface (health endpoint, metrics) would need puma reintroduced — one Gemfile line, recorded here so it reads as a decision, not an accident.

## D-012: Discrete PG* connection vars instead of DATABASE_URL

**Context:** Phase 0 code review found two failure modes in composing a `DATABASE_URL` from `${POSTGRES_PASSWORD}`: reserved characters in an overridden password break URI parsing (while the db itself accepts the password), and the database name was pinned in the URL so `RAILS_ENV` alone didn't select the database.
**Decision:** Pass `PGHOST`/`PGUSER`/`PGPASSWORD` discretely; `config/database.yml` reads them explicitly and owns the env→database mapping.
**Consequences:** Passwords never travel through URL parsing (any characters work); `RAILS_ENV` is the single switch between dev and test databases; compose and CI share the same mechanism. Cost: no single copy-pasteable connection URL — acceptable, nothing external consumes one. The related caveat that the postgres image bakes the password into the volume at first initdb is now documented in compose and `.env.example`.

## D-013: Net::HTTP over an HTTP-client gem

**Context:** Phase 1 needs an HTTP transport for `GithubClient`. Faraday/HTTParty are the habitual choices.
**Decision:** Stdlib `Net::HTTP`, wrapped entirely inside the one client class.
**Consequences:** Zero new supply-chain surface (docs/THREAT-MODEL.md), no middleware indirection for a client that talks to exactly one host with strict transport limits, and WebMock intercepts it natively. The 5 MB cap is enforced by streaming `read_body` and aborting mid-read. Gave up: nicer ergonomics if the API surface ever grows — acceptable, the spec forbids it growing.

## D-014: rate_limit_states singleton via guard column + partial upsert

**Context:** The shared budget mirror must be one logical row, written by two processes, where every write may be a retry.
**Decision:** A `singleton_guard` column fixed at 0 with a unique index; all writes are single-statement `upsert` (`ON CONFLICT DO UPDATE`) of only the columns observed in that response.
**Consequences:** The singleton is a database constraint, not a convention; there is no read-modify-write to race; concurrent writers are last-write-wins, which the client spec explicitly accepts (D-006 lineage) because headers self-correct on the next real response. Partial updates mean a resource fetch can never clobber the `/events` ETag, and a header-less response persists nothing.

## D-015: Fixture strategy — capture the happy paths once, synthesize the failures

**Context:** Tests must never touch the live API (Golden Rule 8), but realistic fixtures matter — GitHub's weak ETags (`W/"..."`) are exactly the kind of detail hand-written stubs get wrong.
**Decision:** One live capture session: `curl -sS -i --http1.1` of a real 200 and a real 304 (ETag replay inside GitHub's cache window), committed verbatim as `.http` files and parsed by a small spec helper (chunked-encoding headers stripped at load — raw replay of chunked captures breaks WebMock). Error responses (403/429/404/5xx/malformed/oversized) are synthesized in spec helpers, since capturing them live would mean burning the budget to zero on purpose.
**Consequences:** Contract specs assert against real GitHub bytes (the weak-ETag echo test uses the actual captured ETag); the capture cost 1 budget request total. The 304 capture also produced D-017's observation.

## D-016: One-shot ingestion via runner argument in the compose command

**Context:** The `ingest` service needs one-shot mode; the phase plan allowed an env flag or an argument.
**Decision:** `IngestRunner.new.run(once: true)` spelled out in the compose `command:`.
**Consequences:** The mode is visible exactly where the service is defined — no hidden env coupling between compose and app code. One-shot mode also skips signal traps and lets exceptions propagate, so verification runs fail loudly instead of backing off silently. Since the client returns failures as Result values rather than exceptions, one-shot mode also raises `IngestRunner::PollFailed` for any poll that isn't `:ok`/`:not_modified` — those two are the only zero-exit outcomes, so a rate-limited or erroring verification run deliberately exits nonzero (Phase 1 review fix).

## D-017: Observed — a real 304 arrived with a decremented X-RateLimit-Remaining

**Context:** The architecture leans on GitHub's documented behavior that conditional requests answered 304 don't count against the rate limit. During the Phase 1 fixture capture, the 200 returned `remaining: 59` and the immediate 304 replay returned `remaining: 58` — the conditional request appears to have been counted (single observation; could also be another client sharing the egress IP in that second).
**Decision:** Build to headers-as-source-of-truth rather than to documentation: the client mirrors whatever rate headers each response carries (including 304s), and the contract-test checklist line was adjusted from "304 → remaining unchanged" to "header-less 304 → unchanged; 304 rate headers → mirrored". Verify the trajectory across several 304s during end-of-phase verification runs.
**Consequences:** The persisted budget is correct either way — no code depends on 304s being free. If the observation holds, the *design margin* changes: polling at the 60s `X-Poll-Interval` would consume the entire 60/hr budget, leaving nothing for Phase 3 enrichment. Mitigation would be policy, not architecture (stretch the effective poll interval; the cadence already lives in one place, `IngestRunner`). Flagged for re-measurement before Phase 3 sets `ENRICHMENT_RESERVE` policy.

## D-018: NUL-bearing payloads are scrubbed and marked, not dropped

**Context:** PostgreSQL `jsonb` cannot store NUL (U+0000) anywhere in a document, so a PushEvent whose payload contains one defeats byte-perfect raw persistence — and a single such row raised out of the whole-page `insert_all`, costing every valid event on the page (Phase 1 review finding).
**Decision:** The batch insert stays the fast path; on `StatementInvalid` the page falls back to savepointed per-row inserts, and a refused row is retried once with NUL stripped from every payload string (keys included) plus a top-level `"payload_scrubbed": true` marker and an `ingest.malformed` warn. Rows refused even after scrubbing count toward `malformed_skipped`; if *every* row is refused, the original batch error re-raises — an all-rows failure is a database problem, not a payload problem. A NUL inside the event *id* is rejected upfront as `invalid_event_id` instead: scrubbing an identifier would forge a new one.
**Consequences:** Raw fidelity is knowingly compromised for exactly the rows PG cannot store verbatim — detectable via the marker key and the warn log, and a NUL payload could never round-trip through `jsonb` anyway (the alternative was losing the row entirely). Savepoints (`requires_new: true`) keep a refused statement from aborting any wrapping transaction, including the transactional test suite. Cost: a poisoned page pays one failed batch statement plus one statement per row.

---

_Append new entries below as D-00N during each phase._
