# DECISIONS.md

ADR-lite log. One entry per consequential decision, appended when made. This file is the raw material for the design brief's "tradeoffs and assumptions" and "what I did not build" sections — write entries well once, reuse twice.

Format: **Context → Decision → Consequences (incl. what we gave up)**

---

## D-001: Rails 8, API-only mode

**Context:** Exercise prefers Rails; alternatives (Sinatra, plain Ruby + Sequel) would be lighter for a headless pipeline.
**Decision:** Rails 8 API-only.
**Consequences:** Migrations, ActiveRecord upserts, Solid Queue, and testing conventions for free; team-alignment with the reviewer's stack. Cost: heavier boot than a script — acceptable for a long-running service. Gave up: minimalism bragging rights.

## D-002: Solid Queue over Sidekiq/Redis

**Context:** Enrichment needs background, durable, restartable jobs. Sidekiq is the Rails default habit but requires Redis.
**Decision:** Solid Queue (Rails 8 default, Postgres-backed).
**Consequences:** Single stateful dependency; job durability = database durability; restart safety and the "system of record: PostgreSQL" requirement satisfied by one system. Cost: lower max throughput than Redis-backed queues — irrelevant here, since the rate limit (60/hr) is the throughput ceiling, not the queue.

## D-003: Polling with conditional requests, not webhooks

**Context:** Webhooks are the "real" production answer for GitHub activity but require a publicly reachable endpoint and repo-level configuration.
**Decision:** Poll `/events` with `If-None-Match`; honor `X-Poll-Interval`.
**Consequences:** Runs unattended on a laptop with zero inbound surface; 304s make idle polling free against the rate budget. Cost: bounded completeness — the public events feed is a sliding window, so quiet-period events between polls can be missed. Acceptable: the goal is activity analysis, not exhaustive capture. Noted in brief.

## D-004: Raw jsonb + structured columns (both), rebuildable one-way

**Context:** Story 2 demands queryability without JSON parsing; audit needs raw retention.
**Decision:** `raw_events` (jsonb, append-only) + `push_events` (real columns, real indexes), written in one transaction; structured is derivable from raw.
**Consequences:** Plain-SQL analytics, honest indexes, replay/backfill capability if the parser improves. Cost: ~2x storage per event — cheap at this scale, and raw could later age out to object storage (consciously deferred, see D-007).

## D-005: 24h enrichment TTL + in-flight dedup, worker concurrency = 1

**Context:** The public firehose repeats actors heavily (bots dominate); every duplicate fetch wastes irreplaceable budget.
**Decision:** Skip enrichment if `fetched_at` < 24h; dedup queued jobs per (type, github_id); single worker thread.
**Consequences:** Fan-out collapses to roughly unique-entities-per-day; budget spend is serialized and predictable. Cost: enrichment data can be up to 24h stale (fine for trend analysis) and backlog drains slowly under budget pressure (by design — parked, not lost).

## D-006: Budget policy — polling has priority, enrichment takes the remainder

**Context:** One 60/hr budget, two consumers.
**Decision:** Reserve budget for the poll cadence (cheap: 304s are free, real polls ~1/interval); enrichment spends down to a small reserve, then parks until `X-RateLimit-Reset`.
**Consequences:** The system never goes blind — observation continues even when enrichment is starved. Degradation is graceful and self-healing at window reset.

## D-007: Extension C (object storage) intentionally not built

**Context:** Optional extension; avatars/raw-events-to-S3 would add MinIO to compose.
**Decision:** Skip. Persist `avatar_url` references only.
**Consequences:** One fewer dependency, smaller review surface, compose stays trivially bootable. The brief documents the production path (age raw jsonb out to object storage; cache avatars with content-hash keys and TTL) to show the thinking without the plumbing.

## D-008: SSRF guard on payload-provided URLs

**Context:** Story 3 says to use URLs *from the event payload* — i.e., fetch targets arrive inside untrusted input.
**Decision:** Fetch only `https://api.github.com/...`; reject everything else with a security log.
**Consequences:** Payload mutation can't redirect the service at internal targets. Cost: none. (This is the kind of requirement-reading the exercise rewards.)

## D-009: Single page per poll — pagination intentionally skipped

**Context:** `/events` serves up to 10 pages × ~30 events; the feed is a sliding window regardless, so completeness is unattainable by design.
**Decision:** Fetch page 1 only, once per poll interval.
**Consequences:** Budget spend is ~1 request/interval instead of up to 10; the dataset is an explicit *sample* of public activity, which serves the stated goal (analyzing usage/behavior over time) fine. Stated plainly in the brief so it reads as judgment, not oversight.

