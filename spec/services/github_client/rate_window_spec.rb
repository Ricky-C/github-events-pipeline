require "rails_helper"

RSpec.describe GithubClient::RateWindow do
  let(:now) { Time.utc(2026, 7, 9, 12, 0, 0) }

  describe ".clamp" do
    it "passes an honest wait through" do
      expect(described_class.clamp(30)).to eq(30)
    end

    it "floors at one second, so a zero wait never becomes a hot loop" do
      expect(described_class.clamp(0)).to eq(1)
      expect(described_class.clamp(-5)).to eq(1)
    end

    it "bounds a wait at the one-hour primary window" do
      expect(described_class.clamp(70.years.to_i)).to eq(described_class::MAX_WAIT)
    end
  end

  # The precedence both callers now share. Pinned here rather than only in
  # each caller's specs, because the point of the extraction is that the two
  # can no longer disagree (D-025).
  describe ".wait" do
    def wait(retry_after: nil, reset_at: nil, fallback: 60)
      described_class.wait(retry_after: retry_after, reset_at: reset_at,
                           now: now, fallback: fallback)
    end

    # A secondary/abuse limit asks for a short wait while the very same
    # response still reports the primary bucket's far-off reset.
    it "prefers Retry-After over reset_at when a response carries both" do
      expect(wait(retry_after: 90, reset_at: now + 3000)).to eq(90)
    end

    it "waits the ceiling of the delta to a future reset_at" do
      expect(wait(reset_at: now + 30.5)).to eq(31)
    end

    # A reset already behind us says the mirror is stale, not that the window
    # rolled. Blind-wait rather than retry in a second.
    it "falls back when reset_at is already in the past" do
      expect(wait(reset_at: now - 30, fallback: 60)).to eq(60)
    end

    it "falls back when neither header is present" do
      expect(wait(fallback: 45)).to eq(45)
    end

    it "clamps a far-future reset_at to the rate window" do
      expect(wait(reset_at: now + 70.years)).to eq(described_class::MAX_WAIT)
    end

    it "clamps an absurd Retry-After to the rate window" do
      expect(wait(retry_after: 99_999_999)).to eq(described_class::MAX_WAIT)
    end

    it "clamps a fallback a caller set beyond the window" do
      expect(wait(fallback: 99_999_999)).to eq(described_class::MAX_WAIT)
    end

    # Zero is a value, not an absence: it must win over reset_at and then be
    # floored, never be mistaken for "no Retry-After".
    it "floors a Retry-After of zero at one second" do
      expect(wait(retry_after: 0, reset_at: now + 3000)).to eq(1)
    end
  end
end
