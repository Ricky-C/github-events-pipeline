require "rails_helper"

RSpec.describe EnrichActorJob do
  include ActiveJob::TestHelper

  let(:user_url) { "https://api.github.com/users/octocat" }
  let(:actor) do
    Actor.create!(github_id: 583231, login: "octocat", url: user_url,
                  fetch_status: "enqueued")
  end

  def stub_fetcher(outcome)
    fetcher = instance_double(EnrichmentFetcher, call: outcome)
    allow(EnrichmentFetcher).to receive(:new).and_return(fetcher)
    fetcher
  end

  it "does nothing for a missing record id" do
    expect { described_class.perform_now(-1) }.not_to raise_error
    expect(WebMock).not_to have_requested(:get, /./)
  end

  describe "parked outcome" do
    it "re-enqueues a fresh job at run_at without consuming retry attempts" do
      run_at = 10.minutes.from_now
      stub_fetcher(EnrichmentFetcher::Outcome.new(action: :parked, run_at: run_at))

      described_class.perform_now(actor.id)

      # A fresh scheduled job, not a retry: executions stays 0 so parking
      # can repeat indefinitely without eating the transient-retry cap.
      expect(enqueued_jobs.size).to eq(1)
      expect(enqueued_jobs.first).to include(
        "job_class" => "EnrichActorJob", "executions" => 0, "arguments" => [ actor.id ]
      )
      expect(Time.at(enqueued_jobs.first[:at]).to_i).to eq(run_at.to_i)
      # Still enqueued: parked in-flight is the dedup while waiting.
      expect(actor.reload.fetch_status).to eq("enqueued")
    end
  end

  describe "retry outcome" do
    it "raises for retry_on, which schedules a backed-off retry" do
      stub_fetcher(EnrichmentFetcher::Outcome.new(action: :retry, error: "transient_error boom"))

      described_class.perform_now(actor.id)

      retried = enqueued_jobs.first
      expect(retried).to include("job_class" => "EnrichActorJob", "executions" => 1)
      expect(actor.reload.fetch_status).to eq("enqueued")
    end

    it "releases the claim and logs when retries are exhausted" do
      stub_fetcher(EnrichmentFetcher::Outcome.new(action: :retry, error: "transient_error boom"))
      allow(Rails.logger).to receive(:error)

      described_class.perform_now(actor.id)
      # Replay each scheduled retry exactly as the queue would; the fifth
      # execution exhausts attempts and runs the give-up block instead of
      # scheduling another retry.
      4.times { ActiveJob::Base.execute(enqueued_jobs.shift) }

      expect(actor.reload.fetch_status).to eq("pending")
      expect(enqueued_jobs).to be_empty
      expect(Rails.logger).to have_received(:error)
        .with(hash_including(event: "enrich.retry_exhausted", record_id: actor.id))
    end
  end

  describe "unexpected error" do
    it "releases the claim and re-raises" do
      fetcher = instance_double(EnrichmentFetcher)
      allow(fetcher).to receive(:call).and_raise(RuntimeError, "boom")
      allow(EnrichmentFetcher).to receive(:new).and_return(fetcher)

      expect { described_class.perform_now(actor.id) }.to raise_error(RuntimeError, "boom")
      expect(actor.reload.fetch_status).to eq("pending")
    end
  end

  describe "park then run (exit criterion 3 in miniature)" do
    it "parks under an exhausted budget and enriches once the window resets" do
      RateLimitState.record!(remaining: 0, reset_at: 30.minutes.from_now)

      described_class.perform_now(actor.id)

      expect(WebMock).not_to have_requested(:get, /./)
      expect(actor.reload.fetch_status).to eq("enqueued")
      expect(enqueued_jobs.size).to eq(1)

      # The window rolls over and the parked job fires.
      RateLimitState.record!(remaining: 40, reset_at: 90.minutes.from_now)
      stub_request(:get, user_url).to_return(GithubFixtures.response(:actor_200))

      described_class.perform_now(actor.id)

      actor.reload
      expect(actor.fetch_status).to eq("fetched")
      expect(actor.data).to eq(GithubFixtures.json_body(:actor_200))
    end
  end
end