## D-010: RAILS_ENV=development in containers; Solid Queue forced and pointed at the primary DB

**Context:** Production env demands SECRET_KEY_BASE and credentials ceremony (we have zero secrets by design); development env silently defaults Active Job to the async adapter and generates Solid Queue against a separate queue database in Rails 8.
**Decision:** Run development env for zero-secret boot, but configure explicitly what env defaults would get wrong: `queue_adapter = :solid_queue`, Solid Queue on the **primary** database, log level info with JSON-only formatting.
**Consequences:** Clean-checkout boot with no key generation steps; queue durability = database durability (one system of record, per the exercise); no async-adapter false positives during development. Cost: dev-env defaults must be consciously overridden — captured as explicit Phase 0/3 tasks so it can't be forgotten.

## D-011: No HTTP server, no credentials, no production environment

**Context:** `rails new` ships puma, encrypted credentials + master.key, and a production env config. This service has zero inbound surface (docs/THREAT-MODEL.md) and zero secrets by design; containers run the development env (D-010).
**Decision:** Delete all three at scaffold time: no puma/`config/puma.rb`, no `credentials.yml.enc`/`master.key`, no `config/environments/production.rb` or database.yml production section. Unused railties (mailer, mailbox, text, storage, cable) also removed. Review cleanup extended the trim: `config.ru`, the `/up` route, the CORS/inflections/locale scaffold files, the no-op `bin/docker-entrypoint`, and stale storage/credentials ignore rules are gone too (key-file ignore rules kept as defense-in-depth).
**Consequences:** The repo contains nothing that can leak and nothing listening; the "no secrets" claim is verifiable by absence, not policy. Cost: a future inbound surface (health endpoint, metrics) would need puma reintroduced — one Gemfile line, recorded here so it reads as a decision, not an accident.

## D-012: Discrete PG* connection vars instead of DATABASE_URL

**Context:** Phase 0 code review found two failure modes in composing a `DATABASE_URL` from `${POSTGRES_PASSWORD}`: reserved characters in an overridden password break URI parsing (while the db itself accepts the password), and the database name was pinned in the URL so `RAILS_ENV` alone didn't select the database.
**Decision:** Pass `PGHOST`/`PGUSER`/`PGPASSWORD` discretely; `config/database.yml` reads them explicitly and owns the env→database mapping.
**Consequences:** Passwords never travel through URL parsing (any characters work); `RAILS_ENV` is the single switch between dev and test databases; compose and CI share the same mechanism. Cost: no single copy-pasteable connection URL — acceptable, nothing external consumes one. The related caveat that the postgres image bakes the password into the volume at first initdb is now documented in compose and `.env.example`.

## D-013: Net::HTTP over an HTTP-client gem

**Context:** Phase 1 needs an HTTP transport for `GithubClient`. Faraday/HTTParty are the habitual choices.
**Decision:** Stdlib `Net::HTTP`, wrapped entirely inside the one client class.
**Consequences:** Zero new supply-chain surface (docs/THREAT-MODEL.md), no middleware indirection for a client that talks to exactly one host with strict transport limits, and WebMock intercepts it natively. The 5 MB cap is enforced by streaming `read_body` and aborting mid-read. Gave up: nicer ergonomics if the API surface ever grows — acceptable, the spec forbids it growing.

## D-014: rate_limit_states singleton via guard column + partial upsert

**Context:** The shared budget mirror must be one logical row, written by two processes, where every write may be a retry.
**Decision:** A `singleton_guard` column fixed at 0 with a unique index; all writes are single-statement `upsert` (`ON CONFLICT DO UPDATE`) of only the columns observed in that response.
**Consequences:** The singleton is a database constraint, not a convention; there is no read-modify-write to race; concurrent writers are last-write-wins, which the client spec explicitly accepts (D-006 lineage) because headers self-correct on the next real response. Partial updates mean a resource fetch can never clobber the `/events` ETag, and a header-less response persists nothing.

## D-015: Fixture strategy — capture the happy paths once, synthesize the failures

