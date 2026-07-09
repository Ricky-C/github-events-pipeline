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

1. **Conditional requests.** `/events` is polled with `If-None-Match: <etag>`. GitHub grants the 304 rate-limit exemption only to requests carrying an `Authorization` header, and this service has none by design — so 304s **decrement `X-RateLimit-Remaining`** here, as measured (D-017, D-022). Conditional requests save bandwidth and parsing, not budget. Per-record ETags are still stored for actor/repo re-fetches (a 304 skips re-persisting an unchanged body).
2. **Poll cadence floor.** GitHub states the minimum poll interval in a response header (60s); the ingester never polls faster than the header **or** its own `POLL_FLOOR` (120s), whichever is larger. Because every poll costs budget, honoring the served 60s would spend the entire 60/hr budget on polling; the floor caps polling at ~30 req/hr (D-022).
3. **Request budget.** `GithubClient` persists `X-RateLimit-Remaining`/`X-RateLimit-Reset`. Policy: polling has priority (~30 req/hr at the floor); enrichment spends what remains down to a small reserve (`ENRICHMENT_RESERVE = 5`). At exhaustion, enrichment jobs **park** (reschedule to `reset_at` + jitter) rather than fail.
4. **Fan-out control.** Actor/repo fetches are deduplicated two ways: a 24h TTL on `fetched_at` (the firehose is dominated by repeat actors — bots especially), and in-flight job dedup keyed on (type, github_id).
5. **Worker concurrency = 1.** Serializes budget spend; no thundering herd at reset time. Throughput ceiling is the rate limit anyway, so concurrency buys nothing.

Degradation mode under sustained limiting: the ingester sleeps to the reset and resumes at the floored cadence; enrichment backlog queues durably in Postgres and drains each budget window. Nothing is lost, nothing crashes.

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
- **`fetch_status` is a small state machine** (`pending → enqueued → fetched | not_found | rejected`, back to `pending` on retry exhaustion or when `EnrichmentSweep` finds an `enqueued` record whose job died; `fetched` re-claims after the 24h TTL) so in-flight dedup and terminal failures are data, not retries (D-023, D-024).

## Idempotency & Restart Safety (Extension B)

Assume every operation can be interrupted and replayed:

- All externally-keyed writes are upserts against unique indexes (`ON CONFLICT DO NOTHING`/`DO UPDATE`)
- Raw + structured writes share one transaction — no torn events
- Job state lives in Postgres (Solid Queue), so a worker restart resumes rather than forgets. Delivery is at-least-once, not exactly-once: a graceful restart mid-fetch re-runs the job (one wasted request; every persist is an idempotent `update!`), and a *hard* kill dead-letters the claimed execution rather than re-running it, which `EnrichmentSweep` reconciles (D-024)
- Poll ETag persistence means a restarted ingester doesn't re-download an unchanged page
- Growth is bounded: events are append-only facts; actors/repos are upserted (one row per entity, ever); TTL bounds fetch frequency

## Failure Handling Matrix

| Failure | Behavior |
|---|---|
| 304 Not Modified | Log `not_modified`, no body to ingest, sleep floored poll interval (budget is decremented like any request — D-022) |
| 403 / 429 | Sleep until `reset_at` + jitter; enrichment jobs park. Every such wait is clamped to the one-hour rate window — a header asking for longer is a desynced shard, not an instruction (D-024) |
| Worker hard-killed mid-fetch | Solid Queue dead-letters the claimed execution; `EnrichmentSweep` releases the record and re-claims it within one sweep interval (D-024) |
| 404 (actor/repo) | Mark `not_found`, never retry |
| 5xx / timeout / DNS / malformed transport (bad status line, truncated gzip, any socket errno) | Poller: capped exponential backoff, absorbed indefinitely — a process restart cannot fix the network (`GithubClient::NETWORK_ERRORS` covers the transport surface by parent class, D-028). Enrichment: `retry_on` backoff, 5 attempts, then the claim is released with `enrich.retry_exhausted` |
| 2xx with unparseable body | `body.unparseable` warn (never the body bytes), `:transient_error` backoff; the stored ETag never advances past it |
| Malformed payload | Persist raw, skip structured, warn — never raise |
| Payload URL host ≠ api.github.com | Reject (SSRF guard), `security.url_rejected` log |
| Postgres unavailable at boot | Compose healthcheck gates `migrate`, which gates the services |
| Postgres dies mid-run | DB-shaped errors (`IngestRunner::TRANSIENT_ERRORS`) back off with `poll.error`; after `MAX_CONSECUTIVE_FAILURES` consecutive failures (~20 min) the ingester logs fatal `poll.escalated` and exits nonzero so compose's `restart: unless-stopped` recycles it (D-026) |
| Programming error mid-cycle | Fatal `poll.escalated reason=permanent_error`, immediate nonzero exit — retrying re-runs the same bug; Docker's restart backoff paces the restart loop (D-026) |
| SIGTERM | Finish in-flight unit, exit clean — a stop requested mid-failure outranks escalation: the error is logged, the exit stays zero (D-028) |

