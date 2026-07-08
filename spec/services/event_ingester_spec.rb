require "rails_helper"

RSpec.describe EventIngester do
  subject(:ingester) { described_class.new(logger: logger) }

  let(:logger) { RecordingLogger.new }

  describe "a real /events page" do
    let(:page) { GithubFixtures.json_body(:events_200) }
    let(:push_count) { page.count { |event| event["type"] == "PushEvent" } }

    it "persists exactly the PushEvents with reconciling counts" do
      counts = ingester.ingest(page)

      expect(counts).to eq(
        events_seen: page.size,
        push_events_new: push_count,
        duplicates_skipped: 0,
        malformed_skipped: 0,
        structured_skipped: 0
      )
      expect(RawEvent.count).to eq(push_count)
      expect(RawEvent.distinct.pluck(:event_type)).to eq([ "PushEvent" ])
      expect(PushEvent.count).to eq(push_count)
    end

    it "stores the full raw payload and a received_at timestamp" do
      ingester.ingest(page)

      sample = page.find { |event| event["type"] == "PushEvent" }
      row = RawEvent.find_by!(github_event_id: sample["id"])
      expect(row.payload).to eq(sample)
      expect(row.received_at).to be_present
    end

    it "stores the structured projection alongside the raw row" do
      ingester.ingest(page)

      sample = page.find { |event| event["type"] == "PushEvent" }
      row = PushEvent.find_by!(github_event_id: sample["id"])
      expect(row.push_id).to eq(sample["payload"]["push_id"])
      expect(row.ref).to eq(sample["payload"]["ref"])
      expect(row.head_sha).to eq(sample["payload"]["head"])
      expect(row.before_sha).to eq(sample["payload"]["before"])
      expect(row.repository_github_id).to eq(sample["repo"]["id"])
      expect(row.repository_name).to eq(sample["repo"]["name"])
      expect(row.actor_github_id).to eq(sample["actor"]["id"])
      expect(row.actor_login).to eq(sample["actor"]["login"])
      expect(row.event_created_at).to eq(Time.iso8601(sample["created_at"]))
    end

    it "skips every row as a duplicate on re-ingest (idempotency)" do
      ingester.ingest(page)
      counts = ingester.ingest(page)

      expect(counts).to eq(
        events_seen: page.size,
        push_events_new: 0,
        duplicates_skipped: push_count,
        malformed_skipped: 0,
        structured_skipped: 0
      )
      expect(RawEvent.count).to eq(push_count)
      expect(PushEvent.count).to eq(push_count)
    end

    it "backfills structured rows for raw duplicates on re-ingest (self-healing)" do
      ingester.ingest(page)
      # Simulates raw rows that predate push_events (or arrived while the
      # table was empty): the raw insert reports duplicates, yet the
      # structured projection must still land.
      PushEvent.delete_all

      counts = ingester.ingest(page)

      expect(counts[:duplicates_skipped]).to eq(push_count)
      expect(PushEvent.count).to eq(push_count)
    end
  end

  describe "malformed payloads (first-class cases)" do
    let(:page) do
      JSON.parse(Rails.root.join("spec/fixtures/github/events_page_with_malformed.json").read)
    end

    it "skips each malformed element with a warning, keeps the valid ones, never raises" do
      counts = ingester.ingest(page)

      # Fixture composition: 2 valid PushEvents, 1 valid non-push, plus a
      # non-object element, a PushEvent missing id, one with an integer id,
      # and one with an over-length id.
      expect(counts).to eq(
        events_seen: 7,
        push_events_new: 2,
        duplicates_skipped: 0,
        malformed_skipped: 4,
        structured_skipped: 0
      )
      expect(RawEvent.count).to eq(2)
      expect(PushEvent.count).to eq(2)

      warnings = logger.messages(:warn)
      expect(warnings.length).to eq(4)
      expect(warnings).to all(include(event: "ingest.malformed"))
      expect(warnings.map { |entry| entry[:reason] })
        .to contain_exactly("element_not_object", "invalid_event_id", "invalid_event_id", "invalid_event_id")
    end

    it "truncates the offending id in the warning rather than logging payloads" do
      ingester.ingest(page)

      details = logger.messages(:warn).map { |entry| entry[:detail] }
      expect(details.map(&:length)).to all(be <= EventIngester::MAX_EVENT_ID_LENGTH)
    end
  end

  describe "payloads the parser rejects (raw kept, structured skipped)" do
    let(:pushes) do
      GithubFixtures.json_body(:events_200).select { |event| event["type"] == "PushEvent" }.first(2)
    end
    let(:mangled) do
      pushes[1].deep_dup.tap { |event| event["payload"].delete("push_id") }
    end

    it "persists the raw row, skips the structured row, warns once, never raises" do
      counts = ingester.ingest([ pushes[0], mangled ])

      expect(counts).to eq(
        events_seen: 2,
        push_events_new: 2,
        duplicates_skipped: 0,
        malformed_skipped: 0,
        structured_skipped: 1
      )
      expect(RawEvent.count).to eq(2)
      expect(PushEvent.count).to eq(1)
      expect(PushEvent.find_by(github_event_id: mangled["id"])).to be_nil
      expect(logger.messages(:warn)).to contain_exactly(
        hash_including(event: "ingest.structured_skipped",
                       reason: "invalid_push_id", detail: mangled["id"])
      )
    end
  end

  describe "degenerate bodies" do
    it "warns and returns zeroed counts for a non-array body" do
      counts = ingester.ingest("message" => "API rate limit exceeded")

      expect(counts.values).to all(eq(0))
      expect(logger.messages(:warn))
        .to contain_exactly(hash_including(event: "ingest.malformed", reason: "body_not_array"))
    end

    it "handles nil the same way" do
      expect(ingester.ingest(nil).values).to all(eq(0))
    end

    it "returns zeroed counts for an empty page without touching the database" do
      expect(ingester.ingest([]).values).to all(eq(0))
      expect(RawEvent.count).to eq(0)
    end
  end

  describe "rows PostgreSQL refuses (jsonb cannot store NUL)" do
    let(:pushes) do
      GithubFixtures.json_body(:events_200).select { |event| event["type"] == "PushEvent" }.first(3)
    end
    let(:poisoned) do
      pushes[1].deep_dup.tap { |event| event["payload"]["ref"] = "refs/heads/nul\u0000branch" }
    end

    it "falls back to per-row inserts, scrubs the refused row, and keeps the batch" do
      counts = ingester.ingest([ pushes[0], poisoned, pushes[2] ])

      expect(counts).to eq(
        events_seen: 3,
        push_events_new: 3,
        duplicates_skipped: 0,
        malformed_skipped: 0,
        structured_skipped: 1
      )
      row = RawEvent.find_by!(github_event_id: poisoned["id"])
      expect(row.payload["payload_scrubbed"]).to be(true)
      expect(row.payload["payload"]["ref"]).to eq("refs/heads/nulbranch")
      # The NUL sits in an extracted field, so two independent outcomes
      # fire: raw durability scrubs (D-018), the parser rejects (D-020) —
      # scrubbed raw kept, structured skipped, one warn each.
      expect(PushEvent.count).to eq(2)
      expect(PushEvent.find_by(github_event_id: poisoned["id"])).to be_nil
      expect(logger.messages(:warn)).to contain_exactly(
        hash_including(reason: "payload_scrubbed", detail: poisoned["id"]),
        hash_including(event: "ingest.structured_skipped",
                       reason: "invalid_ref", detail: poisoned["id"])
      )
    end

    it "keeps the structured row when the NUL lives outside extracted fields" do
      poisoned_elsewhere = pushes[1].deep_dup.tap do |event|
        event["actor"]["display_login"] = "kam\u0000kade"
      end

      counts = ingester.ingest([ poisoned_elsewhere ])

      expect(counts).to eq(
        events_seen: 1,
        push_events_new: 1,
        duplicates_skipped: 0,
        malformed_skipped: 0,
        structured_skipped: 0
      )
      expect(RawEvent.find_by!(github_event_id: poisoned_elsewhere["id"])
        .payload["payload_scrubbed"]).to be(true)
      structured = PushEvent.find_by!(github_event_id: poisoned_elsewhere["id"])
      expect(structured.actor_login).to eq(pushes[1]["actor"]["login"])
      expect(logger.messages(:warn))
        .to contain_exactly(hash_including(reason: "payload_scrubbed"))
    end

    it "rolls back the raw rows when the structured insert fails — no torn events" do
      allow(PushEvent).to receive(:insert_all)
        .and_raise(ActiveRecord::StatementInvalid.new("boom"))

      expect { ingester.ingest(pushes) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(RawEvent.count).to eq(0)
      expect(PushEvent.count).to eq(0)
    end

    it "re-raises the batch error when every row is refused (not row-specific)" do
      allow(RawEvent).to receive(:insert_all)
        .and_raise(ActiveRecord::StatementInvalid.new("server closed the connection"))

      expect { ingester.ingest(pushes) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(logger.messages(:warn).map { |entry| entry[:reason] })
        .to all(eq("row_rejected"))
    end

    it "rejects an id containing NUL upfront without touching the database" do
      bad = pushes[0].deep_dup.tap { |event| event["id"] = "123\u0000456" }

      counts = ingester.ingest([ bad ])

      expect(counts).to eq(
        events_seen: 1,
        push_events_new: 0,
        duplicates_skipped: 0,
        malformed_skipped: 1,
        structured_skipped: 0
      )
      expect(RawEvent.count).to eq(0)
      expect(logger.messages(:warn))
        .to contain_exactly(hash_including(reason: "invalid_event_id", detail: "123456"))
    end
  end

  it "counts an in-page repeated id as a duplicate so counts still reconcile" do
    push = GithubFixtures.json_body(:events_200).find { |event| event["type"] == "PushEvent" }
    counts = ingester.ingest([ push, push.dup ])

    expect(counts).to eq(
      events_seen: 2,
      push_events_new: 1,
      duplicates_skipped: 1,
      malformed_skipped: 0,
      structured_skipped: 0
    )
  end
end