**Context:** Tests must never touch the live API (Golden Rule 8), but realistic fixtures matter — GitHub's weak ETags (`W/"..."`) are exactly the kind of detail hand-written stubs get wrong.
**Decision:** One live capture session: `curl -sS -i --http1.1` of a real 200 and a real 304 (ETag replay inside GitHub's cache window), committed verbatim as `.http` files and parsed by a small spec helper (chunked-encoding headers stripped at load — raw replay of chunked captures breaks WebMock). Error responses (403/429/404/5xx/malformed/oversized) are synthesized in spec helpers, since capturing them live would mean burning the budget to zero on purpose.
**Consequences:** Contract specs assert against real GitHub bytes (the weak-ETag echo test uses the actual captured ETag); the capture cost 1 budget request total. The 304 capture also produced D-017's observation.

## D-016: One-shot ingestion via runner argument in the compose command

**Context:** The `ingest` service needs one-shot mode; the phase plan allowed an env flag or an argument.
**Decision:** `IngestRunner.new.run(once: true)` spelled out in the compose `command:`.
**Consequences:** The mode is visible exactly where the service is defined — no hidden env coupling between compose and app code. One-shot mode also skips signal traps and lets exceptions propagate, so verification runs fail loudly instead of backing off silently. Since the client returns failures as Result values rather than exceptions, one-shot mode also raises `IngestRunner::PollFailed` for any poll that isn't `:ok`/`:not_modified` — those two are the only zero-exit outcomes, so a rate-limited or erroring verification run deliberately exits nonzero (Phase 1 review fix).

## D-017: Observed — a real 304 arrived with a decremented X-RateLimit-Remaining

**Context:** The architecture leans on GitHub's documented behavior that conditional requests answered 304 don't count against the rate limit. During the Phase 1 fixture capture, the 200 returned `remaining: 59` and the immediate 304 replay returned `remaining: 58` — the conditional request appears to have been counted (single observation; could also be another client sharing the egress IP in that second).
**Decision:** Build to headers-as-source-of-truth rather than to documentation: the client mirrors whatever rate headers each response carries (including 304s), and the contract-test checklist line was adjusted from "304 → remaining unchanged" to "header-less 304 → unchanged; 304 rate headers → mirrored". Verify the trajectory across several 304s during end-of-phase verification runs.
**Consequences:** The persisted budget is correct either way — no code depends on 304s being free. If the observation holds, the *design margin* changes: polling at the 60s `X-Poll-Interval` would consume the entire 60/hr budget, leaving nothing for Phase 3 enrichment. Mitigation would be policy, not architecture (stretch the effective poll interval; the cadence already lives in one place, `IngestRunner`). Flagged for re-measurement before Phase 3 sets `ENRICHMENT_RESERVE` policy.
**Resolved (Phase 3):** re-measured and confirmed — 304s cost budget. See D-022 for the measurement and the resulting allocation.

## D-018: NUL-bearing payloads are scrubbed and marked, not dropped

**Context:** PostgreSQL `jsonb` cannot store NUL (U+0000) anywhere in a document, so a PushEvent whose payload contains one defeats byte-perfect raw persistence — and a single such row raised out of the whole-page `insert_all`, costing every valid event on the page (Phase 1 review finding).
**Decision:** The batch insert stays the fast path; on `StatementInvalid` the page falls back to savepointed per-row inserts, and a refused row is retried once with NUL stripped from every payload string (keys included) plus a top-level `"payload_scrubbed": true` marker and an `ingest.malformed` warn. Rows refused even after scrubbing count toward `malformed_skipped`; if *every* row is refused, the original batch error re-raises — an all-rows failure is a database problem, not a payload problem. A NUL inside the event *id* is rejected upfront as `invalid_event_id` instead: scrubbing an identifier would forge a new one.
**Consequences:** Raw fidelity is knowingly compromised for exactly the rows PG cannot store verbatim — detectable via the marker key and the warn log, and a NUL payload could never round-trip through `jsonb` anyway (the alternative was losing the row entirely). Savepoints (`requires_new: true`) keep a refused statement from aborting any wrapping transaction, including the transactional test suite. Cost: a poisoned page pays one failed batch statement plus one statement per row.

## D-019: GithubClient's clock:/http: params removed from the contract

**Context:** The spec's Public Interface listed `clock:` and `http:` as injectable wiring, but the implementation never read either — WebMock intercepts Net::HTTP globally (no transport seam needed) and nothing in the client reads a clock (`Time.at` converts header epochs; `Time.current` normalizes a date-form Retry-After at parse time). A labeled-injectable parameter wired to nothing is a trap: injecting a fake clock or transport silently did nothing (Phase 1 review finding).
**Decision:** Drop both params from the class and the spec signature rather than wire them.
**Consequences:** The contract signature is honest — `state:` is the only seam, and it is real. If a genuine transport or clock seam is ever needed, it gets added together with its consumer, not ahead of one.

## D-020: push_events modeling — the parser guarantees storability; reject, never coerce

**Context:** Story 2 wants push attributes queryable via plain SQL, extracted from attacker-influenceable payloads. The threat model requires length caps on extracted strings before persistence but fixes no numbers and leaves cap-vs-reject open. The structured insert also shares one transaction with the raw insert — necessarily so: the client's ETag advances the moment a 200 parses, so a crash that landed raw rows without structured rows would be a permanently torn state the feed never re-serves. Inside that shared transaction, a PG-refused structured row would take its raw row down with it.
**Decision:** `PushEventParser` is the single validation layer, and what it passes is guaranteed storable: string caps counted in characters (ref ≤ 255 — git's NAME_MAX for a loose-ref component; repository name ≤ 140 — 39-char owner + `/` + 100-char repo; login ≤ 64 — GitHub's 39 plus `[bot]`-suffix headroom, the `MAX_EVENT_ID_LENGTH` idiom), strict 40-hex SHAs, ids bounded to PG bigint, `created_at` bounded to years 2000–9999. Anything unverifiable is rejected as malformed — structured row skipped, raw row kept, one `ingest.structured_skipped` warn — never truncated or coerced, because truncating a ref/SHA/login stores a forged identifier (D-018's id reasoning). NUL in an extracted field is malformed for the same reason; NUL elsewhere in the payload still triggers only D-018's raw scrub and the (clean) structured row persists — the two outcomes are independent. `before_sha` is the only nullable column (absent `before` = first push to the ref; present-but-invalid is still malformed). Columns carry no DB `limit:` — the parser is the one source of truth, matching how raw_events bounds its id in code. The structured insert runs for every parsed-ok row, not just newly inserted raw ones, with `ON CONFLICT DO NOTHING`, so re-ingest self-heals raw rows that predate push_events or return via overlapping poll windows. `push_events_new` keeps counting new raw rows; the new `structured_skipped` count is an overlay, not part of the seen = new + duplicates + non-push + malformed partition.
**Consequences:** A parsed-ok row can never be the statement that poisons the shared savepoint, so the D-018 fallback needed zero changes. Hostile-but-raw-storable payloads get no structured coverage — visible via `structured_skipped` and its warn, rebuildable from raw once handled. Strict 40-hex means SHA-256 pushes (if GitHub ever serves them) are rejected until a one-regex change plus a rebuild from raw (D-004 guarantees that path). If a parser bug ever lets an unstorable value through, the row degrades to D-018's `row_rejected` and its raw row is lost too — the same blast radius as an unstorable raw row today, accepted rather than adding machinery.

## D-021: Phase 2 review remediations — encoding joins storability; telemetry must match persistence

**Context:** Multi-angle review of the Phase 2 PR found the storability contract had an encoding hole and the new overlay telemetry could contradict what was actually persisted. Verified empirically: the json gem passes lone-surrogate escapes and raw invalid bytes through as invalid-UTF-8 Ruby strings; `Regexp#match?` raises `ArgumentError` on such strings (the parse loop would crash before any insert); and jsonb serialization of such a payload raises `JSON::GeneratorError` client-side — not an `ActiveRecord::StatementInvalid`, so the D-018 per-row fallback never engaged. Net effect: one hostile byte sequence cost the entire page, permanently, because the client's ETag had already advanced. Separately: an in-page repeated id was parsed/warned/counted per occurrence while persistence is per unique id; a parse-rejected row that PG also refused was double-counted (`structured_skipped` + `malformed_skipped`) after a warn that had already promised its raw row landed; a transient DB error during the per-row fallback could stamp a false `payload_scrubbed` marker onto an innocent payload; the parser would happily re-parse a D-018-scrubbed payload, so the documented rebuild-from-raw could mint identifiers the original ingest refused; and D-020 justified the 255 ref cap with the wrong fact.
**Decision:** (1) Encoding validity is part of storability: the shared `StorableString` predicate (used by both the event-id check and the parser's string fields) requires valid UTF-8; `sha`/`timestamp` check `valid_encoding?` before touching a regex; `JSON::GeneratorError` is handled exactly like `StatementInvalid` on every insert path; and the D-018 scrub also repairs invalid bytes (`String#scrub` → U+FFFD) under the same `payload_scrubbed` marker. (2) The parser rejects any event carrying that marker (`payload_scrubbed` reason): a scrubbed payload may carry coerced identifiers, so rebuilds must not trust it — scrubbed raw rows are represented by their live-ingest structured rows or not at all. (3) In-page repeats are skipped before parsing, so every id is parsed, warned, and counted at most once per ingest; repeats still count as duplicates, keeping the partition exact. (4) `structured_skipped` warns/counts are settled after the raw insert and exclude rejected rows — the warn's "raw row kept" meaning is true every time it fires, and the overlay never overlaps `malformed_skipped`. (5) Only data-shaped refusals earn the scrub and marker — `JSON::GeneratorError`, or a `StatementInvalid` whose cause is a `PG::DataException` (SQLSTATE class 22: NUL escapes, invalid encoding, numeric overflow); every other per-row failure (contention, connection blips, unforeseen refusals) retries unmodified. The first cut enumerated transient classes instead; the Phase 2 security review (LOW) showed `ActiveRecord::ConnectionFailed` slipped that list, so the classification was inverted to fail safe — an unenumerated error can no longer stamp a false marker. (6) `created_at` must match GitHub's exact serialized shape (whole seconds, explicit `Z`/`±hh:mm`) and round-trip verbatim through `Time.iso8601` — zone-less values (environment-dependent instants) and calendar-normalized values (Feb 30 → Mar 2, hour 24, leap seconds) are rejected, not coerced. (7) Correction to D-020: the ref cap's real guarantor is GitHub's server-side GH005 limit ("refs longer than 255 bytes are not allowed"), not git's NAME_MAX (which bounds one path component, not the whole refname) — the bound stands, the citation was wrong.
**Consequences:** A page containing hostile bytes now degrades to per-row handling — one row's fate, never thirty. Encoding-poisoned rows behave exactly like NUL rows: scrubbed-and-marked raw, structured projection only when every extracted field was untouched. Legitimate fractional-second or exotic-offset timestamps would be rejected until the pattern is widened (a one-line change; GitHub serves neither today). Same-id-different-payload re-serves (possible only during upstream feed incidents) can still leave a push_events row derived from a later serving than the stored raw copy — accepted: raw keeps the first serving, `ON CONFLICT DO NOTHING` never rewrites either side, and a rebuild comparison would surface the divergence. The structured write remains insert-ignore, not a value-refreshing upsert — the phase plan's word "upsert" is precisely that.

## D-022: Measured — 304s cost budget; poll floor stretched to 120s, enrichment gets the remainder above a reserve of 5

**Context:** D-017's single Phase 1 observation (a 304 that decremented `X-RateLimit-Remaining`) needed re-measurement before Phase 3 could allocate the budget between polling and enrichment. A deliberate 6-request session at the start of a fresh window (2026-07-09 00:06 UTC, one client on the egress IP) produced a clean trajectory: `/events` 200 → `used: 1`, ETag-replay **304 → `used: 2`**, replay again (feed had moved) 200 → `used: 3`; then `/users/octocat` 200, its ETag-replay **304 → `used: 4`**, `/repos/octocat/Hello-World` 200 → `used: 5` — all against one `core` bucket and one reset epoch, with `used` matching the session's request count exactly (no IP-sharing noise this time). Conclusion: on the unauthenticated tier, **every request counts, 304s included**, on both `/events` and resource endpoints — GitHub's "conditional requests are free" documentation does not hold here. Side observation: one response (`/users` 200) carried desynced counters (`used: 1`, its own reset epoch) from what was evidently a lagging shard, while the next response proved the request had counted in the real bucket — validating D-014/D-017's headers-as-source-of-truth, last-write-wins mirror: it can read transiently optimistic values and self-corrects on the next response.
**Decision:** Polling keeps priority (D-006) but is capped by policy: `IngestRunner::POLL_FLOOR` raised 10 → **120s** (~30 polls/hr; a served `X-Poll-Interval` above the floor still wins). Enrichment spends the remainder down to `ENRICHMENT_RESERVE = 5` (per the client spec § Budget), i.e. ~25 enrichment fetches/hr sustained. Conditional requests are kept for correctness (skip re-persisting unchanged bodies), not for budget.
**Consequences:** The firehose sample gets coarser — one page per 2 minutes instead of one per minute — which D-009 already frames as acceptable (the dataset is an explicit sample). Enrichment throughput of ~25 entities/hr is sufficient given the 24h TTL and the firehose's heavy actor repetition (D-005): steady state converges on unique-entities-per-day, and the durable queue absorbs bursts. The reserve of 5 keeps headroom so a poll is never starved by enrichment, even with mirror lag. Gave up: minute-level sampling resolution and the comfort of "free" idle polling — neither survives contact with the measured API. *Phase 3 end-to-end addendum:* the shard desync recurred at scale — the mirror bounced from 5 straight back to 58 across consecutive responses, letting enrichment optimistically overspend until GitHub's real enforcement answered 403 — and the system absorbed it exactly as designed: jobs and poller parked to the reset, the backlog drained the fresh window to the reserve in under a minute, re-parked to the next reset, zero failures. The reserve plus headers-as-source-of-truth is the contract; the shards' bookkeeping is not.

## D-023: Enrichment state machine — five states, transactional claim/enqueue, identity-only stub upserts

**Context:** Solid Queue has no native enqueue-uniqueness, so in-flight dedup had to be application state. The phase plan was internally inconsistent about that state: its migration task named three `fetch_status` values, its dedup task required a fourth (`enqueued`), the client spec's caller contract requires marking guard refusals, and its claim predicate (`WHERE fetch_status='pending'`) could never re-enrich an entity after TTL expiry — contradicting its own exit criterion (≤1 fetch *per TTL window* implies a fetch in the next window).
**Decision:** Five states: `pending → enqueued → fetched | not_found | rejected`, with `enqueued → pending` on retry exhaustion or unexpected job error (release is guarded on `enqueued`, so a racing terminal write is never stomped). The claim is one atomic UPDATE folding the 24h TTL gate into the dedup: claimable from `pending` or from `fetched` with `fetched_at` past the TTL, never without a stored `url`. Claim UPDATE and job INSERT commit or roll back together — Solid Queue rows live in the same primary database (D-010's concrete payoff) and `enqueue_after_transaction_commit = false` keeps the enqueue inline — so there is no window where the status says enqueued but no job exists, or vice versa. Parking (budget gate or rate limit) re-enqueues a *fresh* scheduled job rather than `retry_job`: an expected budget wait must never consume the transient-retry cap, and the record deliberately stays `enqueued` while parked — that is the dedup while waiting out the window. The budget gate carries a stale-mirror escape: once the observed `reset_at` has passed, jobs fetch optimistically, because after exhaustion nothing else would ever refresh the mirror (without it, exit criterion "park and later run" deadlocks). Stub upserts are a genuine `DO UPDATE` limited to identity columns (`login`/`full_name`, `url`, `avatar_url`) — renames win, enrichment columns are never in the update set, and `url` is dropped from the update set when the guard refused it, so a hostile event can never null a previously stored good URL. This "upsert" is deliberately not D-021's insert-ignore; the two words mean different things for push_events and stubs. Guard layering: ingest pre-validates payload URLs (security log at the earliest layer; refused → `url` NULL, unclaimable but still `pending` so a later good-URL event can heal the entity), and the client re-checks at fetch time — jobs consume `:rejected_url` as the terminal `rejected` state. One empirical correction the committed real fixture forced: GitHub serves bot actor URLs with raw square brackets (`.../users/github-actions[bot]`), which RFC 3986 forbids and `URI.parse` rejects — the queuer percent-escapes exactly `[` and `]` before the guard, since the escaped form names the same resource and encoded brackets cannot smuggle authority tricks. Bots dominate the firehose; rejecting them would have silently excluded the most common actors from enrichment.
**Consequences:** Exactly-once enqueue per claimable window under any concurrency; enrichment staleness bounded by the TTL; hostile enrichment bodies reuse the D-018 scrub-and-mark path (`JsonScrubber`, extracted from EventIngester unchanged). Residual risk accepted: a SIGKILL mid-job leaves `enqueued` plus a re-dispatchable claimed execution — Solid Queue's process recovery re-runs it, and every persist is an idempotent `update!`. Enrichment enqueueing is best-effort by design: a queuer failure after raw persistence logs `enrich.enqueue_failed` and is absorbed, because the ETag has already advanced and the firehose's repetition plus the TTL re-claim self-heal any missed enqueue.

---

_Append new entries below as D-00N during each phase._
