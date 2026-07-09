require "rails_helper"

# Contract checklist coverage for /events polling
# (docs/specs/GITHUB-CLIENT.md § Contract Test Checklist).
RSpec.describe GithubClient, "#poll_events" do
  subject(:client) { described_class.new }

  let(:events_url) { "https://api.github.com/events" }
  let(:fixture_etag) { GithubFixtures.header(:events_200, "etag") }
  let(:fixture_remaining) { GithubFixtures.header(:events_200, "x-ratelimit-remaining").to_i }
  let(:fixture_reset) { Time.at(GithubFixtures.header(:events_200, "x-ratelimit-reset").to_i).utc }
  let(:fixture_interval) { GithubFixtures.header(:events_200, "x-poll-interval").to_i }

  it "sends UA, Accept, and API-version headers on every request" do
    stub = stub_request(:get, events_url)
      .with(headers: {
        "User-Agent" => "github-events-pipeline/#{GithubClient::VERSION}",
        "Accept" => "application/vnd.github+json",
        "X-GitHub-Api-Version" => "2022-11-28"
      })
      .to_return(GithubFixtures.response(:events_200))

    client.poll_events
    expect(stub).to have_been_requested
  end

  it "returns :ok with the parsed body on 200" do
    stub_request(:get, events_url).to_return(GithubFixtures.response(:events_200))

    result = client.poll_events
    expect(result).to be_ok
    expect(result.body).to eq(GithubFixtures.json_body(:events_200))
  end

  it "does not send If-None-Match before any ETag has been stored" do
    stub_request(:get, events_url).to_return(GithubFixtures.response(:events_200))

    client.poll_events
    expect(
      a_request(:get, events_url).with { |req| !req.headers.key?("If-None-Match") }
    ).to have_been_made
  end

  it "stores the weak ETag from a 200 and echoes it byte-identical on the next poll" do
    stub_request(:get, events_url).to_return(GithubFixtures.response(:events_200))
    client.poll_events

    # Real captured ETag is weak — the W/ prefix must survive storage
    # untouched or every conditional request silently misses.
    expect(fixture_etag).to start_with('W/"')
    expect(RateLimitState.current.etag).to eq(fixture_etag)

    conditional = stub_request(:get, events_url)
      .with(headers: { "If-None-Match" => fixture_etag })
      .to_return(GithubFixtures.response(:events_304))

    result = client.poll_events
    expect(conditional).to have_been_requested
    expect(result).to be_not_modified
  end

  it "parses and exposes x-poll-interval" do
    stub_request(:get, events_url).to_return(GithubFixtures.response(:events_200))

    result = client.poll_events
    expect(result.poll_interval).to eq(fixture_interval)
    expect(RateLimitState.current.poll_interval).to eq(fixture_interval)
  end

  it "parses numeric headers as base 10 even with a leading zero" do
    stub_request(:get, events_url)
      .to_return(status: 200, headers: { "x-poll-interval" => "010" }, body: "[]")

    expect(client.poll_events.poll_interval).to eq(10)
  end

  it "updates persisted remaining/reset_at from a 200, visible via #budget" do
    stub_request(:get, events_url).to_return(GithubFixtures.response(:events_200))

    client.poll_events
    budget = client.budget
    expect(budget.remaining).to eq(fixture_remaining)
    expect(budget.reset_at).to eq(fixture_reset)
    expect(budget.updated_at).to be_present
  end

  describe "304 handling" do
    it "returns :not_modified with the poll interval from the real captured 304" do
      stub_request(:get, events_url).to_return(GithubFixtures.response(:events_304))

      result = client.poll_events
      expect(result).to be_not_modified
      expect(result.poll_interval).to eq(GithubFixtures.header(:events_304, "x-poll-interval").to_i)
    end

    it "leaves persisted remaining untouched on a header-less 304 (partial upsert)" do
      RateLimitState.record!(etag: 'W/"seed"', remaining: 42, reset_at: Time.at(1_783_000_000).utc, poll_interval: 60)
      stub_request(:get, events_url).to_return(status: 304)

      result = client.poll_events
      expect(result).to be_not_modified
      expect(RateLimitState.current.remaining).to eq(42)
      expect(RateLimitState.current.etag).to eq('W/"seed"')
    end

    it "mirrors rate headers that a real 304 does carry" do
      # Observed live (D-017): GitHub 304s arrive with a decremented
      # x-ratelimit-remaining. Headers are the source of truth, so the
      # mirror records what they say rather than assuming 304s are free.
      RateLimitState.record!(remaining: 59)
      stub_request(:get, events_url).to_return(GithubFixtures.response(:events_304))

      client.poll_events
      expect(RateLimitState.current.remaining)
        .to eq(GithubFixtures.header(:events_304, "x-ratelimit-remaining").to_i)
    end
  end

  describe "rate limiting" do
    it "maps 403 with remaining=0 to :rate_limited with the correct reset_at" do
      reset_at = Time.at(1_783_600_000).utc
      stub_request(:get, events_url).to_return(GithubApiStubs.rate_limited_403(reset_at: reset_at))

      result = client.poll_events
      expect(result).to be_rate_limited
      expect(result.rate[:remaining]).to eq(0)
      expect(result.rate[:reset_at]).to eq(reset_at)
    end

    it "maps 429 to :rate_limited and exposes retry-after" do
      stub_request(:get, events_url).to_return(GithubApiStubs.too_many_requests_429(retry_after: 90))

      result = client.poll_events
      expect(result).to be_rate_limited
      expect(result.retry_after).to eq(90)
    end

    it "normalizes an HTTP-date Retry-After into integer seconds" do
      freeze_time do
        stub_request(:get, events_url).to_return(
          status: 429,
          headers: { "retry-after" => 90.seconds.from_now.utc.httpdate },
          body: '{"message":"You have exceeded a secondary rate limit."}'
        )

        result = client.poll_events
        expect(result).to be_rate_limited
        expect(result.retry_after).to eq(90)
      end
    end
  end

  describe "transient errors" do
    it "maps 5xx to :transient_error" do
      stub_request(:get, events_url).to_return(status: 502, body: "Bad Gateway")

      result = client.poll_events
      expect(result).to be_retryable
      expect(result.error).to include("502")
    end

    it "maps a timeout to :transient_error without raising" do
      stub_request(:get, events_url).to_timeout

      result = client.poll_events
      expect(result).to be_retryable
    end

    it "maps unparseable JSON to :transient_error" do
      stub_request(:get, events_url).to_return(status: 200, body: '{"truncated":')

      result = client.poll_events
      expect(result).to be_retryable
      expect(result.error).to include("unparseable")
    end

    it "does not advance the stored ETag past a 200 whose body failed to parse" do
      RateLimitState.record!(etag: 'W/"old"')
      stub_request(:get, events_url)
        .to_return(status: 200, headers: { "etag" => 'W/"new"' }, body: '{"truncated":')

      result = client.poll_events
      expect(result).to be_retryable
      expect(RateLimitState.current.etag).to eq('W/"old"')
    end

    it "maps a body over the 5 MB cap to :transient_error" do
      stub_request(:get, events_url)
        .to_return(status: 200, body: "a" * (GithubClient::MAX_BODY_BYTES + 1))

      result = client.poll_events
      expect(result).to be_retryable
      expect(result.error).to include("over")
    end

    it "still mirrors rate headers from a response whose body blew the cap" do
      stub_request(:get, events_url).to_return(
        status: 200,
        headers: { "x-ratelimit-remaining" => "3", "x-ratelimit-reset" => "1783600000" },
        body: "a" * (GithubClient::MAX_BODY_BYTES + 1)
      )

      result = client.poll_events
      expect(result).to be_retryable
      expect(RateLimitState.current.remaining).to eq(3)
    end

    it "maps a connection failure to :transient_error" do
      stub_request(:get, events_url).to_raise(Errno::ECONNREFUSED)

      result = client.poll_events
      expect(result).to be_retryable
    end

    it "maps an impossible 401 to :transient_error and logs loudly" do
      stub_request(:get, events_url).to_return(status: 401, body: '{"message":"Requires authentication"}')
      allow(Rails.logger).to receive(:error)

      result = client.poll_events
      expect(result).to be_retryable
      expect(Rails.logger).to have_received(:error)
        .with(hash_including(event: "auth.unexpected_401"))
    end
  end

  # Net::HTTP hands header bytes through verbatim, and `etag` is the one
  # externally-sourced string that reaches a column. PostgreSQL refuses a NUL
  # in a bind with a bare ArgumentError — outside every rescue this project
  # has — and refuses invalid UTF-8 with an error the D-018 scrub cannot
  # repair, because scrubbing an ETag would forge one. So the client refuses
  # it here, the way the parser refuses an unstorable payload field (D-024).
  describe "unstorable ETags" do
    {
      "a NUL" => "W/\"a\u0000b\"",
      "invalid UTF-8" => "W/\"a\xC3\x28b\"".dup.force_encoding("UTF-8"),
      "an oversized value" => "W/\"#{'a' * 300}\""
    }.each do |description, etag|
      it "drops an ETag carrying #{description} rather than persist it" do
        RateLimitState.record!(etag: 'W/"old"')
        stub_request(:get, events_url).to_return(status: 200, headers: { "etag" => etag }, body: "[]")

        result = client.poll_events

        expect(result).to be_ok
        expect(result.etag).to be_nil
        # The stored ETag stands: the next poll is unconditional, which costs
        # one request. Storing the header would cost the row.
        expect(RateLimitState.current.etag).to eq('W/"old"')
      end
    end
  end

  # Each of these reaches an integer or timestamp column through `persist`,
  # which runs after *every* response — so a value the column cannot hold
  # would take down every later call, not just the one that carried it (D-024).
  describe "implausible rate headers" do
    it "ignores an x-ratelimit-reset outside the storable epoch range" do
      RateLimitState.record!(reset_at: Time.at(1_783_600_000).utc)
      stub_request(:get, events_url)
        .to_return(status: 200, headers: { "x-ratelimit-reset" => "999999999999999999999" }, body: "[]")

      result = nil
      expect { result = client.poll_events }.not_to raise_error
      expect(result.rate[:reset_at]).to be_nil
      expect(RateLimitState.current.reset_at).to eq(Time.at(1_783_600_000).utc)
    end

    it "ignores an x-ratelimit-remaining outside the integer column range" do
      stub_request(:get, events_url)
        .to_return(status: 200, headers: { "x-ratelimit-remaining" => "2147483648" }, body: "[]")

      expect { client.poll_events }.not_to raise_error
      expect(client.budget.remaining).to be_nil
    end

    it "ignores a negative x-poll-interval" do
      stub_request(:get, events_url)
        .to_return(status: 200, headers: { "x-poll-interval" => "-1" }, body: "[]")

      expect(client.poll_events.poll_interval).to be_nil
    end

    it "still accepts ordinary values at those bounds" do
      reset = Time.at(1_783_600_000).utc
      stub_request(:get, events_url).to_return(
        status: 200,
        headers: { "x-ratelimit-reset" => reset.to_i.to_s, "x-ratelimit-remaining" => "0",
                   "x-poll-interval" => "60" },
        body: "[]"
      )

      result = client.poll_events
      expect(result.rate).to eq(remaining: 0, reset_at: reset)
      expect(result.poll_interval).to eq(60)
    end
  end
end
