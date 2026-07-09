# GitHub Events Pipeline

Ingests GitHub PushEvents from the public Events API (unauthenticated), persists raw and structured data to PostgreSQL, and enriches events with actor/repository data — designed to run unattended within GitHub's 60 req/hr rate limit.

> **Design brief:** [DESIGN.md](DESIGN.md) · **Deep dive:** [ARCHITECTURE.md](docs/ARCHITECTURE.md) · **Plan & PR trail:** [PLAN.md](docs/PLAN.md) + [Issues](../../issues)

## Requirements

- Docker Desktop (macOS) — nothing else; all dependencies live in Compose.

## Start the System

```bash
docker compose up --build
```

Boots Postgres, runs migrations, starts the ingester (continuous polling) and the enrichment worker.

## Run Ingestion

Continuous ingestion starts with `up`. For a one-shot run:

```bash
docker compose run --rm ingest
```

## Run Tests

```bash
docker compose run --rm test
```

## How to Verify It's Working

<!-- Finalized in Phase 4 — structure locked now, examples filled from real runs -->

**1. Watch the logs** (`docker compose logs -f`):

Within the first minute you should see:
```jsonc
// captured from a live run (Phase 4 verification)
{"ts":"2026-07-09T19:10:16.053Z","level":"info","component":"ingester","event":"poll.cycle","status":"ok","not_modified":false,"budget_remaining":59,"sleep_for":120,"events_seen":30,"push_events_new":28,"duplicates_skipped":0,"malformed_skipped":0,"structured_skipped":0}
```

Under rate limiting (expected during long runs — this is normal, not an error):
```jsonc
// captured from the real ingest loop replaying the 403 fixture (spec/fixtures/github/events_403_rate_limited.http)
{"ts":"2026-07-09T19:09:49.664Z","level":"info","component":"ingester","event":"poll.rate_limited","reset_at":"2026-07-09T01:20:00Z","retry_after":null,"sleep_for":60}
```

**2. Check the database:**

```bash
docker compose exec db psql -U postgres -d github_events_pipeline_development -c \
  "SELECT count(*) FROM raw_events;
   SELECT count(*) FROM push_events;
   SELECT count(*) FROM actors WHERE fetch_status='fetched';"
```

**Important context for first runs:**

- The 60 req/hr unauthenticated limit is **per IP**. On a shared/office network, the budget may already be spent by others. If you see `poll.rate_limited` immediately, that is the system working as designed — it sleeps to the reset (top of the hour) and resumes, not a bug.
- One-shot `docker compose run --rm ingest` shares the same IP budget as the running stack — running both concurrently is safe (idempotent writes) but doubles spend.
- One-shot ingestion enqueues enrichment jobs; the `worker` service must be running for enrichment to drain.

**3. Expected timing:**

- First `raw_events` / `push_events` rows: within one poll cycle (~2 min — the poll floor is 120s because 304s cost budget, D-022)
- First enriched actors/repositories: within 2–3 minutes, budget permitting
- Under exhausted budget: the ingester sleeps to the rate-limit reset (top of the hour) and enrichment parks; both resume there. Conditional requests save bandwidth, not budget — GitHub exempts a 304 from the rate limit only when the request is authenticated (D-022)

## Project Structure

| Path | What |
|---|---|
| `app/services/` | `GithubClient`, `EventIngester`, `PushEventParser` |
| `app/jobs/` | Enrichment jobs (Solid Queue) |
| `docs/plans/` | Per-phase implementation plans |
| `DESIGN.md` | 2-page design brief (deliverable) |
| `docs/THREAT-MODEL.md` | Threat model for a pipeline that eats untrusted internet JSON |
