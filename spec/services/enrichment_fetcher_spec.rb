require "rails_helper"

RSpec.describe EnrichmentFetcher do
  subject(:fetcher) do
    described_class.new(logger: logger, jitter: -> { jitter })
  end

  let(:logger) { RecordingLogger.new }
  let(:jitter) { 7 }
  let(:user_url) { "https://api.github.com/users/octocat" }
  let(:actor) do
    Actor.create!(github_id: 583231, login: "octocat", url: user_url,
                  fetch_status: "enqueued")
  end

  before { freeze_time }

  def entry(level, event)
    logger.messages(level).find { |message| message[:event] == event }
  end

  describe ":ok" do
    it "persists body, etag, fetched_at and marks fetched" do
      stub_request(:get, user_url).to_return(GithubFixtures.response(:actor_200))

      outcome = fetcher.call(actor)

      expect(outcome.action).to eq(:done)
      actor.reload
      expect(actor.fetch_status).to eq("fetched")
      expect(actor.data).to eq(GithubFixtures.json_body(:actor_200))
      # Weak ETag stored byte-identical so the next conditional fetch echoes
      # exactly what GitHub served.
      expect(actor.etag).to eq(GithubFixtures.header(:actor_200, "etag"))
      expect(actor.etag).to start_with('W/"')
      expect(actor.fetched_at).to eq(Time.current)
      expect(entry(:info, "enrich.success")).to include(entity: "actor", github_id: 583231,
                                                        not_modified: false)
    end
  end

  describe ":not_modified" do
    it "sends the stored etag, touches fetched_at, and leaves data and etag alone" do
      etag = GithubFixtures.header(:actor_200, "etag")
      actor.update!(etag: etag, data: { "login" => "octocat" }, fetched_at: 25.hours.ago)
      stub = stub_request(:get, user_url)
        .with(headers: { "If-None-Match" => etag })
        .to_return(GithubFixtures.response(:actor_304))

      outcome = fetcher.call(actor)

      expect(outcome.action).to eq(:done)
      expect(stub).to have_been_requested
      actor.reload
      expect(actor.fetch_status).to eq("fetched")
      expect(actor.fetched_at).to eq(Time.current)
      expect(actor.data).to eq("login" => "octocat")
      expect(actor.etag).to eq(etag)
      expect(entry(:info, "enrich.success")).to include(not_modified: true)
    end
  end

  describe ":not_found" do
    it "marks the record terminal and never claims again" do
      stub_request(:get, user_url).to_return(GithubApiStubs.not_found_404)

      outcome = fetcher.call(actor)

      expect(outcome.action).to eq(:done)
      expect(actor.reload.fetch_status).to eq("not_found")
      expect(entry(:info, "enrich.terminal")).to include(reason: "not_found")
      expect(Actor.claim_for_enrichment(actor.github_id)).to be(false)
    end
  end

  describe ":rejected_url" do
    it "marks the record rejected with a security log and zero HTTP" do
      actor.update!(url: "https://evil.com/users/octocat")

      outcome = fetcher.call(actor)

      expect(outcome.action).to eq(:done)
      expect(actor.reload.fetch_status).to eq("rejected")
      expect(entry(:error, "security.url_rejected")).to include(entity: "actor", github_id: 583231)
      expect(WebMock).not_to have_requested(:get, /./)
    end
  end

  describe ":rate_limited" do
    it "parks until reset_at plus jitter on a 403" do
      reset_at = 20.minutes.from_now
      stub_request(:get, user_url).to_return(GithubApiStubs.rate_limited_403(reset_at: reset_at))

      outcome = fetcher.call(actor)

      expect(outcome.action).to eq(:parked)
      # Header epochs round-trip through Time.at, so compare at integer
      # precision.
      expect(outcome.run_at.to_i).to eq(reset_at.to_i + jitter)
      expect(actor.reload.fetch_status).to eq("enqueued")
      expect(entry(:info, "enrich.parked")).to include(reason: "rate_limited")
    end

    it "prefers Retry-After over the far-off reset on a 429" do
      stub_request(:get, user_url).to_return(GithubApiStubs.too_many_requests_429(retry_after: 90))

      outcome = fetcher.call(actor)

      expect(outcome.action).to eq(:parked)
      expect(outcome.run_at).to eq(Time.now + 90 + jitter)
    end

    it "clamps a reset_at already in the past to a future run_at" do
      stub_request(:get, user_url).to_return(GithubApiStubs.rate_limited_403(reset_at: 2.minutes.ago))

      outcome = fetcher.call(actor)

      # Stale reset falls back to a blind wait — never a zero-delay hot loop.
      expect(outcome.run_at).to eq(Time.now + described_class::PARK_FALLBACK + jitter)
    end

    # The only input that reaches the clamp's floor: the fallback branch above
    # never does, because PARK_FALLBACK is already 60.
    it "never parks in the past on a Retry-After of zero" do
      stub_request(:get, user_url).to_return(GithubApiStubs.too_many_requests_429(retry_after: 0))

      outcome = fetcher.call(actor)

      expect(outcome.run_at).to eq(Time.now + 1 + jitter)
    end
  end

  # A park leaves the record `enqueued` — that is the in-flight dedup — so a
  # wait honored past the rate window would wedge the entity forever. Both
  # park sites are covered: a desynced header can arrive on either (D-024).
  describe "the park cap" do
    let(:cap) { GithubClient::RateWindow::MAX_WAIT }

    it "caps a rate-limited park at the rate window" do
      stub_request(:get, user_url)
        .to_return(GithubApiStubs.rate_limited_403(reset_at: 70.years.from_now))

      expect(fetcher.call(actor).run_at).to eq(Time.now + cap + jitter)
    end

    it "caps a park driven by an absurd Retry-After" do
      stub_request(:get, user_url).to_return(GithubApiStubs.too_many_requests_429(retry_after: 99_999_999))

      expect(fetcher.call(actor).run_at).to eq(Time.now + cap + jitter)
    end

    it "caps a budget-gate park at the rate window" do
      RateLimitState.record!(remaining: 0, reset_at: 70.years.from_now)

      outcome = fetcher.call(actor)

      expect(outcome.run_at).to eq(Time.now + cap + jitter)
      expect(entry(:info, "enrich.parked")).to include(reason: "budget")
      expect(WebMock).not_to have_requested(:get, /./)
    end

    it "leaves an honest reset inside the window untouched" do
      reset_at = 45.minutes.from_now
      stub_request(:get, user_url).to_return(GithubApiStubs.rate_limited_403(reset_at: reset_at))

      expect(fetcher.call(actor).run_at.to_i).to eq(reset_at.to_i + jitter)
    end
  end

  describe "budget gate" do
    it "parks without fetching when remaining is at the reserve" do
      reset_at = 30.minutes.from_now
      RateLimitState.record!(remaining: described_class::ENRICHMENT_RESERVE, reset_at: reset_at)

      outcome = fetcher.call(actor)

      expect(outcome.action).to eq(:parked)
      expect(outcome.run_at.to_i).to eq(reset_at.to_i + jitter)
      expect(entry(:info, "enrich.parked")).to include(reason: "budget")
      expect(WebMock).not_to have_requested(:get, /./)
    end

    it "fetches when remaining is one above the reserve" do
      RateLimitState.record!(remaining: described_class::ENRICHMENT_RESERVE + 1,
                             reset_at: 30.minutes.from_now)
      stub_request(:get, user_url).to_return(GithubFixtures.response(:actor_200))

      expect(fetcher.call(actor).action).to eq(:done)
    end

    it "parks with the blind fallback when no reset_at has been observed" do
      RateLimitState.record!(remaining: 0)

      outcome = fetcher.call(actor)

      expect(outcome.action).to eq(:parked)
      expect(outcome.run_at).to eq(Time.now + described_class::PARK_FALLBACK + jitter)
    end

    it "fetches optimistically when the exhausted window has already rolled" do
      # The mirror says 0 but its reset instant has passed: nothing would
      # ever refresh it unless someone fetches (stale-mirror escape).
      RateLimitState.record!(remaining: 0, reset_at: 2.minutes.ago)
      stub_request(:get, user_url).to_return(GithubFixtures.response(:actor_200))

      expect(fetcher.call(actor).action).to eq(:done)
      expect(actor.reload.fetch_status).to eq("fetched")
    end

    it "fetches when the budget has never been observed" do
      stub_request(:get, user_url).to_return(GithubFixtures.response(:actor_200))

      expect(fetcher.call(actor).action).to eq(:done)
    end
  end

  describe ":transient_error" do
    it "returns a retry outcome and leaves the record enqueued" do
      stub_request(:get, user_url).to_return(status: 502, body: "")

      outcome = fetcher.call(actor)

      expect(outcome.action).to eq(:retry)
      expect(outcome.error).to be_present
      expect(actor.reload.fetch_status).to eq("enqueued")
      expect(entry(:warn, "enrich.retry")).to include(entity: "actor")
    end
  end

  # The scrub repairs `data`; it cannot repair `etag`, and the ArgumentError a
  # NUL bind raises never reaches the classifier at all. The client drops an
  # unstorable ETag before it ever reaches this layer, so the record settles
  # instead of cycling claim → fail → release, spending a request each lap.
  describe "hostile ETag" do
    it "settles the record with no etag rather than failing the write" do
      stub_request(:get, user_url).to_return(
        status: 200, headers: { "etag" => "W/\"a\u0000b\"" }, body: '{"login":"octocat"}'
      )

      expect { fetcher.call(actor) }.not_to raise_error

      actor.reload
      expect(actor.fetch_status).to eq("fetched")
      expect(actor.etag).to be_nil
      expect(actor.data).to eq("login" => "octocat")
    end

    # Net::HTTP tags header values ASCII-8BIT, where `valid_encoding?` is true
    # of every byte sequence — so the client's guard has to judge the bytes as
    # UTF-8, or this ETag reaches the bind it exists to stop (D-025).
    it "settles the record when a binary-tagged etag carries invalid UTF-8" do
      stub_request(:get, user_url).to_return(
        status: 200, headers: { "etag" => "W/\"a\xC3\x28b\"".b }, body: '{"login":"octocat"}'
      )

      expect { fetcher.call(actor) }.not_to raise_error

      actor.reload
      expect(actor.fetch_status).to eq("fetched")
      expect(actor.etag).to be_nil
      expect(actor.data).to eq("login" => "octocat")
    end
  end

  # /users and /repos answer with JSON objects. A 200 carrying anything else
  # is not enrichment data, and persisting it would store a scalar under
  # `data`, mark the record `fetched`, and let the 24h TTL hide the anomaly
  # for a day. Refuse before persist — terminal, like any other unusable
  # response (D-025).
  describe "a non-object 200 body" do
    {
      "an array" => [ "[]", "Array" ],
      "a string" => [ '"octocat"', "String" ],
      "a number" => [ "123", "Integer" ],
      "null" => [ "null", "NilClass" ]
    }.each do |description, (body, body_class)|
      it "rejects #{description} without storing it" do
        stub_request(:get, user_url)
          .to_return(status: 200, headers: { "etag" => 'W/"b1"' }, body: body)

        outcome = fetcher.call(actor)

        expect(outcome.action).to eq(:done)
        actor.reload
        expect(actor.fetch_status).to eq("rejected")
        expect(actor.data).to be_nil
        expect(actor.etag).to be_nil
        expect(actor.fetched_at).to be_nil
        expect(entry(:warn, "enrich.rejected"))
          .to include(entity: "actor", github_id: 583231,
                      reason: "non_object_body", body_class: body_class)
      end
    end

    it "settles the entity for good — it is never claimed again" do
      stub_request(:get, user_url).to_return(status: 200, body: "[]")

      fetcher.call(actor)

      expect(Actor.claim_for_enrichment(actor.github_id)).to be(false)
    end
  end

  describe "hostile enrichment body" do
    it "persists a scrubbed, marked copy when the body is unstorable" do
      # \x5C = backslash: the JSON escape for NUL, spelled without putting
      # a raw NUL byte in this source file.
      hostile = %({"login":"octocat","bio":"a\x5Cu0000b"})
      stub_request(:get, user_url).to_return(status: 200,
                                             headers: { "etag" => 'W/"h1"' }, body: hostile)

      outcome = fetcher.call(actor)

      expect(outcome.action).to eq(:done)
      actor.reload
      expect(actor.fetch_status).to eq("fetched")
      expect(actor.data).to eq("login" => "octocat", "bio" => "ab", "payload_scrubbed" => true)
      expect(entry(:warn, "enrich.scrubbed")).to include(entity: "actor")
    end
  end
end
