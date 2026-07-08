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

---

_Append new entries below as D-00N during each phase._
