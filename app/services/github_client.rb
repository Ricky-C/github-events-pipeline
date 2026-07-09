require "net/http"

# The single chokepoint for all GitHub API traffic (CLAUDE.md Golden Rule 3),
# built to the binding contract in docs/specs/GITHUB-CLIENT.md. The client
# returns facts as Result values; callers make all policy — it never sleeps,
# never retries, and never raises for expected outcomes.
class GithubClient
  API_HOST = "api.github.com"
  EVENTS_URL = "https://#{API_HOST}/events".freeze
  VERSION = "0.1"

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10
  MAX_BODY_BYTES = 5 * 1024 * 1024
  MAX_REDIRECTS = 1

  # Real ETags are ~40 characters; the cap bounds what a response header can
  # push into a text column, the way MAX_EVENT_ID_LENGTH bounds a payload id
  # (docs/THREAT-MODEL.md length validation).
  MAX_ETAG_LENGTH = 255

  # Header integers reach `integer` and `timestamp` columns. A value the
  # column cannot store raises out of `persist`, which runs after *every*
  # response — so one implausible header would brick every later call, not
  # just the one that carried it. The epoch bound is D-020's YEAR_RANGE idiom
  # (years 2000-9999); the integer bound is PostgreSQL's `integer` range.
  RESET_EPOCH_RANGE = (Time.utc(2000).to_i..Time.utc(9999, 12, 31).to_i).freeze
  INT_COLUMN_RANGE = (0..(2**31 - 1)).freeze

  REQUEST_HEADERS = {
    # GitHub rejects requests without a User-Agent.
    "User-Agent" => "github-events-pipeline/#{VERSION}",
    "Accept" => "application/vnd.github+json",
    "X-GitHub-Api-Version" => "2022-11-28"
  }.freeze

  NETWORK_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout,
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
    SocketError, OpenSSL::SSL::SSLError, EOFError, IOError
  ].freeze

  # Internal control flow only: raised mid-stream to abort an over-cap read
  # (closing the connection), caught before the public surface. Carries the
  # response so its rate headers can still be mirrored — the spec requires
  # bookkeeping after every real response, and this one cost budget.
  class BodyTooLarge < StandardError
    attr_reader :response

    def initialize(response)
      @response = response
      super("response body over cap")
    end
  end
  private_constant :BodyTooLarge

  def initialize(state: RateLimitState)
    @state = state
  end

  # GET /events with the persisted ETag. A 304 costs nothing to parse, but it
  # does cost budget: GitHub exempts a conditional request from the primary
  # rate limit only when it carries an Authorization header, and this client
  # never sends one (D-017, D-022). The mirror records whatever the response
  # headers claim.
  def poll_events
    perform(URI(EVENTS_URL), etag: @state.current&.etag, events: true)
  end

  # SSRF-guarded GET of a payload-provided URL. Refusal makes zero requests.
  def fetch_resource(url, etag: nil)
    verdict, checked = UrlGuard.check(url)
    return Result.new(status: :rejected_url, error: checked) if verdict == :rejected

    perform(checked, etag: etag, events: false)
  end

  def budget
    row = @state.current
    Budget.new(row&.remaining, row&.reset_at, row&.updated_at)
  end

  private

  def perform(uri, etag:, events:)
    redirects = 0
    loop do
      response, body = request(uri, etag)
      persist(response, events: events)
      status = response.code.to_i

      unless redirect?(status)
        result = map(status, response, body, events: events)
        # The stored ETag advances only past a page that actually parsed —
        # persisted any earlier, the next conditional poll would 304 against
        # content that was never ingested and silently skip those events. An
        # unstorable ETag is already nil by here, so it cannot advance either.
        @state.record!(etag: result.etag) if events && result.ok? && result.etag
        return result
      end

      # GitHub 301s renamed users/repos. Follow at most one hop, and only
      # through the same guard as the original URL — a redirect is
      # attacker-influenceable data like any other payload field.
      location = response["location"]
      if location.nil? || location.empty?
        return Result.new(status: :transient_error, error: "redirect #{status} without location")
      end
      return Result.new(status: :transient_error, error: "redirect limit exceeded") if redirects >= MAX_REDIRECTS

      # RFC 7231 permits a relative Location; resolve it against the request
      # URI before guarding so a same-origin relative redirect isn't misread
      # as a scheme change. An absolute Location wins the join unchanged.
      begin
        resolved = URI.join(uri, location)
      rescue URI::Error, ArgumentError
        return Result.new(status: :transient_error, error: "unresolvable redirect location")
      end

      verdict, checked = UrlGuard.check(resolved)
      return Result.new(status: :rejected_url, error: "redirect target refused: #{checked}") if verdict == :rejected

      redirects += 1
      uri = checked
    end
  rescue BodyTooLarge => e
    persist(e.response, events: events) if e.response
    Result.new(status: :transient_error, error: "response body over #{MAX_BODY_BYTES} bytes")
  rescue *NETWORK_ERRORS => e
    Result.new(status: :transient_error, error: "#{e.class}: #{e.message}")
  end

  def redirect?(status)
    (300..399).cover?(status) && status != 304
  end

  def request(uri, etag)
    get = Net::HTTP::Get.new(uri)
    REQUEST_HEADERS.each { |name, value| get[name] = value }
    # Stored verbatim, echoed verbatim: GitHub's ETags are weak (W/"...")
    # and stripping the prefix would silently defeat conditional requests.
    get["If-None-Match"] = etag if etag

    Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                    open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      http.request(get) do |response|
        return [ response, read_capped(response) ]
      end
    end
  end

  def read_capped(response)
    raise BodyTooLarge.new(response) if response.content_length.to_i > MAX_BODY_BYTES

    body = +""
    response.read_body do |chunk|
      body << chunk
      # Content-Length can lie or be absent (chunked); the stream check is
      # the real cap. Raising aborts the read and closes the connection.
      raise BodyTooLarge.new(response) if body.bytesize > MAX_BODY_BYTES
    end
    body
  end

  # Mirror rate headers after every real HTTP response, including errors
  # and redirect hops. Partial upsert: only observed columns are written,
  # so header-less responses persist nothing and resource fetches never
  # clobber the /events etag/poll_interval. The ETag itself is persisted
  # in perform, and only once the body has parsed.
  def persist(response, events:)
    attrs = read_rate(response).compact
    if events && (interval = poll_interval(response))
      attrs[:poll_interval] = interval
    end
    @state.record!(attrs) unless attrs.empty?
  end

  def map(status, response, body, events:)
    rate = read_rate(response)
    case status
    when 200..299
      Result.new(status: :ok, body: JSON.parse(body), etag: storable_etag(response),
                 poll_interval: events ? poll_interval(response) : nil, rate: rate)
    when 304
      Result.new(status: :not_modified,
                 poll_interval: events ? poll_interval(response) : nil, rate: rate)
    when 403, 429
      # All 403s map to :rate_limited — primary-limit exhaustion and
      # secondary/abuse detection both mean "stop asking until told".
      Result.new(status: :rate_limited, rate: rate, retry_after: retry_after_from(response))
    when 404, 410
      Result.new(status: :not_found, rate: rate)
    when 401
      # Impossible without an auth header, and this project must never have
      # one — log loudly per spec so a stray credential is caught fast.
      Rails.logger.error(component: "github_client", event: "auth.unexpected_401",
                         msg: "401 from an unauthenticated request — check for a stray auth header")
      Result.new(status: :transient_error, error: "unexpected 401", rate: rate)
    else
      Result.new(status: :transient_error, error: "HTTP #{status}", rate: rate)
    end
  rescue JSON::ParserError => e
    Result.new(status: :transient_error, error: "unparseable body: #{e.class}", rate: rate)
  end

  # This client is the single validation layer for response headers, the way
  # PushEventParser is for payload fields (D-020): everything it emits — in a
  # Result or into the mirror — is already storable, so no caller has to
  # re-check and the two layers cannot drift. An unstorable ETag becomes nil,
  # which only means the next fetch is unconditional (D-024).
  def storable_etag(response)
    etag = response["etag"]
    return etag if etag.nil? || StorableString.valid?(etag, max: MAX_ETAG_LENGTH)

    # Never the header bytes themselves: they are why this line exists.
    Rails.logger.warn(component: "github_client", event: "etag.unstorable",
                      bytesize: etag.bytesize)
    nil
  end

  # One reader for the rate headers so the persisted mirror and Result#rate
  # can never disagree about the same response. Values stay nil-able here
  # (the Result contract exposes unknowns); persist compacts its copy. An
  # out-of-range header reads as unknown rather than raising on the way to a
  # column that cannot hold it.
  def read_rate(response)
    reset = bounded_header(response, "x-ratelimit-reset", RESET_EPOCH_RANGE)
    { remaining: bounded_header(response, "x-ratelimit-remaining", INT_COLUMN_RANGE),
      reset_at: reset && Time.at(reset).utc }
  end

  def poll_interval(response)
    bounded_header(response, "x-poll-interval", INT_COLUMN_RANGE)
  end

  def bounded_header(response, name, range)
    value = int_header(response, name)
    value if value && range.cover?(value)
  end

  def int_header(response, name)
    value = response[name]
    # Base 10 always: Integer's radix auto-detection would read a
    # leading-zero header as octal ("010" -> 8) or reject it ("09" -> nil).
    value && Integer(value, 10, exception: false)
  end

  # GitHub sends Retry-After as delta-seconds, but RFC 7231 also permits the
  # HTTP-date form (a proxy or CDN edge may rewrite it) — normalize both to
  # integer seconds so the caller's sleep math never sees a date.
  def retry_after_from(response)
    value = response["retry-after"]
    return nil unless value

    seconds = Integer(value, 10, exception: false)
    return seconds if seconds

    date = begin
      Time.httpdate(value)
    rescue ArgumentError
      nil
    end
    date && [ (date - Time.current).ceil, 0 ].max
  end
end
