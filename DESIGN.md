# Design Brief — GitHub Push Event Ingestion

<!--
DELIVERABLE. 1–2 pages HARD CAP. Finalized in Phase 5.
Voice: first person, decisions and reasons, no feature-listing.
Each section pulls from: docs/DECISIONS.md (tradeoffs), docs/ARCHITECTURE.md (design),
docs/PLAN.md out-of-scope list (what I didn't build).
-->

## How I Understood the Problem

<!-- 3–4 sentences.
- Internal, unattended service: predictability under failure > feature count
- The real design problem: 60 unauthenticated req/hr shared between polling and
  enrichment fan-out — every decision below traces to this constraint
- Downstream consumers are analysts: structured, plain-SQL-queryable storage is
  the product; ingestion is the means -->

## Architecture

<!-- Small diagram (from docs/ARCHITECTURE.md, simplified) + one paragraph:
ingester → GithubClient (owns budget/ETags) → Postgres ← Solid Queue worker.
Two processes, one datastore, one HTTP chokepoint. -->

## Rate Limits & Durability

<!-- The Extension A + B narrative, ~one-third of the brief:
- Conditional requests: 304s cost zero budget → observation is nearly free
- X-Poll-Interval compliance; jittered sleeps on 403/429
- Budget policy: polling priority, enrichment takes remainder, parks at reserve
- Fan-out: 24h TTL + in-flight dedup collapses fetches to unique entities/day
- Durability: unique-index upserts (replay-safe), raw+structured in one
  transaction, Postgres-backed queue (restart = resume), bounded growth -->

## Key Tradeoffs & Assumptions

<!-- 4–5 from docs/DECISIONS.md, one line each with the cost stated honestly:
D-002 Solid Queue over Sidekiq/Redis · D-003 polling over webhooks (bounded
completeness accepted) · D-004 raw+structured dual write · D-005 24h staleness
accepted · D-006 budget policy -->

## What I Intentionally Did Not Build

<!-- From docs/PLAN.md, one line + reason each:
Extension C (object storage) · auth tokens (constraint) · webhooks (no inbound
surface) · query API (storage was the ask) · metrics endpoint · multi-instance
coordination. Close with the production path for each in a sentence. -->
