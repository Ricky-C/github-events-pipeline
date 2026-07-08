# PLAN.md — Project Roadmap

Master index for the phased build. Each phase maps 1:1 to a GitHub issue and a single PR. Detailed plans live in `docs/plans/`.

## Goal

A containerized, unattended service that ingests GitHub PushEvents from the public (unauthenticated) Events API, persists raw + structured data in Postgres, enriches events with actor/repository data, and behaves predictably under rate limiting and failure — per the exercise's four core stories, with Extensions A, B, and D.

## Central Design Constraint

**60 unauthenticated requests/hour, shared between polling and enrichment.** Every architectural decision traces back to this. See `docs/ARCHITECTURE.md` § Rate Budget.

## Phases

| Phase | Scope | Issue | Branch | PR | Status |
|---|---|---|---|---|---|
| 0 | Scaffold: Rails 8 API, Docker Compose, Postgres | #1 | `chore/scaffold` | #7 | 🔄 In review |
| 1 | Story 1: Ingest GitHub Push Events | #2 | `story-1-ingest` | — | ☐ Not started |
| 2 | Story 2: Persist Raw and Structured Data | #3 | `story-2-structured-persistence` | — | ☐ Not started |
| 3 | Story 3: Enrich Push Events | #4 | `story-3-enrichment` | — | ☐ Not started |
| 4 | Story 4: Operability and Observability | #5 | `story-4-operability` | — | ☐ Not started |
| 5 | Extensions (A/B docs, D tests) + Design Brief | #6 | `extensions-and-brief` | — | ☐ Not started |

Detailed plans: [Phase 0](plans/PHASE-0-PLAN.md) · [Phase 1](plans/PHASE-1-PLAN.md) · [Phase 2](plans/PHASE-2-PLAN.md) · [Phase 3](plans/PHASE-3-PLAN.md) · [Phase 4](plans/PHASE-4-PLAN.md) · [Phase 5](plans/PHASE-5-PLAN.md)

## Working Agreement

- A phase is **done** when its exit criteria are checked, its PR is squash-merged with `Closes #N`, and its docs are updated in the same PR.
- Phases are sequential. No cross-phase work in a single PR.
- Discovered work that belongs to a later phase gets a note in that phase's plan file, not an implementation.
- Notable tradeoffs discovered mid-phase are recorded in `docs/DECISIONS.md` immediately, while the reasoning is fresh — this is raw material for the design brief.

## Intentionally Out of Scope (whole project)

Recorded here so "what I did not build" in the brief is a decision log, not an apology:

- Extension C (object storage / avatars) — adds a dependency (MinIO/S3) that doesn't serve the core analysis use case
- Authenticated GitHub tokens — explicit exercise constraint
- Webhooks — would require a public endpoint; polling fits "runs unattended locally"
- A query/read API — exercise asks for queryable *storage*, not an API surface
- Horizontal scaling / multi-instance coordination — single-node by design; noted as future work in the brief
