require "rails_helper"

RSpec.describe Enrichable do
  shared_examples "an enrichable record" do
    def create_record(**overrides)
      described_class.create!(github_id: 42, url: "https://api.github.com/x", **identity, **overrides)
    end

    def claim
      described_class.claim_for_enrichment(42)
    end

    describe ".claim_for_enrichment" do
      it "claims a pending row and marks it enqueued" do
        record = create_record

        expect(claim).to be(true)
        expect(record.reload.fetch_status).to eq("enqueued")
      end

      it "claims a fetched row whose TTL has expired" do
        record = create_record(fetch_status: "fetched",
                               fetched_at: Enrichable::ENRICHMENT_TTL.ago - 1.hour)

        expect(claim).to be(true)
        expect(record.reload.fetch_status).to eq("enqueued")
      end

      it "wins at most once: a second claim on the same window loses" do
        create_record

        expect(claim).to be(true)
        expect(claim).to be(false)
      end

      it "does not claim a freshly fetched row (TTL gate)" do
        record = create_record(fetch_status: "fetched", fetched_at: 1.hour.ago)

        expect(claim).to be(false)
        expect(record.reload.fetch_status).to eq("fetched")
      end

      it "does not claim an in-flight (enqueued) row" do
        create_record(fetch_status: "enqueued")
        expect(claim).to be(false)
      end

      it "never claims terminal rows" do
        %w[not_found rejected].each do |terminal|
          described_class.delete_all
          record = create_record(fetch_status: terminal)

          expect(claim).to be(false)
          expect(record.reload.fetch_status).to eq(terminal)
        end
      end

      it "never claims a row without a url, even when pending" do
        create_record(url: nil)
        expect(claim).to be(false)
      end

      it "does not claim a different github_id" do
        create_record
        expect(described_class.claim_for_enrichment(43)).to be(false)
      end
    end

    describe ".release_claim" do
      it "returns an enqueued row to pending" do
        record = create_record(fetch_status: "enqueued")

        described_class.release_claim(record.id)

        expect(record.reload.fetch_status).to eq("pending")
      end

      it "never stomps a state other than enqueued" do
        %w[pending fetched not_found rejected].each do |status|
          described_class.delete_all
          record = create_record(fetch_status: status)

          described_class.release_claim(record.id)

          expect(record.reload.fetch_status).to eq(status)
        end
      end
    end
  end

  describe Actor do
    let(:identity) { { login: "octocat" } }
    it_behaves_like "an enrichable record"
  end

  describe Repository do
    let(:identity) { { full_name: "octocat/Hello-World" } }
    it_behaves_like "an enrichable record"
  end
end
