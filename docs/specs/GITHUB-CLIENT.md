# SPEC: GithubClient

The single chokepoint for all GitHub API traffic (CLAUDE.md Golden Rule 3). This spec is the contract Phase 1 builds against and Phase 3 consumes unchanged. If implementation pressure forces a contract change, update this file and `docs/DECISIONS.md` in the same PR.

## Design Principles

1. **The client returns facts; callers make policy.** It never sleeps, never retries, never reschedules. It reports what happened (`rate_limited`, `not_modified`, …) with enough data (`reset_at`, `poll_interval`) for the caller to decide. The ingester loop sleeps; enrichment jobs park. This keeps the client synchronous, side-effect-minimal, and testable without time travel.
2. **Expected outcomes are values, not exceptions.** 304s, 404s, and 429s are *normal operation* for this system. Exceptions are reserved for programmer error (malformed arguments). Every call returns a `Result`.
3. **The budget is shared, persisted, and advisory.** State lives in Postgres (`rate_limit_states`) so both processes and restarts see one budget. GitHub's response headers are the source of truth; the persisted copy is a best-effort mirror that self-corrects on every real response.

## Public Interface

```ruby
class GithubClient
  # Injectable for tests. Defaults are production wiring.
  def initialize(state: RateLimitState, clock: Time, http: nil)

  # GET https://api.github.com/events using the persisted ETag.
  # Persists new ETag + rate state from response headers.
  # Never consumes budget on 304.
  # @return [Result]
  def poll_events

  # SSRF-guarded GET of a payload-provided URL (actor/repo enrichment).
  # Sends If-None-Match when etag given. Persists rate state.
  # @return [Result]
  def fetch_resource(url, etag: nil)

  # Snapshot of persisted budget state.
  # @return [Budget]
  def budget
end
```

### Result

Immutable value object. Exactly one `status` per call:

| `status` | Meaning | Populated fields |
|---|---|---|
| `:ok` | 2xx with parseable JSON body | `body` (parsed), `etag`, `poll_interval`*, `rate` |
| `:not_modified` | 304 — no budget consumed | `poll_interval`*, `rate` (unchanged) |
| `:rate_limited` | 403 with `x-ratelimit-remaining: 0`, or 429 | `rate` (incl. `reset_at`), `retry_after`? |
| `:not_found` | 404 / 410 — terminal, never retry | `rate` |
| `:transient_error` | 5xx, timeout, connection/DNS failure, unparseable body, body over size cap | `error` (class + message), `rate`? |
| `:rejected_url` | `fetch_resource` refused the URL pre-flight (no request made) | `error` (reason) |

`poll_interval` only on `/events` responses. `rate` = `{remaining: Integer?, reset_at: Time?}` — nil-able before first response. `retry_after` = integer seconds, normalized from both the delta-seconds and HTTP-date forms of the header; callers must prefer it over `reset_at` when both are present (secondary limits ask for a short wait while the primary reset sits far out).

Convenience predicates: `ok?`, `not_modified?`, `rate_limited?`, `terminal?` (`:not_found` or `:rejected_url`), `retryable?` (`:transient_error`).

### Budget

```ruby
Budget = Struct.new(:remaining, :reset_at, :updated_at) do
  def spendable?(reserve: 0)  # false when remaining known and <= reserve
  def exhausted?              # remaining known and == 0
  def unknown?                # no response observed yet (boot) -> callers act optimistically
end
```

**Policy constants (live with the callers, documented here):** `ENRICHMENT_RESERVE = 5` — enrichment jobs check `budget.spendable?(reserve: ENRICHMENT_RESERVE)` before fetching and park until `reset_at` if not. Polling checks nothing — it has priority by design (D-006): real polls cost ~1/interval and 304s are free.

## Request Discipline

Every request sends:

| Header | Value |
|---|---|
| `User-Agent` | `github-events-pipeline/<version>` (GitHub rejects requests without one) |
| `Accept` | `application/vnd.github+json` |
| `X-GitHub-Api-Version` | `2022-11-28` |
| `If-None-Match` | stored ETag, when present |

Transport limits: open timeout **5s**, read timeout **10s**, response body cap **5 MB** (over-cap → `:transient_error`, connection closed). No auth header, ever.

### URL guard (`fetch_resource` pre-flight)

Refuse — returning `:rejected_url` *without making any request* — unless **all** hold:

- scheme is exactly `https`
- host is exactly `api.github.com` (no subdomains, no userinfo, no IP literals, no port override)
- after normalization (no `..` traversal to a different origin)

### Redirect policy

GitHub returns `301` for renamed repos/users. Follow **at most one** redirect, and only if the `Location` passes the same URL guard. A second redirect, or a guarded-out target → `:transient_error` (redirect loop) / `:rejected_url` (bad target). The redirect hop consumes budget like any request — count it.

## Rate-State Bookkeeping

After **every** real (non-304-shortcut… i.e., every actual HTTP) response, including errors, when headers are present:

