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
      uri = URI.parse(url.to_s)
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
  end
end
