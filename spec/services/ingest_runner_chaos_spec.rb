require "rails_helper"

# Executable chaos checks for the Phase 4 exit criteria: the loop runs with
# the real GithubClient against WebMock replays, so what is pinned is the
# operator-visible behavior — the log narrative and that the loop resumes —
# not any service's internals.
RSpec.describe IngestRunner, "chaos checks" do
  let(:logger) { RecordingLogger.new }
  let(:events_url) { "https://api.github.com/events" }
  let(:reset_at) { Time.at(GithubFixtures.header(:events_403_rate_limited, "x-ratelimit-reset").to_i).utc }
  # Pinned relative to the fixture's reset so the computed sleep never
  # depends on when the suite runs.
  let(:clock) { class_double(Time, now: reset_at - 120) }

  def cycle_logs
    logger.messages(:info).select { |entry| entry[:event] == "poll.cycle" }
  end

  # Runs the continuous loop until `cycles` poll.cycle lines exist, then
  # requests shutdown exactly as the runner's own signal trap would.
  def run_cycles(cycles)
    runner = nil
    sleeper = ->(_) { runner.request_shutdown if cycle_logs.size >= cycles }
    runner = described_class.new(client: GithubClient.new(logger: logger),
                                 ingester: EventIngester.new(logger: logger),
                                 sleeper: sleeper, clock: clock, logger: logger,
                                 jitter: -> { 0 }, traps: false)
    runner.run
  end

  it "sleeps out a 403 and resumes on the next window" do
    stub_request(:get, events_url)
      .to_return(GithubFixtures.response(:events_403_rate_limited),
                 GithubFixtures.response(:events_200))

    run_cycles(2)

    expect(logger.messages(:info))
      .to include(hash_including(event: "poll.rate_limited", reset_at: reset_at.iso8601,
                                 sleep_for: 120))
    expect(cycle_logs.map { |entry| entry[:status] }).to eq(%i[ rate_limited ok ])
    expect(logger.messages(:fatal)).to be_empty
  end

  it "warns and continues past a garbage body instead of crashing" do
    stub_request(:get, events_url)
      .to_return({ status: 200, body: "{{{ not json",
                   headers: { "Content-Type" => "application/json" } },
                 GithubFixtures.response(:events_200))

    expect { run_cycles(2) }.not_to raise_error

    expect(logger.messages(:warn))
      .to include(hash_including(event: "body.unparseable", error_class: "JSON::ParserError"))
    expect(cycle_logs.map { |entry| entry[:status] }).to eq(%i[ transient_error ok ])
    expect(logger.messages(:fatal)).to be_empty
  end
end
