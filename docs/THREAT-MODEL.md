# THREAT-MODEL.md

Security posture for an internal, unattended ingestion service. Scoped honestly: this is not a public-facing app, but it consumes untrusted input from the internet continuously, which is enough to warrant a real threat model.

## Threat Model

**Assets:** database integrity, service availability, host it runs on.
**Exposure:** no inbound network surface (no web endpoints in ingestion path); all risk arrives via *outbound* fetches and the *content* of API responses.
**Trust boundary:** everything returned by api.github.com is untrusted user-generated content — event payloads contain attacker-controllable strings (repo names, refs, logins) and attacker-influenced URLs.

### Threats & Controls

| # | Threat | Control |
|---|---|---|
| 1 | **SSRF via payload URLs.** Enrichment follows URLs found in event payloads; a crafted/mutated payload could point at internal services or metadata endpoints. | Allowlist: fetch only if scheme is `https` and host is exactly `api.github.com`. Reject + `security.url_rejected` log otherwise. No redirects followed cross-host. The bracket normalization that makes GitHub's bot URLs parseable lives **inside** the guard, so every caller — ingest pre-validation, a stored URL, a redirect `Location` — gets the same URL parsed and the same URL requested (D-025). An *absent* URL is not a refusal and raises no alarm. |
| 2 | **Injection via payload strings.** Refs/logins/repo names are attacker-chosen; risk of SQL injection, log injection, or downstream template injection. | Parameterized queries only (ActiveRecord defaults; no string-interpolated SQL anywhere). JSON-encoded structured logs neutralize newline/control-char log injection. Length caps and UTF-8 validity checks (NUL and invalid bytes rejected) on extracted string fields before persistence (D-020, D-021). Response **headers** are bounded too: an unstorable `ETag` is dropped and rate-header integers outside their column's range read as unknown, so no unvalidated external value ever reaches a bind (D-024). Storability is judged on a value's **bytes as UTF-8**, never on the encoding its `String` happens to carry: Net::HTTP tags headers `ASCII-8BIT`, under which `valid_encoding?` is vacuously true and a character cap silently counts bytes (D-025). |
| 3 | **Resource exhaustion / poisoned payloads.** Oversized or deeply-nested JSON; a firehose page designed to balloon storage. | Response body size cap in `GithubClient`; parse with standard `JSON.parse` (no `eval`-style loading); jsonb column with payload size guard; append-only tables are bounded by upstream page size × poll rate. |
| 4 | **Self-inflicted DoS / IP reputation.** Aggressive polling gets the IP throttled or blocked. | `X-Poll-Interval` compliance under a 120s floor, budget with reserve, jittered sleeps, and every rate-derived wait clamped to the one-hour window so a bad header can neither hot-loop us nor blind us (D-024). Rate-limit discipline is a security control here, not just politeness. |
| 5 | **Supply chain.** Malicious/vulnerable gems or base images. | `Gemfile.lock` committed; `bundler-audit` and `brakeman` runnable in the test stage; slim, pinned base image; Dependabot enabled on the repo. |
| 6 | **Secrets leakage.** | **This system requires zero secrets by design** (unauthenticated API is an exercise constraint). DB credentials are compose-internal defaults, never real. `.env` git-ignored; Gitleaks-clean history. Anyone adding a secret must update this file first. |
| 7 | **Container escape / blast radius.** | Non-root user in runtime image; multi-stage build (no build tools in runtime layer); no privileged flags, no docker socket mounts; db not port-mapped to host by default. |

## Data Handling

All ingested data is **public** GitHub activity — no PII beyond what users publish publicly, no credentials, no proprietary data. Raw payloads are retained deliberately (audit/replay requirement). Logs never include full payloads at info level, keeping `docker compose logs` output bounded and clean.

## Security Testing Hooks

- Unit specs: SSRF guard allow/deny table; parser length-cap behavior; malformed-input matrix; unstorable response headers (ETag — including the `ASCII-8BIT` tag Net::HTTP actually delivers — and out-of-range rate integers); non-object enrichment bodies refused before persist
- `bundler-audit check --update` and `brakeman -q` wired into the test container (advisory, non-blocking for the exercise; would gate CI in production)
- Fixture-based negative tests: hostile URL payload (including IPv6 literals through the bracket escape), oversized string payload

## Explicit Non-Goals (right-sized scope)

- No authn/authz — no inbound surface exists
- No encryption-at-rest config — public data, local dev Postgres
- No network policies/egress proxying — would be the production next step for control #1's defense-in-depth
- No WAF/IDS — nothing inbound to protect

These are recorded so the design brief's scope decisions read as judgment, not omission.
