require "rails_helper"

# Extension D's integration deliverables (docs/plans/PHASE-5-PLAN.md): drive
# the real one-shot composition — GithubClient, EventIngester,
# EnrichmentQueuer — end to end against the captured /events page, pinning
# everything a reviewer would verify by hand in one place: persisted rows,
# enqueued jobs, and the log narrative. The restart-safety example then runs
# the same fixtures through a second freshly built runner and pins that a
# replay changes nothing a reader consumes.
RSpec.describe IngestRunner, "full ingest cycle" do
  include ActiveJob::TestHelper

  let(:logger) { RecordingLogger.new }
  let(:events_url) { "https://api.github.com/events" }
  let(:page) { GithubFixtures.json_body(:events_200) }
  let(:pushes) { GithubFixtures.push_events }
  let(:actor_ids) { pushes.map { |event| event["actor"]["id"] }.uniq }
  let(:repo_ids) { pushes.map { |event| event["repo"]["id"] }.uniq }

  before do
    # Header-blind on purpose: the restart run polls conditionally (the
    # persisted ETag goes out as If-None-Match) and must still be served the
    # same 200 — GitHub re-serving a window that overlaps ingested events.
    stub_request(:get, events_url).to_return(GithubFixtures.response(:events_200))
  end

  # A fresh composition per call, because a restart is a new process — only
  # the database survives between runs. The queuer is injected explicitly:
  # EventIngester's default queuer logs to Rails.logger, which would silently
  # hide the enrich.* events from the recorder.
  def run_once
    IngestRunner.new(client: GithubClient.new(logger: logger),
                     ingester: EventIngester.new(logger: logger,
                                                 queuer: EnrichmentQueuer.new(logger: logger)),
                     sleeper: ->(_) { raise "one-shot mode must never sleep" },
                     logger: logger, jitter: -> { 0 }, traps: false)
      .run(once: true)
  end

  def cycle_logs
    logger.messages(:info, event: "poll.cycle")
  end

  describe "one poll through the real composition" do
    before { run_once }

    it "persists every fixture PushEvent raw and structured" do
      # Row sets only: the field mapping is event_ingester_spec's wiring
      # probe and the parser spec's matrix — re-pinning it here would give
      # every attribute change two failures for one cause.
      expect(RawEvent.pluck(:github_event_id)).to match_array(pushes.map { |event| event["id"] })
      expect(PushEvent.pluck(:github_event_id)).to match_array(pushes.map { |event| event["id"] })
    end

    it "stubs and enqueues exactly one enrichment job per unique entity" do
      # Identity anchors to the fixture, not just counts: a seam bug pairing
      # the wrong event's actor/repo per stub would keep every count green.
      expect(Actor.pluck(:github_id)).to match_array(actor_ids)
      expect(Repository.pluck(:github_id)).to match_array(repo_ids)
      expect(Actor.distinct.pluck(:fetch_status)).to eq([ "enqueued" ])
      expect(Repository.distinct.pluck(:fetch_status)).to eq([ "enqueued" ])

      expect(enqueued_jobs.map { |job| job["job_class"] }.tally)
        .to eq("EnrichActorJob" => actor_ids.size, "EnrichRepositoryJob" => repo_ids.size)
      actor_args = enqueued_jobs.select { |job| job["job_class"] == "EnrichActorJob" }
                                .map { |job| job["arguments"] }
      expect(actor_args).to match_array(Actor.pluck(:id).map { |id| [ id ] })
    end

    it "narrates the cycle to the operator and stays clean" do
      expect(cycle_logs).to contain_exactly(
        hash_including(status: :ok, not_modified: false,
                       events_seen: page.size, push_events_new: pushes.size,
                       duplicates_skipped: 0, malformed_skipped: 0, structured_skipped: 0,
                       budget_remaining: GithubFixtures.header(:events_200, "x-ratelimit-remaining").to_i,
                       # The fixture serves X-Poll-Interval 60; the budget
                       # floor wins. A literal, not IngestRunner::POLL_FLOOR:
                       # this is the suite's one pin of D-022's 120s policy
                       # value, and sourcing it from the constant under test
                       # would let the expectation move with the mutation
                       # (D-025's methodological note).
                       sleep_for: 120)
      )

      enqueued = logger.messages(:info, event: "enrich.enqueued")
      expect(enqueued.count { |entry| entry[:entity] == "actor" }).to eq(actor_ids.size)
      expect(enqueued.count { |entry| entry[:entity] == "repository" }).to eq(repo_ids.size)

      expect(logger.messages(:warn)).to be_empty
      expect(logger.messages(:error)).to be_empty
      expect(logger.messages(:fatal)).to be_empty
    end
  end

  describe "restart safety" do
    # Exclusion-based on purpose: every column is compared except the two the
    # identity-refresh stub upsert and the rate-mirror upsert bump on every
    # run by design (D-024) — so a column added later is snapshotted by
    # default instead of silently escaping the replay contract.
    REPLAY_MUTABLE = %w[ created_at updated_at ].freeze

    def replay_stable(relation, order_by)
      relation.order(order_by).map { |row| row.attributes.except("id", *REPLAY_MUTABLE) }
    end

    def db_snapshot
      { raw: replay_stable(RawEvent.all, :github_event_id),
        push: replay_stable(PushEvent.all, :github_event_id),
        actors: replay_stable(Actor.all, :github_id),
        repositories: replay_stable(Repository.all, :github_id),
        rate: RateLimitState.current&.attributes&.except("id", *REPLAY_MUTABLE),
        jobs: enqueued_jobs.map { |job| [ job["job_class"], job["arguments"] ] }.sort }
    end

    it "replays identically: a second run over the same page changes nothing" do
      run_once
      first_run = db_snapshot

      run_once

      expect(db_snapshot).to eq(first_run)

      # Not vacuously: the second poll really was the conditional-request
      # path — the ETag persisted by run one went out and the same 200 came
      # back — not a repeat of run one's header-less boot poll.
      expect(WebMock).to have_requested(:get, events_url)
        .with(headers: { "If-None-Match" => GithubFixtures.header(:events_200, "etag") }).once

      # ...and the second cycle did full-page work: every raw row deduped,
      # every enrichment claim skipped as already in flight.
      expect(cycle_logs.map { |entry| entry.values_at(:status, :push_events_new, :duplicates_skipped) })
        .to eq([ [ :ok, pushes.size, 0 ], [ :ok, 0, pushes.size ] ])
      skips = logger.messages(:info, event: "enrich.skipped")
      expect(skips.size).to eq(actor_ids.size + repo_ids.size)
      expect(skips.map { |entry| entry[:reason] }.uniq).to eq([ "in_flight" ])

      expect(logger.messages(:error)).to be_empty
      expect(logger.messages(:fatal)).to be_empty
    end
  end
end
