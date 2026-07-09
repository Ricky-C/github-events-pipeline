require "rails_helper"

RSpec.describe IngestRunner do
  let(:logger) { RecordingLogger.new }
  let(:client) { instance_double(GithubClient, budget: GithubClient::Budget.new(57, nil, nil)) }
  let(:ingester) { instance_double(EventIngester, ingest: counts) }
  # The full ingester counts shape — kept in lockstep with
  # EventIngester.empty_counts so the poll.cycle assertion below pins every
  # key's propagation into the log line.
  let(:counts) do
    { events_seen: 30, push_events_new: 26, duplicates_skipped: 4, malformed_skipped: 0,
      structured_skipped: 0 }
  end
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
    it "ingests the body and sleeps a reported poll interval above the floor after :ok" do
      run_loop([ ok_result(interval: 180) ])

      expect(ingester).to have_received(:ingest)
      expect(cycle_logs.last).to include(status: :ok, sleep_for: 180, budget_remaining: 57, **counts)
    end

    it "floors the default interval when the header is absent" do
      run_loop([ ok_result(interval: nil) ])
      expect(cycle_logs.last[:sleep_for]).to eq(IngestRunner::POLL_FLOOR)
    end

    it "never polls faster than the floor, even at GitHub's served 60s interval" do
      # 304s cost budget (D-017, D-022): the served interval is deliberately
      # not honored below the floor.
      run_loop([ ok_result(interval: 60) ])
      expect(cycle_logs.last[:sleep_for]).to eq(IngestRunner::POLL_FLOOR)
    end

    it "does not ingest on :not_modified and reuses the response interval" do
      run_loop([ result(:not_modified, poll_interval: 180) ])

      expect(ingester).not_to have_received(:ingest)
      expect(cycle_logs.last).to include(status: :not_modified, not_modified: true,
                                         sleep_for: 180, events_seen: 0)
    end

    it "falls back to the last persisted interval on a header-less :not_modified" do
      RateLimitState.record!(poll_interval: 150)
      run_loop([ result(:not_modified) ])
      expect(cycle_logs.last[:sleep_for]).to eq(150)
    end

    it "sleeps until reset_at plus jitter when rate-limited" do
      run_loop([ result(:rate_limited, rate: { remaining: 0, reset_at: now + 120 }) ])
      expect(cycle_logs.last[:sleep_for]).to eq(120)
    end

    it "narrates a rate-limited cycle with its own event, alongside the cycle line" do
      run_loop([ result(:rate_limited, retry_after: 90,
                        rate: { remaining: 0, reset_at: now + 120 }) ])

      # iso8601, matching enrich.parked's run_at — one timestamp format
      # across every operator-facing log field.
      expect(logger.messages(:info))
        .to include(hash_including(event: "poll.rate_limited", reset_at: (now + 120).iso8601,
                                   retry_after: 90, sleep_for: 90))
      # The cycle line still fires — poll.rate_limited is an overlay, so the
      # per-cycle count reconciliation stays intact.
      expect(cycle_logs.last).to include(status: :rate_limited, sleep_for: 90)
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

    # A reset already behind us says the mirror is stale, not that the window
    # rolled: the poller blind-waits the default interval rather than retrying
    # in a second against an API that has just said stop. Both park sites and
    # this loop read that rule from RateWindow.wait (D-025).
    it "blind-waits the default interval when reset_at is already in the past" do
      run_loop([ result(:rate_limited, rate: { remaining: 0, reset_at: now - 30 }) ])
      expect(cycle_logs.last[:sleep_for]).to eq(described_class::DEFAULT_POLL_INTERVAL)
    end

    # A header asking for a wait past the rate window is a desynced shard or a
    # rewritten Retry-After, not an instruction (D-024). Honoring it would
    # blind the poller for years; the enrichment parks share the clamp.
    it "never sleeps past the rate window on a far-future reset_at" do
      run_loop([ result(:rate_limited, rate: { remaining: 0, reset_at: now + 70.years }) ])
      expect(cycle_logs.last[:sleep_for]).to eq(GithubClient::RateWindow::MAX_WAIT)
    end

    it "never sleeps past the rate window on an absurd retry-after" do
      run_loop([ result(:rate_limited, retry_after: 99_999_999) ])
      expect(cycle_logs.last[:sleep_for]).to eq(GithubClient::RateWindow::MAX_WAIT)
    end
  end

  describe "backoff" do
    it "backs off exponentially on consecutive transient errors, capped" do
      run_loop(Array.new(8) { result(:transient_error, error: "boom") })
      expect(cycle_logs.map { |entry| entry[:sleep_for] }).to eq([ 5, 10, 20, 40, 80, 160, 300, 300 ])
    end

    it "resets the backoff counter after a successful cycle" do
      run_loop([ result(:transient_error, error: "boom"), ok_result, result(:transient_error, error: "boom") ])
      expect(cycle_logs.map { |entry| entry[:sleep_for] }).to eq([ 5, IngestRunner::POLL_FLOOR, 5 ])
    end
  end

  describe "resilience" do
    # Network failures reach this loop as Result values, never exceptions
    # (the client converts them), so the raised-exception policy below is
    # about database errors and bugs (D-026).
    let(:transient) { ActiveRecord::ConnectionNotEstablished.new("db unavailable") }

    def new_runner(sleeper:)
      described_class.new(client: client, ingester: ingester, sleeper: sleeper,
                          clock: clock, logger: logger, jitter: -> { 0 }, traps: false)
    end

    it "backs off and keeps looping when the database drops for one cycle" do
      calls = 0
      allow(client).to receive(:poll_events) do
        calls += 1
        raise transient if calls == 1
        ok_result
      end
      runner = nil
      sleeper = ->(_) { runner.instance_variable_set(:@shutdown, true) if calls >= 2 }
      runner = new_runner(sleeper: sleeper)
      runner.run

      expect(logger.messages(:error))
        .to contain_exactly(hash_including(event: "poll.error",
                                           error_class: "ActiveRecord::ConnectionNotEstablished",
                                           consecutive: 1))
      expect(cycle_logs.last[:status]).to eq(:ok)
    end

    it "escalates a programming error immediately instead of absorbing it" do
      allow(client).to receive(:poll_events).and_raise(NoMethodError, "undefined method 'oops'")
      runner = new_runner(sleeper: ->(_) { raise "escalation must not sleep" })

      expect { runner.run }.to raise_error(NoMethodError)
      expect(logger.messages(:fatal))
        .to contain_exactly(hash_including(event: "poll.escalated", reason: "permanent_error",
                                           error_class: "NoMethodError"))
    end

    it "escalates once consecutive transient failures exhaust the cap" do
      calls = 0
      allow(client).to receive(:poll_events) { calls += 1; raise transient }
      runner = nil
      # The flag is a leash on the mutant that never escalates: past the cap
      # it stops the loop so the missing raise fails this spec instead of
      # hanging the suite.
      sleeper = lambda do |_|
        runner.instance_variable_set(:@shutdown, true) if calls > described_class::MAX_CONSECUTIVE_FAILURES
      end
      runner = new_runner(sleeper: sleeper)

      expect { runner.run }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      expect(calls).to eq(described_class::MAX_CONSECUTIVE_FAILURES)
      expect(logger.messages(:fatal))
        .to contain_exactly(hash_including(event: "poll.escalated",
                                           reason: "transient_failures_exhausted",
                                           consecutive: described_class::MAX_CONSECUTIVE_FAILURES))
    end

    it "resets the consecutive counter after any completed cycle" do
      # One below the cap, a success, one below the cap again: never
      # escalates, pinning that the cap measures a streak, not a total —
      # the mutant that stops resetting fails here on the doubled tally.
      below_cap = described_class::MAX_CONSECUTIVE_FAILURES - 1
      sequence = [ transient ] * below_cap + [ :ok ] + [ transient ] * below_cap + [ :ok ]
      served = 0
      allow(client).to receive(:poll_events) do
        step = sequence[[ served, sequence.size - 1 ].min]
        served += 1
        step == :ok ? ok_result : raise(step)
      end
      runner = nil
      sleeper = ->(_) { runner.instance_variable_set(:@shutdown, true) if served >= sequence.size }
      runner = new_runner(sleeper: sleeper)

      expect { runner.run }.not_to raise_error
      expect(logger.messages(:fatal)).to be_empty
      expect(logger.messages(:error).map { |entry| entry[:consecutive] }.max).to eq(below_cap)
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

    it "raises PollFailed on a failure result so the process exits nonzero" do
      allow(client).to receive(:poll_events).and_return(result(:transient_error, error: "HTTP 502"))
      runner = described_class.new(client: client, ingester: ingester, sleeper: ->(_) { },
                                   clock: clock, logger: logger, jitter: -> { 0 }, traps: false)

      expect { runner.run(once: true) }
        .to raise_error(IngestRunner::PollFailed, /transient_error/)
    end

    it "treats a rate-limited one-shot as a failure too" do
      allow(client).to receive(:poll_events).and_return(result(:rate_limited, retry_after: 60))
      runner = described_class.new(client: client, ingester: ingester, sleeper: ->(_) { },
                                   clock: clock, logger: logger, jitter: -> { 0 }, traps: false)

      expect { runner.run(once: true) }
        .to raise_error(IngestRunner::PollFailed, /rate_limited/)
    end

    it "returns normally on :not_modified — an unchanged feed is a healthy poll" do
      allow(client).to receive(:poll_events).and_return(result(:not_modified, poll_interval: 60))
      runner = described_class.new(client: client, ingester: ingester, sleeper: ->(_) { },
                                   clock: clock, logger: logger, jitter: -> { 0 }, traps: false)

      expect { runner.run(once: true) }.not_to raise_error
    end
  end
end
