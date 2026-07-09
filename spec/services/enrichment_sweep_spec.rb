require "rails_helper"

RSpec.describe EnrichmentSweep do
  include ActiveJob::TestHelper

  # Named, not described_class: the nested `describe Actor` blocks rebind it.
  subject(:sweep) { EnrichmentSweep.new(logger: logger) }

  let(:logger) { RecordingLogger.new }

  before { freeze_time }

  def swept_entries = logger.messages(:warn).select { |message| message[:event] == "enrich.swept" }

  # Solid Queue writes a job row for every enqueue, always with a scheduled_at
  # (Job.enqueue defaults it to Time.current) and an execution row created by
  # its own after_create hook.
  def job_for(job_class, record_id, scheduled_at: Time.current)
    SolidQueue::Job.create!(queue_name: "enrichment", class_name: job_class.name,
                            scheduled_at: scheduled_at,
                            arguments: { "job_class" => job_class.name, "arguments" => [ record_id ] })
  end

  def clear_executions(job)
    [ job.ready_execution, job.scheduled_execution, job.claimed_execution ].compact.each(&:destroy!)
  end

  # What Process#prune does: destroy the claimed execution, record the failure.
  # The job row survives with finished_at still NULL, and nothing re-runs it.
  def dead_letter(job)
    clear_executions(job)
    SolidQueue::FailedExecution.create!(
      job_id: job.id,
      error: { "exception_class" => "SolidQueue::Processes::ProcessPrunedError", "message" => "pruned" }
    )
    job
  end

  shared_examples "an enrichment sweep" do
    let!(:record) do
      described_model.create!(github_id: 4242, url: "https://api.github.com/x", **identity,
                              fetch_status: "enqueued").tap do |row|
        row.update_columns(updated_at: 10.minutes.ago)
      end
    end

    describe "a record whose job was dead-lettered" do
      before { dead_letter(job_for(described_job, record.id)) }

      it "releases the claim, re-claims it, and enqueues a fresh job" do
        expect(sweep.call).to eq(1)

        expect(record.reload.fetch_status).to eq("enqueued")
        expect(enqueued_jobs.map { |job| job["job_class"] }).to eq([ described_job.name ])
        expect(enqueued_jobs.first["arguments"]).to eq([ record.id ])
        expect(swept_entries.first)
          .to include(entity: described_model.model_name.singular, github_id: 4242,
                      reason: "dead_lettered", reclaimed: true)
      end

      it "leaves the dead-letter row as the operator's record of what happened" do
        expect { sweep.call }.not_to change(SolidQueue::FailedExecution, :count)
      end
    end

    it "sweeps a record whose job row is gone entirely" do
      expect(sweep.call).to eq(1)

      expect(swept_entries.first).to include(reason: "no_job", reclaimed: true)
      expect(enqueued_jobs.size).to eq(1)
    end

    it "sweeps a record whose job finished without settling it" do
      job = job_for(described_job, record.id)
      clear_executions(job)
      job.update!(finished_at: Time.current)

      expect(sweep.call).to eq(1)
      expect(swept_entries.first).to include(reason: "no_job")
    end

    it "frees a record parked beyond the rate window and discards the dead job" do
      job = job_for(described_job, record.id,
                    scheduled_at: 2.years.from_now)

      expect(sweep.call).to eq(1)

      expect(swept_entries.first).to include(reason: "scheduled_beyond_window", reclaimed: true)
      # Left behind, it would fire in two years against a record long since
      # settled — and would keep the record looking stranded on every sweep.
      expect(SolidQueue::Job.exists?(job.id)).to be(false)
    end

    it "never touches a record whose job is still live" do
      job_for(described_job, record.id)

      expect(sweep.call).to eq(0)
      expect(enqueued_jobs).to be_empty
      expect(swept_entries).to be_empty
    end

    it "never touches a record parked inside the rate window" do
      job_for(described_job, record.id, scheduled_at: 30.minutes.from_now)

      expect(sweep.call).to eq(0)
      expect(record.reload.fetch_status).to eq("enqueued")
    end

    it "never touches a record claimed within the grace period" do
      record.update_columns(updated_at: 1.second.ago)

      expect(sweep.call).to eq(0)
      expect(enqueued_jobs).to be_empty
    end

    it "releases a guard-refused record to pending without enqueueing it" do
      record.update_columns(url: nil)
      dead_letter(job_for(described_job, record.id))

      expect(sweep.call).to eq(1)

      expect(record.reload.fetch_status).to eq("pending")
      expect(enqueued_jobs).to be_empty
      expect(swept_entries.first).to include(reclaimed: false)
    end

    it "never touches a record in any state but enqueued" do
      %w[pending fetched not_found rejected].each do |status|
        record.update_columns(fetch_status: status, updated_at: 10.minutes.ago)

        expect(sweep.call).to eq(0)
        expect(record.reload.fetch_status).to eq(status)
      end
    end

    it "ignores a live job belonging to a different record" do
      other = described_model.create!(github_id: 4343, url: "https://api.github.com/y", **identity)
      job_for(described_job, other.id)

      expect(sweep.call).to eq(1)
      expect(swept_entries.first).to include(github_id: 4242)
    end
  end

  describe Actor do
    let(:described_model) { Actor }
    let(:described_job) { EnrichActorJob }
    let(:identity) { { login: "octocat" } }
    it_behaves_like "an enrichment sweep"
  end

  describe Repository do
    let(:described_model) { Repository }
    let(:described_job) { EnrichRepositoryJob }
    let(:identity) { { full_name: "octocat/Hello-World" } }
    it_behaves_like "an enrichment sweep"
  end

  it "logs a summary even when nothing is stranded" do
    sweep.call

    expect(logger.messages(:info).last).to include(event: "enrich.sweep", swept: 0)
  end

  it "sweeps actors and repositories in one pass" do
    actor = Actor.create!(github_id: 1, login: "a", url: "https://api.github.com/a",
                          fetch_status: "enqueued")
    repository = Repository.create!(github_id: 2, full_name: "a/b", url: "https://api.github.com/b",
                                    fetch_status: "enqueued")
    [ actor, repository ].each { |record| record.update_columns(updated_at: 10.minutes.ago) }

    expect(sweep.call).to eq(2)
    expect(enqueued_jobs.map { |job| job["job_class"] })
      .to contain_exactly("EnrichActorJob", "EnrichRepositoryJob")
  end
end
