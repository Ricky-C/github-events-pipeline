# CLAUDE.md

GitHub Push event ingestion pipeline. Polls the public GitHub Events API (unauthenticated), filters PushEvents, persists raw + structured data to Postgres, and enriches with actor/repo data — all within a 60 req/hr rate budget. Built as a take-home exercise; treated as a production internal service.

## Golden Rules

1. **Read `docs/PLAN.md` and the current phase plan in `docs/plans/` before starting any work.** Work only on the current phase. Do not implement future-phase features early, even if convenient.
2. **One PR per phase.** Branch from `main`, reference the phase's GitHub issue with `Closes #N`, squash-merge. Never commit directly to `main` after Phase 0.
3. **All GitHub API traffic goes through `GithubClient`.** Never call `Net::HTTP`/`Faraday` against api.github.com from anywhere else. The client owns ETags, `X-Poll-Interval`, and the rate budget.
4. **Never introduce a GitHub auth token.** Unauthenticated access is an explicit exercise constraint. Do not add token support "for convenience."
5. **No new stateful dependencies.** Postgres is the only datastore. Background jobs use Solid Queue (Postgres-backed). Do not add Redis, Sidekiq, or external caches.
6. **Update docs in the same PR as the code.** Phase plan checkboxes, `docs/DECISIONS.md` for notable tradeoffs, `docs/ARCHITECTURE.md` if structure changes.
7. **No AI attribution in git history.** Never add "Generated with Claude Code", `Co-Authored-By: Claude <noreply@anthropic.com>`, robot emoji, or any similar signature/trailer to commit messages or PR descriptions. Commits are conventional-commit style (`feat:`, `fix:`, `chore:`, `docs:`, `test:`), written in plain imperative voice, describing the change and nothing else.
8. **Develop against fixtures, never the live API.** The 60 req/hr budget is per-IP and shared with the human's own verification runs — debugging loops against api.github.com burn it and stall the project for an hour at a time. Capture real responses once (curl with `-i` to keep headers → `spec/fixtures/`), commit them, and develop/test exclusively against them via WebMock. The live API is touched only for deliberate end-of-phase verification runs.
9. **A phase is done when its exit criteria have been *executed*, not written.** Before declaring any phase complete or opening its PR: actually run `docker compose run --rm test`, actually boot the stack, actually run the verification SQL, and report the observed output. Never state that tests pass or the system works without having run the commands in this session.

## Commands

```bash
docker compose up --build          # start full system (db, ingester, worker)
docker compose run --rm ingest     # one-shot ingestion run
docker compose run --rm test       # run test suite
docker compose logs -f             # observe behavior
docker compose run --rm app bin/rails c   # console for inspection
```

Local (outside Docker) commands should not be assumed to work; the container is the source of truth.

## Tech Stack

- Ruby on Rails 8, API-only mode
- PostgreSQL 16 (system of record, single stateful dependency)
- Solid Queue for background jobs
- RSpec + WebMock for tests (no live API calls in tests, ever)
- Structured JSON logging to stdout/stderr

## Code Conventions

- Service objects in `app/services/`, one responsibility each (`GithubClient`, `EventIngester`, `PushEventParser`)
- Jobs in `app/jobs/`, thin — delegate logic to services so it's unit-testable
- Migrations: every externally-sourced ID gets a unique index; writes are `upsert`/`ON CONFLICT` — assume every operation may be retried
- Logging: one JSON line per meaningful event via the shared `StructuredLogger`; never `puts`; never log full raw payloads at info level
- Rescue specific errors, never bare `rescue`; transient failures retry with backoff, terminal failures (404) are marked and never retried
- No comments explaining *what*; comments only for *why* (especially rate-limit and idempotency decisions)

## Testing

- Every service object gets unit tests; fixtures are real captured `/events` JSON in `spec/fixtures/`
- WebMock blocks all real HTTP in the suite
- Malformed-payload cases are first-class test cases, not afterthoughts
- The suite must pass via `docker compose run --rm test` before any PR

## Security Invariants

See `docs/THREAT-MODEL.md` for full detail. Non-negotiables:

- Enrichment URLs from event payloads are only fetched if host is exactly `api.github.com` (SSRF guard)
- Structured fields extracted from payloads are length-validated before persistence
- No secrets exist in this project; if you think you need one, stop and check `docs/DECISIONS.md`
- Containers run as non-root

## Doc Map

| File | Purpose |
|---|---|
| `docs/PLAN.md` | Phase index + status |
| `docs/plans/PHASE-N-PLAN.md` | Per-phase objectives, tasks, exit criteria |
| `docs/specs/GITHUB-CLIENT.md` | Binding contract for the API client (interface, Result taxonomy, URL guard) |
| `docs/ARCHITECTURE.md` | System design, data model, rate-limit strategy |
| `docs/THREAT-MODEL.md` | Threat model and controls |
| `docs/SECURITY-REVIEWER.md` | Checklist for security review of each PR |
| `docs/DECISIONS.md` | ADR-lite log of tradeoffs (feeds the design brief) |
| `DESIGN.md` | The submission design brief (finalized in Phase 5) |
