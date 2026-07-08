# Phase 0 — Project Scaffold

**Issue:** #1 · **Branch:** `chore/scaffold` · **Story:** none (chore)

## Objective

A clean-checkout-bootable foundation so every subsequent PR is a pure feature diff. The reviewer experience commands must work before any feature exists.

## Tasks

- [x] `rails new . --api --database=postgresql` (Rails 8, API-only)
- [x] Multi-stage `Dockerfile` (slim base, non-root user, gems cached in build layer)
- [x] `docker-compose.yml`:
  - [x] `db`: Postgres 16 with healthcheck (`pg_isready`), named volume
  - [x] `migrate`: **one-shot** service running `db:prepare`, depends_on db healthy — the ONLY service that touches migrations (prevents concurrent-migration races)
  - [x] `ingester` / `worker` (stub for now): `depends_on: {migrate: {condition: service_completed_successfully}}`
  - [x] Service stubs for `ingest` (one-shot) and `test` (wired fully in later phases; `test` prepares its own RAILS_ENV=test database)
- [x] `.env.example` for `DATABASE_URL` etc. (compose defaults work without a real `.env`)
- [x] RSpec installed and running (one placeholder spec)
- [x] Rails logger configured for stdout, JSON formatter as the ONLY formatter; log level `info`; ActiveRecord SQL logging quieted — `docker compose logs -f` must show structured lines only, no framework noise
- [x] Environment decision applied (see docs/DECISIONS.md D-010): containers run `RAILS_ENV=development` for zero-secret boot; behavior that differs by env (job adapter, logging, eager loading) is configured explicitly rather than inherited
- [x] Base `README.md` with the three reviewer commands
- [x] `.gitignore` / `.dockerignore` correct (no `log/`, `tmp/`, `.env` in image or repo)

## Exit Criteria

- [x] Fresh clone → `docker compose up --build` boots app + db with zero manual steps
- [x] `docker compose run --rm test` runs the (placeholder) suite green
- [x] `docker compose logs -f` shows structured startup logs
- [x] Image runs as non-root (verify: `docker compose run --rm app whoami`)

## Out of Scope

Any GitHub API code, any domain tables. Solid Queue setup deferred to Phase 3 (its migrations arrive with the feature that needs it).

## Notes / Discovered Work

- Rails resolved to **8.1.3** (docs say "Rails 8"; 8.1 is the current 8.x line). Generator run inside a throwaway `ruby:3.4` container — no host Ruby required, consistent with "the container is the source of truth."
- Went further than the plan on trimming: removed puma (no HTTP server at all), credentials/master.key, and `config/environments/production.rb`. Recorded as D-011.
- The compose `test` service sets `CI=true` so the suite eager-loads the whole app — a leftover `app/mailers/` referencing the removed ActionMailer railtie crashed the ingester but passed a lazy-loading test run; eager loading in the suite closes that gap permanently.
- GitHub Actions CI (scan/lint/test with a Postgres service container) kept per maintainer preference; local Docker commands remain the canonical verification path.
- `bundler-audit --update` needs `git` in the runtime image; added (advisory-db clone happens in-container).
