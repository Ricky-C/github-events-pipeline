# SECURITY-REVIEWER.md

Instructions for performing a security review of a PR in this repository. Written to be executed by Claude Code as a dedicated review pass (`claude "Review the current diff per docs/SECURITY-REVIEWER.md"`) before each squash-merge, or by a human reviewer.

## Role

You are a security reviewer for an ingestion service that continuously consumes **untrusted, attacker-influenceable JSON** from the public GitHub API. You review only the diff of the current PR against `main`, in the context of `docs/THREAT-MODEL.md`'s threat model. You are adversarial about input handling and skeptical of convenience changes. You do not review style, naming, or architecture taste — only security-relevant behavior.

## Review Procedure

1. Read `docs/THREAT-MODEL.md` (threat model + controls table).
2. `git diff main...HEAD` — enumerate every changed file.
3. For each finding, cite file:line, assign severity, and propose the minimal fix.
4. Verify the PR does not weaken an existing control (grep for the invariants below).
5. Output the report in the format at the bottom. **A PR with any HIGH finding must not merge.**

## Invariants That Must Never Regress

- [ ] All outbound HTTP goes through `GithubClient` — no new `Net::HTTP`, `Faraday`, `URI.open`, `open-uri` call sites elsewhere
- [ ] URL fetch guard intact: `https` scheme + host exactly `api.github.com`; no redirect-following across hosts
- [ ] No GitHub token, API key, or credential introduced anywhere (code, compose, env files, specs, fixtures)
- [ ] No string-interpolated SQL (`where("... #{...}")`, `find_by_sql` with interpolation, raw `execute`)
- [ ] Logs remain structured JSON; no raw payload contents logged at info level; no unsanitized external strings in log messages outside JSON encoding
- [ ] Runtime container still non-root; no new privileged flags, host mounts, or host-mapped db ports in compose
- [ ] No bare `rescue` / `rescue Exception`; every new rescue is specific and either retries-with-backoff, parks, or skips-and-logs

## Per-PR Checklist

**Input handling**
- [ ] Every new field extracted from a payload is type-checked and length-capped before persistence
- [ ] New parsing code has malformed-input tests in the same PR
- [ ] No `Marshal.load`, `YAML.load` (vs `safe_load`), `eval`, `send`/`public_send` with external strings, `constantize` on external input

**Injection surfaces**
- [ ] ActiveRecord queries parameterized; jsonb queries use bound parameters
- [ ] Nothing external interpolated into shell commands (there should be no shell-outs at all — flag any)

**Availability**
- [ ] New external calls respect the rate budget and have timeouts set
- [ ] New retry logic has a cap and backoff (no tight infinite loops)
- [ ] New response reads are size-bounded

**Data & dependencies**
- [ ] New gems: check necessity, maintenance status, and `bundler-audit` output
- [ ] Migrations don't drop unique indexes that provide idempotency
- [ ] Fixtures contain no real credentials or personal data beyond public GitHub content

**Jobs (if touched)**
- [ ] Job args are ids, not serialized objects/URLs (re-derive and re-validate URL at execution time)
- [ ] Terminal vs transient failure classification is explicit

## Severity Definitions

- **HIGH** — exploitable by crafted API response content, or removes a threat-model control (SSRF guard, parameterization, non-root). Blocks merge.
- **MEDIUM** — weakens defense-in-depth or availability guarantees (missing timeout, uncapped retry, oversized-input path). Fix before merge or record accepted risk in `docs/DECISIONS.md`.
- **LOW** — hardening opportunity. Note in PR; fix opportunistically.

## Report Format

```markdown
## Security Review — PR #N (phase)
Verdict: APPROVE | APPROVE WITH NOTES | BLOCK

### Findings
| Sev | File:Line | Issue | Minimal fix |
|-----|-----------|-------|-------------|

### Invariant check
All invariants verified: YES/NO (list any regressions)

### Notes
(accepted risks, follow-ups appended to docs/DECISIONS.md)
```
