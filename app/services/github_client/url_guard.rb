class GithubClient
  # SSRF pre-flight for payload-provided URLs (docs/THREAT-MODEL.md,
  # docs/DECISIONS.md D-008): enrichment targets arrive inside untrusted
  # event payloads, so nothing is fetched unless the URL is exactly
  # https://api.github.com with no tricks. A refusal makes zero requests.
  module UrlGuard
    ALLOWED_HOST = "api.github.com"
    ALLOWED_PORT = 443

    module_function

    # => [ :ok, URI::HTTPS ] | [ :rejected, reason ]
    # The returned URI object — not the raw string — must be what gets
    # requested, so parse-vs-request disagreement can't smuggle a host.
    def check(url)
      uri = URI.parse(normalize_brackets(url))
      return [ :rejected, "scheme is not https" ] unless uri.is_a?(URI::HTTPS)
      return [ :rejected, "userinfo present" ] unless uri.userinfo.nil?
      return [ :rejected, "host is not #{ALLOWED_HOST}" ] unless uri.host&.downcase == ALLOWED_HOST
      return [ :rejected, "port override" ] unless uri.port == ALLOWED_PORT
      return [ :rejected, "path traversal" ] if uri.path.split("/").include?("..")

      [ :ok, uri ]
    rescue URI::InvalidURIError, ArgumentError
      # URI.parse raising (control chars, malformed escapes) is itself a
      # rejection, not an error — no request was ever going to be made.
      [ :rejected, "unparseable URL" ]
    end

    # GitHub serves bot actor URLs with raw square brackets
    # (.../users/github-actions[bot]) — RFC 3986 forbids them, so URI.parse
    # (and therefore the guard) rejects the URL as served. Percent-encode
    # exactly those two characters: the escaped form names the same resource
    # and GitHub accepts it. Escaping the whole URL is safe because no bracket
    # survives it: RFC 3986 allows `[`/`]` only as the delimiters of an
    # IP-literal host, and `%5B`/`%5D` contain none of `: @ / ? #`, so the
    # substitution can neither introduce nor remove an authority boundary. The
    # authority can then only be a reg-name or IPv4 — never an IPv6 literal —
    # and a host that held a bracket only grows further from `api.github.com`.
    # Idempotent, too: an already-encoded `%5B` is untouched. Bots dominate the
    # firehose (D-005); rejecting them would exclude the most common actors
    # from enrichment (D-023, D-024).
    #
    # It belongs to the guard, not to any one caller: whatever the guard parsed
    # must be what the client requests, so ingest pre-validation and the
    # fetch-time re-check of a stored URL cannot disagree (D-025).
    #
    # It does *not* reach a redirect Location. `perform` resolves that against
    # the request URI with `URI.join` before calling the guard, and `URI.join`
    # refuses raw brackets itself — so a 301 pointing at a bracketed URL is a
    # `:transient_error`, never a fetch. Fail-closed, and left that way: making
    # the redirect path follow bot renames means normalizing an
    # attacker-influenced header before it is resolved, which is a change to
    # argue for on its own evidence, not a side effect of this one.
    def normalize_brackets(url)
      url.to_s.gsub("[", "%5B").gsub("]", "%5D")
    end
  end
end
