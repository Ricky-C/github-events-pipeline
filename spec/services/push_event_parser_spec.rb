require "rails_helper"

RSpec.describe PushEventParser do
  # First PushEvent on the captured page (D-015): kamkade/qvutir.
  let(:push) { GithubFixtures.first_push }

  def mutate(event, &mutation)
    event.deep_dup.tap(&mutation)
  end

  describe "a real captured PushEvent" do
    it "returns ok with the full column-ready attribute set" do
      result = described_class.call(push)

      expect(result).to be_ok
      expect(result.reason).to be_nil
      expect(result.attributes).to eq(
        push_id: 36859490315,
        ref: "refs/heads/main",
        head_sha: "32ed1387a903628c1c12d714071f76b0fb44a41a",
        before_sha: "ab3a30bc82432fa3043f55dfb9820916a11cb3ce",
        repository_github_id: 1293185578,
        repository_name: "kamkade/qvutir",
        actor_github_id: 298946723,
        actor_login: "kamkade",
        event_created_at: Time.utc(2026, 7, 8, 17, 31, 54)
      )
    end

    it "parses every PushEvent on the captured page" do
      expect(GithubFixtures.push_events.map { |event| described_class.call(event) }).to all(be_ok)
    end
  end

  describe "a missing before (first push to a ref)" do
    it "stores nil when the key is absent" do
      result = described_class.call(mutate(push) { |event| event["payload"].delete("before") })

      expect(result).to be_ok
      expect(result.attributes[:before_sha]).to be_nil
    end

    it "stores nil when the value is JSON null" do
      result = described_class.call(mutate(push) { |event| event["payload"]["before"] = nil })

      expect(result).to be_ok
      expect(result.attributes[:before_sha]).to be_nil
    end
  end

  describe "a created_at with an explicit numeric offset" do
    it "is accepted and stores the exact instant" do
      result = described_class.call(mutate(push) { |event| event["created_at"] = "2026-07-08T22:31:54+05:00" })

      expect(result).to be_ok
      expect(result.attributes[:event_created_at]).to eq(Time.utc(2026, 7, 8, 17, 31, 54))
    end
  end

  describe "malformed shapes" do
    {
      "a missing payload" =>
        [ ->(event) { event.delete("payload") }, "payload_not_object" ],
      "a payload that is an array" =>
        [ ->(event) { event["payload"] = [ "push" ] }, "payload_not_object" ],
      "a missing repo" =>
        [ ->(event) { event.delete("repo") }, "repo_not_object" ],
      "a missing actor" =>
        [ ->(event) { event.delete("actor") }, "actor_not_object" ],
      "a missing push_id" =>
        [ ->(event) { event["payload"].delete("push_id") }, "invalid_push_id" ],
      "a push_id sent as a string" =>
        [ ->(event) { event["payload"]["push_id"] = "36859490315" }, "invalid_push_id" ],
      "a push_id past bigint range" =>
        [ ->(event) { event["payload"]["push_id"] = 2**64 }, "invalid_push_id" ],
      "a missing ref" =>
        [ ->(event) { event["payload"].delete("ref") }, "invalid_ref" ],
      "a ref sent as an integer" =>
        [ ->(event) { event["payload"]["ref"] = 42 }, "invalid_ref" ],
      "an empty ref" =>
        [ ->(event) { event["payload"]["ref"] = "" }, "invalid_ref" ],
      "an oversized ref" =>
        [ ->(event) { event["payload"]["ref"] = "refs/heads/#{"a" * 245}" }, "invalid_ref" ],
      "a ref containing NUL" =>
        [ ->(event) { event["payload"]["ref"] = "refs/heads/nul\u0000branch" }, "invalid_ref" ],
      "a missing head" =>
        [ ->(event) { event["payload"].delete("head") }, "invalid_head_sha" ],
      "a 39-char head" =>
        [ ->(event) { event["payload"]["head"] = "a" * 39 }, "invalid_head_sha" ],
      "a head with a non-hex character" =>
        [ ->(event) { event["payload"]["head"] = "g#{"a" * 39}" }, "invalid_head_sha" ],
      "a present-but-invalid before" =>
        [ ->(event) { event["payload"]["before"] = "not-a-sha" }, "invalid_before_sha" ],
      "a repo id sent as a string" =>
        [ ->(event) { event["repo"]["id"] = "1293185578" }, "invalid_repository_id" ],
      "an oversized repository name" =>
        [ ->(event) { event["repo"]["name"] = "a" * 141 }, "invalid_repository_name" ],
      "a missing actor id" =>
        [ ->(event) { event["actor"].delete("id") }, "invalid_actor_id" ],
      "an oversized actor login" =>
        [ ->(event) { event["actor"]["login"] = "a" * 65 }, "invalid_actor_login" ],
      "an actor login containing NUL" =>
        [ ->(event) { event["actor"]["login"] = "kam\u0000kade" }, "invalid_actor_login" ],
      "a ref with invalid UTF-8 bytes" =>
        [ ->(event) { event["payload"]["ref"] = "refs/heads/bad\xC3" }, "invalid_ref" ],
      "a head with invalid UTF-8 bytes" =>
        [ ->(event) { event["payload"]["head"] = "\xC3#{"a" * 39}" }, "invalid_head_sha" ],
      "an actor login with invalid UTF-8 bytes" =>
        [ ->(event) { event["actor"]["login"] = "kam\xC3kade" }, "invalid_actor_login" ],
      "a missing created_at" =>
        [ ->(event) { event.delete("created_at") }, "invalid_created_at" ],
      "an unparseable created_at" =>
        [ ->(event) { event["created_at"] = "not-a-date" }, "invalid_created_at" ],
      "a created_at outside PG's comfortable range" =>
        [ ->(event) { event["created_at"] = "999999-01-01T00:00:00Z" }, "invalid_created_at" ],
      "a created_at before the year floor" =>
        [ ->(event) { event["created_at"] = "1999-12-31T23:59:59Z" }, "invalid_created_at" ],
      "a calendar-invalid created_at (Feb 30 normalizes instead of raising)" =>
        [ ->(event) { event["created_at"] = "2026-02-30T00:00:00Z" }, "invalid_created_at" ],
      "a created_at at hour 24 (normalizes to the next day)" =>
        [ ->(event) { event["created_at"] = "2026-07-08T24:00:00Z" }, "invalid_created_at" ],
      "a zone-less created_at (would parse as process-local time)" =>
        [ ->(event) { event["created_at"] = "2026-07-08T17:31:54" }, "invalid_created_at" ],
      "a fractional-seconds created_at (GitHub's exact whole-second shape only)" =>
        [ ->(event) { event["created_at"] = "2026-07-08T17:31:54.123Z" }, "invalid_created_at" ],
      "a D-018-scrubbed payload (rebuilds must not trust repaired bytes)" =>
        [ ->(event) { event["payload_scrubbed"] = true }, "payload_scrubbed" ]
    }.each do |description, (mutation, reason)|
      it "rejects #{description} as #{reason}" do
        result = described_class.call(mutate(push, &mutation))

        expect(result).to be_malformed
        expect(result.reason).to eq(reason)
        expect(result.attributes).to be_nil
      end
    end

    it "rejects a non-object event defensively" do
      result = described_class.call("not-an-event")

      expect(result).to be_malformed
      expect(result.reason).to eq("event_not_object")
    end
  end
end
