require "rails_helper"

RSpec.describe IngestRunner do
  let(:logger) { RecordingLogger.new }
  let(:client) { instance_double(GithubClient, budget: GithubClient::Budget.new(57, nil, nil)) }
  let(:ingester) { instance_double(EventIngester, ingest: counts) }
  let(:counts) { { events_seen: 30, push_events_new: 26, duplicates_skipped: 4, malformed_skipped: 0 } }
  let(:now) { Time.utc(2026, 7, 8, 12, 0, 0) }
  let(:clock) { class_double(Time, now: now) }

  def result(status, **fields)
    GithubClient::Result.new(status: status, **fields)
  end

  def ok_result(interval: 60)
    result(:ok, body: [], poll_interval: interval, rate: { remaining: 57, reset_at: nil })
  end

  # Drives the continuous loop through `responses`, one per cycle, with no
  # real sleeping; after the last response is served, the next sleep slice
  # flips the shutdown flag exactly as the runner's own signal trap would.
  def run_loop(responses)
    served = 0
    allow(client).to receive(:poll_events) { responses[[ served, responses.size - 1 ].min].tap { served += 1 } }
    runner = nil
    slept = []
    sleeper = lambda do |slice|
      slept << slice
      runner.instance_variable_set(:@shutdown, true) if served >= responses.size
    end
    runner = described_class.new(client: client, ingester: ingester, sleeper: sleeper,
                                 clock: clock, logger: logger, jitter: -> { 0 }, traps: false)
    runner.run
    slept
  end

  def cycle_logs
    logger.messages(:info).select { |entry| entry[:event] == "poll.cycle" }
  end

  describe "cadence policy" do
    it "ingests the body and sleeps the reported poll interval after :ok" do
      run_loop([ ok_result(interval: 60) ])

      expect(ingester).to have_received(:ingest)
      expect(cycle_logs.last).to include(status: :ok, sleep_for: 60, budget_remaining: 57, **counts)
    end

    it "defaults the interval when the header is absent" do
      run_loop([ ok_result(interval: nil) ])
      expect(cycle_logs.last[:sleep_for]).to eq(IngestRunner::DEFAULT_POLL_INTERVAL)
    end

    it "never polls faster than the floor" do
      run_loop([ ok_result(interval: 3) ])
      expect(cycle_logs.last[:sleep_for]).to eq(IngestRunner::POLL_FLOOR)
    end

    it "does not ingest on :not_modified and reuses the response interval" do
      run_loop([ result(:not_modified, poll_interval: 60) ])

      expect(ingester).not_to have_received(:ingest)
      expect(cycle_logs.last).to include(status: :not_modified, not_modified: true,
                                         sleep_for: 60, events_seen: 0)
    end

    it "falls back to the last persisted interval on a header-less :not_modified" do
      RateLimitState.record!(poll_interval: 75)
      run_loop([ result(:not_modified) ])
      expect(cycle_logs.last[:sleep_for]).to eq(75)
    end

    it "sleeps until reset_at plus jitter when rate-limited" do
      run_loop([ result(:rate_limited, rate: { remaining: 0, reset_at: now + 120 }) ])
      expect(cycle_logs.last[:sleep_for]).to eq(120)
    end

    it "uses retry-after when rate-limited without a reset time" do
      run_loop([ result(:rate_limited, retry_after: 90) ])
      expect(cycle_logs.last[:sleep_for]).to eq(90)
    end

    it "prefers retry-after over the primary reset when a response carries both" do
      # Secondary/abuse limits ask for a short wait while the same response
      # still reports the primary bucket's far-off reset.
      run_loop([ result(:rate_limited, retry_after: 60,
                        rate: { remaining: 55, reset_at: now + 3000 }) ])
      expect(cycle_logs.last[:sleep_for]).to eq(60)
    end

    it "waits at least a second when reset_at is already in the past" do
      run_loop([ result(:rate_limited, rate: { remaining: 0, reset_at: now - 30 }) ])
      expect(cycle_logs.last[:sleep_for]).to eq(1)
    end
  end

  describe "backoff" do
    it "backs off exponentially on consecutive transient errors, capped" do
      run_loop(Array.new(8) { result(:transient_error, error: "boom") })
      expect(cycle_logs.map { |entry| entry[:sleep_for] }).to eq([ 5, 10, 20, 40, 80, 160, 300, 300 ])
    end

    it "resets the backoff counter after a successful cycle" do
      run_loop([ result(:transient_error, error: "boom"), ok_result, result(:transient_error, error: "boom") ])
      expect(cycle_logs.map { |entry| entry[:sleep_for] }).to eq([ 5, 60, 5 ])
    end
  end

  describe "resilience" do
    it "logs an unexpected exception and keeps looping instead of exiting" do
      calls = 0
      allow(client).to receive(:poll_events) do
        calls += 1
        raise "database hiccup" if calls == 1
        ok_result
      end
      runner = nil
      sleeper = ->(_) { runner.instance_variable_set(:@shutdown, true) if calls >= 2 }
      runner = described_class.new(client: client, ingester: ingester, sleeper: sleeper,
                                   clock: clock, logger: logger, jitter: -> { 0 }, traps: false)
      runner.run

      expect(logger.messages(:error))
        .to contain_exactly(hash_including(event: "poll.error", message: "database hiccup"))
      expect(cycle_logs.last[:status]).to eq(:ok)
    end

    it "logs a clean shutdown when the stop flag flips" do
      run_loop([ ok_result ])
      expect(logger.messages(:info).last).to include(event: "shutdown.clean")
    end
  end

  describe "one-shot mode" do
    it "runs exactly one cycle and never sleeps" do
      allow(client).to receive(:poll_events).and_return(ok_result)
      slept = []
      runner = described_class.new(client: client, ingester: ingester, sleeper: ->(s) { slept << s },
                                   clock: clock, logger: logger, jitter: -> { 0 }, traps: false)
      runner.run(once: true)

      expect(client).to have_received(:poll_events).once
      expect(slept).to be_empty
      expect(cycle_logs.size).to eq(1)
    end

    it "lets failures propagate so verification runs are loud" do
      allow(client).to receive(:poll_events).and_raise("boom")
      runner = described_class.new(client: client, ingester: ingester, sleeper: ->(_) { },
                                   clock: clock, logger: logger, jitter: -> { 0 }, traps: false)

      expect { runner.run(once: true) }.to raise_error("boom")
    end
  end
end
