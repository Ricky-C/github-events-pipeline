require "rails_helper"

# The claim *is* the in-flight dedup (docs/DECISIONS.md D-023): Solid Queue has
# no native enqueue-uniqueness, so "exactly one job per claimable window" rests
# entirely on one atomic UPDATE that commits together with its job row. The
# sequential examples in enrichable_spec.rb cannot tell an atomic claim from a
# read-modify-write — both pass when the calls never overlap. Only real threads
# on real Postgres connections can, so transactional fixtures are off here: a
# thread checks out its own connection and would never see rows left
# uncommitted on the example's.
RSpec.describe "enrichment claim atomicity", type: :model do
  self.use_transactional_tests = false

  # The real Solid Queue adapter, not :test. The test adapter records enqueues
  # in a plain array that no transaction can roll back, so it would report a
  # job for a claim that rolled back — which is the property under test.
  around do |example|
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
    example.run
  ensure
    ActiveJob::Base.queue_adapter = previous
  end

  # Foreign keys cascade from solid_queue_jobs to every execution table.
  after do
    SolidQueue::Job.delete_all
    Actor.delete_all
    Repository.delete_all
  end

  let(:event) { GithubFixtures.first_push }
  let(:github_id) { event["actor"]["id"] }
  let(:rows) do
    parsed = PushEventParser.call(event)
    [ { github_event_id: event["id"], event_type: "PushEvent", payload: event,
        structured: parsed.attributes.merge(github_event_id: event["id"]) } ]
  end

  def queuer = EnrichmentQueuer.new(logger: Logger.new(IO::NULL))
  def actor_jobs = SolidQueue::Job.where(class_name: "EnrichActorJob")

  def existing_actor(**overrides)
    Actor.create!(github_id: github_id, login: event["actor"]["login"],
                  url: "https://api.github.com/users/#{event['actor']['login']}", **overrides)
  end

  # Every thread reaches the barrier before any of them can touch the row, so
  # the claims genuinely overlap instead of merely following one another.
  def in_parallel(count)
    barrier = Concurrent::CyclicBarrier.new(count)
    results = Concurrent::Array.new
    Array.new(count) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait(10)
          results << yield
        end
      end
    end.each(&:join)
    results
  end

  it "lets exactly one of two concurrent ingest runs claim and enqueue an entity" do
    existing_actor

    in_parallel(2) { queuer.call(rows) }

    expect(Actor.where(github_id: github_id).count).to eq(1)
    expect(Actor.find_by!(github_id: github_id).fetch_status).to eq("enqueued")
    expect(actor_jobs.count).to eq(1)
    expect(SolidQueue::Job.where(class_name: "EnrichRepositoryJob").count).to eq(1)
  end

  it "lets exactly one of two concurrent claims win once the TTL has expired" do
    existing_actor(fetch_status: "fetched", fetched_at: Enrichable::ENRICHMENT_TTL.ago - 1.minute)

    wins = in_parallel(2) { Actor.claim_for_enrichment(github_id) }

    expect(wins.count(true)).to eq(1)
    expect(wins.count(false)).to eq(1)
  end

  # The atomicity proof proper. A read-modify-write claim would not block —
  # both callers would read "pending" from their own snapshot and both would
  # win. The single guarded UPDATE makes the loser wait on the winner's
  # uncommitted row lock, then re-evaluate its WHERE against the committed row
  # and match nothing.
  it "makes a concurrent claim block on the winner's row lock, then lose" do
    existing_actor
    hold = 0.2
    claimed = Concurrent::CyclicBarrier.new(2)
    lost = nil
    blocked_for = nil

    winner = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Actor.transaction do
          Actor.claim_for_enrichment(github_id)
          claimed.wait(10)
          sleep hold
        end
      end
    end

    loser = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        claimed.wait(10)
        started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        lost = Actor.claim_for_enrichment(github_id)
        blocked_for = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started
      end
    end

    [ winner, loser ].each(&:join)

    expect(lost).to be(false)
    # It returned only after the winner committed — it was queued on the row
    # lock, not reading a stale snapshot.
    expect(blocked_for).to be >= hold / 2
    expect(Actor.find_by!(github_id: github_id).fetch_status).to eq("enqueued")
  end

  # D-023's other half: the claim and the job row share one transaction on the
  # one database, so neither can exist without the other. Both halves are
  # asserted, and the order matters. Only the pre-commit assertion can tell an
  # inline enqueue from a deferred one — an after_commit enqueue also leaves no
  # job row behind a rollback, while opening exactly the window D-023 closes
  # (claim committed, job not yet inserted). The knob it pins is the job
  # class's `enqueue_after_transaction_commit`; Rails 8.1's Active Job railtie
  # deliberately excludes that key from the application-level config it applies
  # to ActiveJob::Base, so nothing but this example guards the default.
  it "inserts the job row inside the claim transaction and rolls both back together" do
    actor = existing_actor
    enqueued_before_commit = nil

    Actor.transaction do
      Actor.claim_for_enrichment(github_id)
      EnrichActorJob.perform_later(actor.id)
      enqueued_before_commit = actor_jobs.count
      raise ActiveRecord::Rollback
    end

    expect(enqueued_before_commit).to eq(1)
    expect(actor.reload.fetch_status).to eq("pending")
    expect(actor_jobs.count).to eq(0)
  end
end
