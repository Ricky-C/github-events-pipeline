# Phase 0 — Project Scaffold

**Issue:** #1 · **Branch:** `chore/scaffold` · **Story:** none (chore)

## Objective

A clean-checkout-bootable foundation so every subsequent PR is a pure feature diff. The reviewer experience commands must work before any feature exists.

## Tasks

- [ ] `rails new . --api --database=postgresql` (Rails 8, API-only)
- [ ] Multi-stage `Dockerfile` (slim base, non-root user, gems cached in build layer)
- [ ] `docker-compose.yml`:
  - [ ] `db`: Postgres 16 with healthcheck (`pg_isready`), named volume
  - [ ] `migrate`: **one-shot** service running `db:prepare`, depends_on db healthy — the ONLY service that touches migrations (prevents concurrent-migration races)
  - [ ] `ingester` / `worker` (stub for now): `depends_on: {migrate: {condition: service_completed_successfully}}`
  - [ ] Service stubs for `ingest` (one-shot) and `test` (wired fully in later phases; `test` prepares its own RAILS_ENV=test database)
- [ ] `.env.example` for `DATABASE_URL` etc. (compose defaults work without a real `.env`)
- [ ] RSpec installed and running (one placeholder spec)
- [ ] Rails logger configured for stdout, JSON formatter as the ONLY formatter; log level `info`; ActiveRecord SQL logging quieted — `docker compose logs -f` must show structured lines only, no framework noise
- [ ] Environment decision applied (see docs/DECISIONS.md D-010): containers run `RAILS_ENV=development` for zero-secret boot; behavior that differs by env (job adapter, logging, eager loading) is configured explicitly rather than inherited
- [ ] Base `README.md` with the three reviewer commands
- [ ] `.gitignore` / `.dockerignore` correct (no `log/`, `tmp/`, `.env` in image or repo)

## Exit Criteria

- [ ] Fresh clone → `docker compose up --build` boots app + db with zero manual steps
- [ ] `docker compose run --rm test` runs the (placeholder) suite green
- [ ] `docker compose logs -f` shows structured startup logs
- [ ] Image runs as non-root (verify: `docker compose run --rm app whoami`)

## Out of Scope

Any GitHub API code, any domain tables. Solid Queue setup deferred to Phase 3 (its migrations arrive with the feature that needs it).

## Notes / Discovered Work

_(append during the phase)_
