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
  # (closing the connection), caught before the public surface.
  class BodyTooLarge < StandardError; end
  private_constant :BodyTooLarge

  # http: is a transport override kept for contract fidelity; specs don't
  # inject it because WebMock intercepts Net::HTTP globally.
  def initialize(state: RateLimitState, clock: Time, http: nil)
    @state = state
    @clock = clock
    @http = http
  end

  # GET /events with the persisted ETag. A 304 costs nothing to parse and
  # (per GitHub's documented behavior) should not consume budget — the
  # persisted mirror simply records whatever the response headers claim.
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
        return map(status, response, body, events: events)
      end

      # GitHub 301s renamed users/repos. Follow at most one hop, and only
      # through the same guard as the original URL — a redirect is
      # attacker-influenceable data like any other payload field.
      location = response["location"]
      return Result.new(status: :transient_error, error: "redirect #{status} without location") unless location
      return Result.new(status: :transient_error, error: "redirect limit exceeded") if redirects >= MAX_REDIRECTS

      verdict, checked = UrlGuard.check(location)
      return Result.new(status: :rejected_url, error: "redirect target refused: #{checked}") if verdict == :rejected

      redirects += 1
      uri = checked
    end
  rescue BodyTooLarge
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
    raise BodyTooLarge if response.content_length.to_i > MAX_BODY_BYTES

    body = +""
    response.read_body do |chunk|
      body << chunk
      # Content-Length can lie or be absent (chunked); the stream check is
      # the real cap. Raising aborts the read and closes the connection.
      raise BodyTooLarge if body.bytesize > MAX_BODY_BYTES
    end
    body
  end

  # Mirror rate headers after every real HTTP response, including errors
  # and redirect hops. Partial upsert: only observed columns are written,
  # so header-less responses persist nothing and resource fetches never
  # clobber the /events etag/poll_interval.
  def persist(response, events:)
    attrs = {}
    if (remaining = int_header(response, "x-ratelimit-remaining"))
      attrs[:remaining] = remaining
    end
    if (reset = int_header(response, "x-ratelimit-reset"))
      attrs[:reset_at] = Time.at(reset).utc
    end
    if events
      if (interval = int_header(response, "x-poll-interval"))
        attrs[:poll_interval] = interval
      end
      attrs[:etag] = response["etag"] if response["etag"]
    end
    @state.record!(attrs) unless attrs.empty?
  end

  def map(status, response, body, events:)
    rate = rate_from(response)
    case status
    when 200..299
      Result.new(status: :ok, body: JSON.parse(body), etag: response["etag"],
                 poll_interval: events ? int_header(response, "x-poll-interval") : nil, rate: rate)
    when 304
      Result.new(status: :not_modified,
                 poll_interval: events ? int_header(response, "x-poll-interval") : nil, rate: rate)
    when 403, 429
      # All 403s map to :rate_limited — primary-limit exhaustion and
      # secondary/abuse detection both mean "stop asking until told".
      Result.new(status: :rate_limited, rate: rate, retry_after: int_header(response, "retry-after"))
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

  def rate_from(response)
    reset = int_header(response, "x-ratelimit-reset")
    { remaining: int_header(response, "x-ratelimit-remaining"),
      reset_at: reset && Time.at(reset).utc }
  end

  def int_header(response, name)
    value = response[name]
    value && Integer(value, exception: false)
  end
end
