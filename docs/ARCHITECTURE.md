# ARCHITECTURE.md

Living design reference. The design brief (`DESIGN.md`, repo root) is the 2-page summary; this is the depth.

## System Overview

```
                          ┌──────────────────────────────────────────┐
                          │                Docker Compose            │
                          │                                          │
  api.github.com  ◄───────┤  ┌──────────┐        ┌──────────┐        │
  /events (poll)          │  │ ingester │        │  worker  │        │
  /users/:id      ◄───────┤  │ (loop)   │        │ (Solid   │        │
  /repos/:o/:r    ◄───────┤  └────┬─────┘        │  Queue)  │        │
                          │       │              └────┬─────┘        │
                          │       │   both via        │              │
                          │       │   GithubClient    │              │
                          │       ▼                   ▼              │
                          │  ┌──────────────────────────────┐        │
                          │  │         PostgreSQL           │        │
                          │  │ raw_events · push_events     │        │
                          │  │ actors · repositories        │        │
                          │  │ rate_limit_states · queue    │        │
                          │  └──────────────────────────────┘        │
                          └──────────────────────────────────────────┘
```

Two processes, one datastore. The **ingester** polls; the **worker** enriches. Both route every HTTP request through `GithubClient`, which owns the shared rate budget (state persisted in Postgres so both processes and restarts see one budget).

## The Central Constraint: 60 req/hr

Unauthenticated GitHub API = 60 requests/hour/IP, shared across polling **and** enrichment. Naive design (poll every 10s + 2 enrichment calls per push) exhausts it in minutes. Controls, in order of leverage:

1. **Conditional requests.** `/events` is polled with `If-None-Match: <etag>`. A `304 Not Modified` costs **zero** rate-limit budget. Per-record ETags are also stored for actor/repo re-fetches.
2. **`X-Poll-Interval` compliance.** GitHub states the minimum poll interval in a response header; the ingester never polls faster.
3. **Request budget.** `GithubClient` persists `X-RateLimit-Remaining`/`X-RateLimit-Reset`. Policy: polling has priority (it's ~1 req/interval and 304s are free); enrichment spends what remains down to a small reserve. At exhaustion, enrichment jobs **park** (reschedule to `reset_at` + jitter) rather than fail.
4. **Fan-out control.** Actor/repo fetches are deduplicated two ways: a 24h TTL on `fetched_at` (the firehose is dominated by repeat actors — bots especially), and in-flight job dedup keyed on (type, github_id).
5. **Worker concurrency = 1.** Serializes budget spend; no thundering herd at reset time. Throughput ceiling is the rate limit anyway, so concurrency buys nothing.

Degradation mode under sustained limiting: ingestion keeps observing via free 304s; enrichment backlog queues durably in Postgres and drains each budget window. Nothing is lost, nothing crashes.

## Data Model

| Table | Purpose | Key constraints |
|---|---|---|
| `raw_events` | Audit-grade raw payloads (jsonb) | `github_event_id` unique |
| `push_events` | Structured, queryable push attributes | `github_event_id` unique; indexes on `push_id`, `repository_github_id`, `actor_github_id`, `event_created_at` |
| `actors` | Contributor identity + enrichment | `github_id` unique; `etag`, `fetched_at`, `fetch_status` |
| `repositories` | Repo identity + enrichment | `github_id` unique; same enrichment metadata |
| `rate_limit_states` | Shared budget + last poll ETag | single logical row |
| Solid Queue tables | Durable job state | framework-managed |

Modeling decisions (full rationale in `docs/DECISIONS.md`):

- **Raw + structured, not raw + views.** Real columns give plain-SQL access (the story's requirement), honest indexes, and schema-as-documentation. Raw jsonb is retained for audit/replay — structured tables are rebuildable from raw.
- **Enrichment is additive.** Stub actor/repo rows are created from payload data at ingest; enrichment fills them in later. Push events are immediately queryable with ids/logins even before (or without) enrichment.
- **`fetch_status` is a tiny state machine** (`pending → fetched | not_found`) so terminal failures are data, not retries.

## Idempotency & Restart Safety (Extension B)

Assume every operation can be interrupted and replayed:

- All externally-keyed writes are upserts against unique indexes (`ON CONFLICT DO NOTHING`/`DO UPDATE`)
- Raw + structured writes share one transaction — no torn events
- Job state lives in Postgres (Solid Queue): worker restarts resume, not duplicate
- Poll ETag persistence means a restarted ingester doesn't re-download an unchanged page
- Growth is bounded: events are append-only facts; actors/repos are upserted (one row per entity, ever); TTL bounds fetch frequency

## Failure Handling Matrix

| Failure | Behavior |
|---|---|
| 304 Not Modified | Log `not_modified`, zero budget spent, sleep poll interval |
| 403 / 429 | Sleep until `reset_at` + jitter; enrichment jobs park |
| 404 (actor/repo) | Mark `not_found`, never retry |
| 5xx / timeout / DNS | Exponential backoff, capped attempts, then skip-and-log |
| Malformed payload | Persist raw, skip structured, warn — never raise |
| Payload URL host ≠ api.github.com | Reject (SSRF guard), `security.url_rejected` log |
| Postgres unavailable | Wait-and-retry at boot; compose healthcheck ordering |
| SIGTERM | Finish in-flight unit, exit clean |

## Observability

One JSON object per line to stdout/stderr (`docker compose logs -f` is the operator UI). Canonical events: `poll.cycle`, `poll.rate_limited`, `enrich.success|cache_hit|parked|retry|terminal`, `ingest.malformed`, `security.url_rejected`. Every log carries `ts`, `level`, `component`, `event`; counts over one poll cycle reconcile (seen = new + duplicates + non-push).

## Technology Choices (summary — details in docs/DECISIONS.md)

| Choice | Over | Because |
|---|---|---|
| Rails 8 API-only | Sinatra/plain Ruby | Exercise preference; migrations, jobs, testing conventions for free |
| Solid Queue | Sidekiq + Redis | One stateful dependency; queue durability = DB durability; restart safety for free |
| Polling + ETag | Webhooks | No public endpoint needed; fits "runs unattended locally"; 304s make it cheap |
| Postgres jsonb for raw | Object storage | One system of record at this scale; Extension C consciously skipped |