## Observability

One JSON object per line to stdout/stderr (`docker compose logs -f` is the operator UI). Two layers own the shape: `JsonLogFormatter` (lib/) renders the line and neutralizes hostile bytes — its reserved `ts`/`level` keys win every merge, so payload-derived keys cannot forge a severity or timestamp — and the `StructuredLogging` mixin stamps `component` and `event` at every call site (D-027). This list is transcribed from what the code emits; changing either without the other is a defect (D-027):

| Component | Event (level) | Key fields |
|---|---|---|
| `ingester` | `poll.cycle` (info) | `status`, `not_modified`, `events_seen`, `push_events_new`, `duplicates_skipped`, `malformed_skipped`, `structured_skipped`, `budget_remaining`, `sleep_for` |
| `ingester` | `poll.rate_limited` (info) | `reset_at`, `retry_after`, `sleep_for` — an overlay on the cycle line; exhausted shared budget is normal operation |
| `ingester` | `poll.error` (error) | `error_class`, `message`, `consecutive` — DB-shaped failure, absorbed and backed off (D-026) |
| `ingester` | `poll.escalated` (fatal) | `reason` (`permanent_error` \| `transient_failures_exhausted`), `error_class`, `message`, `backtrace` (trimmed), `consecutive` (streak reason only) — last line before the nonzero exit; the process exits rather than re-raising, so nothing unstructured follows it (D-026, D-028) |
| `ingester` | `shutdown.clean` (info) | — |
| `ingester` | `ingest.malformed` / `ingest.structured_skipped` (warn) | `reason`, `detail` |
| `ingester` | `enrich.enqueued` / `enrich.cache_hit` / `enrich.skipped` (info) | `entity`, `github_id` (+ `fetched_at` / `reason`) |
| `ingester` | `enrich.enqueue_failed` (error) | `error_class`, `message` |
| `worker` | `enrich.success` (info) | `entity`, `github_id`, `not_modified` (`true` = 304 revalidation) |
| `worker` | `enrich.parked` (info) | `reason` (`budget` \| `rate_limited`), `run_at` |
| `worker` | `enrich.retry` (warn) / `enrich.retry_exhausted` (error) | `status`/`error` · `job`, `record_id`, `error_class` |
| `worker` | `enrich.terminal` (info) / `enrich.rejected` (warn) / `enrich.scrubbed` (warn) | `reason` / `body_class` / `error_class` |
| `worker` | `enrich.sweep` (info) / `enrich.swept` (warn) / `enrich.sweep_aborted` (error) | `swept` · `reason`, `reclaimed` · `class_name`, `solid_queue_job_id` |
| both | `security.url_rejected` (error) | `entity`, `github_id`, `reason` (+ `detail` at ingest) |
| `github_client` | `etag.unstorable` (warn) / `body.unparseable` (warn) / `auth.unexpected_401` (error) | `bytesize` / `error_class`, `bytesize` / `msg` |

Level convention: **info** narrates the healthy lifecycle (including rate limiting — that is the system working); **warn** is an upstream data anomaly, absorbed; **error** is a guard refusal, a broken invariant, or lost work; **fatal** precedes a deliberate nonzero exit. Counts over one poll cycle reconcile (seen = new + duplicates + non-push + malformed; `structured_skipped` is an overlay on top of that partition, not a term in it — see D-020/D-021).

## Technology Choices (summary — details in docs/DECISIONS.md)

| Choice | Over | Because |
|---|---|---|
| Rails 8 API-only | Sinatra/plain Ruby | Exercise preference; migrations, jobs, testing conventions for free |
| Solid Queue | Sidekiq + Redis | One stateful dependency; queue durability = DB durability; restart safety modulo a reconciling sweep (D-024) |
| Polling + ETag | Webhooks | No public endpoint needed; fits "runs unattended locally"; 304s save bandwidth, not budget (D-022) |
| Postgres jsonb for raw | Object storage | One system of record at this scale; Extension C consciously skipped |
