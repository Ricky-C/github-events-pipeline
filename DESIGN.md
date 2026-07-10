# Design Brief — GitHub Push Event Ingestion

*Depth lives in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); the full decision log with costs stated is [docs/DECISIONS.md](docs/DECISIONS.md) (referenced below as D-NNN).*

## How I Understood the Problem

This is an internal, unattended service for an engineering-analytics team: poll GitHub's public Events API without authentication, keep the PushEvents, persist raw and structured data in PostgreSQL, and enrich events with actor and repository detail. For an internal pipeline, predictability under failure matters more than feature count. The real design problem is the rate budget — 60 unauthenticated requests per hour per IP, shared between polling and enrichment fan-out — and every decision below traces back to it. The downstream consumers are analysts, so structured, plain-SQL-queryable storage is the product; ingestion is the means.

## Architecture

```
api.github.com ◄──── ingester (poll loop) ──┐        ┌── worker (Solid Queue)
     ▲                                      │  both  │        │
     └──────────────────────────────────────┼─ via ──┘        │
                                            │ GithubClient    │
                                            ▼                 ▼
                        PostgreSQL: raw_events · push_events · actors
                          · repositories · rate_limit_states · queue
```

Two processes, one datastore, one HTTP chokepoint. The ingester polls `/events`; a Solid Queue worker enriches actors and repositories. Every request goes through one `GithubClient`, which owns ETags, `X-Poll-Interval`, and the rate budget — mirrored in Postgres, so both processes and every restart see a single budget. Raw jsonb and structured columns are written in one transaction, and enrichment is additive: push events are queryable with ids and logins before, or without, enrichment.

## Rate Limits & Durability

The folklore says conditional requests are free. I measured instead of assuming: on the unauthenticated tier, a 304 decrements `X-RateLimit-Remaining` — GitHub's current documentation grants the exemption only to requests carrying an `Authorization` header (D-017, D-022). That measurement set the whole budget policy. Honoring the served 60s `X-Poll-Interval` would spend the entire budget on polling, so polling is capped by a 120s floor (~30 req/hr), and enrichment spends what remains down to a reserve of 5, parking — rescheduled to the reset with jitter — rather than failing when the budget is exhausted. Conditional requests stay for correctness (a 304 skips re-persisting an unchanged body), not for budget. Enrichment fan-out is collapsed two ways: a 24-hour TTL on fetched entities (the firehose is dominated by repeat actors, bots especially) and in-flight dedup via an atomic claim, so steady-state spend converges on unique entities per day (D-005, D-023).

Durability assumes every operation may be interrupted and replayed. Externally-keyed writes are upserts against unique indexes; raw and structured rows share one transaction, because the client's ETag advances past a page the moment it parses — a torn write would be permanent. Job state lives in Postgres, so a worker restart resumes rather than forgets. Delivery is at-least-once, not exactly-once: a graceful restart re-runs a job at the cost of one idempotent re-fetch, and a hard-killed worker's claim is dead-lettered by Solid Queue, which a recurring sweep reconciles (D-024). Failure behavior is classified, not generic: network failures are absorbed as values and retried with backoff, rate limits park to the reset (clamped to the one-hour window — a header asking for longer is a desynced shard, not an instruction), 404s are terminal and never retried, and database-shaped errors back off for ~20 minutes before the process deliberately exits nonzero so compose's restart policy recycles it (D-026).

## Key Tradeoffs & Assumptions

- **Solid Queue over Sidekiq/Redis** — one stateful dependency; queue durability equals database durability. Cost: lower throughput ceiling, which is irrelevant here — the rate limit is the ceiling (D-002).
- **Polling over webhooks** — runs unattended with zero inbound surface. Cost: the public feed is a sliding window, so completeness is bounded; accepted for activity analysis (D-003).
- **Raw jsonb and structured columns, both** — plain-SQL analytics with honest indexes, raw retained for audit and replay. Cost: roughly 2× storage per event (D-004).
- **One page per poll** — ~1 request per interval instead of up to 10; the dataset is an explicit sample, which serves the goal (D-009).
- **24h enrichment staleness, one worker thread** — serialized, predictable spend. Cost: enrichment lags up to a day and backlog drains slowly under budget pressure — parked, not lost, by design (D-005).

## What I Tested and Why

I tested the decision logic, not the framework: budget arithmetic at the reserve boundary, the claim/dedup state machine (on the real queue adapter, where atomicity is the property), parsing against a ~33-case malformed matrix — malformed input is a first-class case for a pipeline that eats untrusted internet JSON — the SSRF guard's deny table, and the poll loop's escalation policy. Fixtures are captured real GitHub responses, so contract specs assert against real bytes (the weak-ETag echo test uses the actual captured ETag); failure responses are synthesized, since capturing a real 403 means deliberately burning the shared budget (D-015). Two integration specs close the chain: a full poll→persist→enqueue cycle asserting rows, jobs, and the log narrative together, and a restart-safety spec that runs the pipeline twice over identical fixtures and asserts identical database state on every column a reader consumes (the upserts refresh two bookkeeping timestamps by design). I deliberately skipped exhaustive model specs — asserting validations the parser already guarantees would test Rails, not this system.

## What I Intentionally Did Not Build

- **Extension C (object storage)** — a new dependency that doesn't serve the analysis use case. Production path: age raw jsonb out to object storage; cache avatars under content-hash keys (D-007).
- **Auth tokens** — an explicit exercise constraint, honored strictly; no token support even for convenience. Production path: one org token raises the ceiling to 5,000 req/hr and makes 304s free (D-022), dissolving most of this design's scarcity engineering.
- **Webhooks** — require a publicly reachable endpoint; polling fits "runs unattended locally". Production path: webhooks as the primary feed, this poller as backfill.
- **A query/read API** — the exercise asks for queryable storage, and analysts get SQL. Production path: a read-only reporting layer over the same tables.
- **Metrics endpoint** — structured logs are the operator UI at this scale. Production path: Prometheus counters mirroring the existing log events.
- **Multi-instance coordination** — single-node by design; the budget is per-IP, so horizontal scale buys nothing without more egress IPs or authentication. Production path: authenticate first (see above), then shard entities across workers — the durable queue already supports it.