- persist `x-ratelimit-remaining` → `remaining`, `x-ratelimit-reset` (epoch) → `reset_at`, now → `updated_at`
- `/events` responses: persist `etag` and `x-poll-interval`
- **ETags are stored and echoed verbatim** — GitHub returns weak ETags (`W/"..."`); stripping the `W/` prefix means it never matches, every poll silently costs budget, and the core design is defeated invisibly
- **304s may not be free in practice** — despite GitHub's documentation, a live 304 was observed carrying a decremented `x-ratelimit-remaining` (D-017). The mirror records whatever headers say; no code may assume 304s cost nothing
- `fetch_resource` with `etag:` given → on `304`, return `:not_modified` (caller keeps existing record; refresh `fetched_at` only)

**Concurrency note (accepted, documented):** ingester and worker may interleave writes; last-write-wins is acceptable because headers self-correct within one request and `ENRICHMENT_RESERVE` absorbs the race. No row locking. (Record as part of D-006 lineage if questioned.)

**Boot state:** `unknown?` budget → proceed optimistically; first response populates it.

## HTTP → Result Mapping (normative)

| Condition | Result |
|---|---|
| 200 `/events` | `:ok` + etag + poll_interval |
| 200 resource | `:ok` + etag |
| 304 | `:not_modified` |
| 301 (first, guard-passing) | follow once, map final response |
| 301 (second) / redirect to guarded-out URL | `:transient_error` / `:rejected_url` |
| 403 with `x-ratelimit-remaining: 0` | `:rate_limited` |
| 403 otherwise (abuse detection etc.) | `:rate_limited` (honor `retry-after` if present) |
| 429 | `:rate_limited` |
| 404, 410 | `:not_found` |
| 401 | `:transient_error` (should be impossible unauthenticated — log loudly) |
| 5xx | `:transient_error` |
| Timeout / ECONNREFUSED / DNS / SSL error | `:transient_error` |
| 2xx with invalid JSON | `:transient_error` |
| 2xx body > 5 MB | `:transient_error` |

## Caller Contracts (for reference — implemented in Phases 1 & 3)

**Ingester loop (Phase 1):**
```
loop:
  r = client.poll_events
  case r.status
  when :ok           -> ingest(r.body); sleep max(r.poll_interval, floor)
  when :not_modified -> sleep max(r.poll_interval_or_last_known, floor)
  when :rate_limited -> sleep (r.retry_after || (r.rate.reset_at - now)) + jitter   # retry-after wins when present
  when :transient_error -> sleep backoff(attempt++)   # capped; never exit
```

**Enrichment job (Phase 3):**
```
return park(until: (budget.reset_at || now + 60) + jitter) unless client.budget.spendable?(reserve: 5)
r = client.fetch_resource(record.url, etag: record.etag)
case r.status
when :ok            -> persist enrichment
when :not_modified  -> touch fetched_at
when :rate_limited  -> park(until: (r.retry_after ? now + r.retry_after : (r.rate.reset_at || now + 60)) + jitter)  # retry_after is a duration; reset_at an instant
when :not_found     -> mark not_found (terminal)
when :rejected_url  -> mark rejected + security log (terminal)
when :transient_error -> raise for Solid Queue retry (backoff, capped)
```

## Contract Test Checklist (Phase 1 unit specs — WebMock)

- [ ] Sends UA / Accept / API-version headers on every request
- [ ] `/events`: stores ETag from 200; sends it as `If-None-Match` on next poll
- [ ] 304 → `:not_modified`; a header-less 304 leaves persisted `remaining` unchanged, while rate headers a 304 does carry are mirrored (observed live: 304s can arrive with a decremented remaining — docs/DECISIONS.md D-017)
- [ ] Parses and exposes `x-poll-interval`
- [ ] 200 updates persisted `remaining`/`reset_at`; visible via `budget`
- [ ] 403 with remaining=0 → `:rate_limited` with correct `reset_at`
- [ ] 429 with `retry-after` → `:rate_limited`, `retry_after` exposed
- [ ] `Retry-After` in HTTP-date form → normalized to integer seconds
- [ ] 404 → `:not_found`
- [ ] 5xx / timeout / bad JSON / oversized body → `:transient_error` (four separate specs)
- [ ] URL guard allow/deny table: `https://api.github.com/users/x` ✓; `http://api.github.com/...` ✗; `https://api.github.com.evil.com/...` ✗; `https://evil.com/...` ✗; `https://api.github.com:8443/...` ✗; `https://user@api.github.com/...` ✗; IP literal ✗ — all deny cases make **zero** HTTP requests
- [ ] 301 followed once when target passes guard; second 301 → `:transient_error`; guarded-out target → `:rejected_url`
- [ ] `budget.unknown?` true before any response; false after
- [ ] Weak ETag (`W/"abc"`) from 200 is sent back byte-identical in `If-None-Match` (no prefix stripping)
- [ ] `spendable?(reserve: 5)` boundary: remaining 6 → true, 5 → false

## Out of Scope for This Client

Retry/backoff execution (callers), sleeping (callers), logging policy beyond returning data (callers log Results), payload interpretation (parser), persistence of domain records (services/jobs).
