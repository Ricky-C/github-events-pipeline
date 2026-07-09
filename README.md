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
// TODO(phase-4): paste real poll.cycle line
{"event":"poll.cycle","status":"ok","events_seen":30,"push_events_new":14,"duplicates_skipped":0,"malformed_skipped":0,"structured_skipped":0,"budget_remaining":57,"sleep_for":120}
```

Under rate limiting (expected during long runs — this is normal, not an error):
```jsonc
// TODO(phase-4): paste real poll.rate_limited line
```

**2. Check the database:**

```bash
docker compose exec db psql -U postgres -d app_development -c \
  "SELECT count(*) FROM raw_events;
   SELECT count(*) FROM push_events;
   SELECT count(*) FROM actors WHERE fetch_status='fetched';"
```

**Important context for first runs:**

- The 60 req/hr unauthenticated limit is **per IP**. On a shared/office network, the budget may already be spent by others. If you see `poll.rate_limited` immediately, that is the system working as designed — it sleeps to the reset (top of the hour) and resumes, not a bug.
- One-shot `docker compose run --rm ingest` shares the same IP budget as the running stack — running both concurrently is safe (idempotent writes) but doubles spend.
- One-shot ingestion enqueues enrichment jobs; the `worker` service must be running for enrichment to drain.

**3. Expected timing:**

- First `raw_events` / `push_events` rows: within one poll cycle (~60s)
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
