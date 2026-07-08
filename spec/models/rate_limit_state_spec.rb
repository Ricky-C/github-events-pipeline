require "rails_helper"

RSpec.describe RateLimitState do
  describe ".current" do
    it "is nil before any response has been observed" do
      expect(described_class.current).to be_nil
    end
  end

  describe ".record!" do
    it "creates the single logical row on first write" do
      described_class.record!(remaining: 59)

      expect(described_class.count).to eq(1)
      expect(described_class.current.remaining).to eq(59)
    end

    it "converges every write onto the same row" do
      described_class.record!(remaining: 59)
      described_class.record!(remaining: 58)

      expect(described_class.count).to eq(1)
      expect(described_class.current.remaining).to eq(58)
    end

    it "updates only the observed columns, preserving the rest" do
      described_class.record!(etag: 'W/"abc"', poll_interval: 60, remaining: 59)
      described_class.record!(remaining: 58, reset_at: Time.at(1_783_600_000).utc)

      state = described_class.current
      expect(state.etag).to eq('W/"abc"')
      expect(state.poll_interval).to eq(60)
      expect(state.remaining).to eq(58)
      expect(state.reset_at).to eq(Time.at(1_783_600_000).utc)
    end

    it "maintains updated_at across upserts" do
      described_class.record!(remaining: 59)
      expect(described_class.current.updated_at).to be_present
    end
  end
end
