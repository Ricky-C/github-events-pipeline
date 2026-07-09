require "rails_helper"

RSpec.describe GithubClient::Budget do
  describe "#spendable?" do
    it "is true at the reserve boundary only above the reserve" do
      expect(described_class.new(6, nil, nil).spendable?(reserve: 5)).to be(true)
      expect(described_class.new(5, nil, nil).spendable?(reserve: 5)).to be(false)
    end

    it "is optimistic when the budget is unknown" do
      expect(described_class.new(nil, nil, nil).spendable?(reserve: 5)).to be(true)
    end

    it "is false at zero with no reserve" do
      expect(described_class.new(0, nil, nil).spendable?).to be(false)
    end

    # The stale-mirror escape. Nothing refreshes `remaining` until some
    # request is made, so an exhausted budget whose window has already rolled
    # has to be spendable — otherwise the caller that would refresh it is the
    # caller waiting on it (D-023, D-025).
    describe "once the observed window has rolled" do
      let(:now) { Time.current }

      it "is spendable even at zero" do
        expect(described_class.new(0, now - 1.second, nil).spendable?(at: now)).to be(true)
      end

      it "counts the reset instant itself as rolled" do
        expect(described_class.new(0, now, nil).spendable?(at: now)).to be(true)
      end

      it "is not spendable while that window is still open" do
        expect(described_class.new(0, now + 1.second, nil).spendable?(reserve: 5, at: now)).to be(false)
      end

      it "cannot escape the reserve when no reset_at has ever been observed" do
        expect(described_class.new(0, nil, nil).spendable?(reserve: 5, at: now)).to be(false)
      end
    end
  end

  describe "#exhausted?" do
    it "is true only when remaining is known and zero" do
      expect(described_class.new(0, nil, nil).exhausted?).to be(true)
      expect(described_class.new(1, nil, nil).exhausted?).to be(false)
      expect(described_class.new(nil, nil, nil).exhausted?).to be(false)
    end
  end
end

RSpec.describe GithubClient, "#budget" do
  subject(:client) { described_class.new }

  it "is unknown before any response and known after the first" do
    expect(client.budget.unknown?).to be(true)

    stub_request(:get, "https://api.github.com/events")
      .to_return(GithubFixtures.response(:events_200))
    client.poll_events

    budget = client.budget
    expect(budget.unknown?).to be(false)
    expect(budget.remaining).to eq(GithubFixtures.header(:events_200, "x-ratelimit-remaining").to_i)
  end
end
