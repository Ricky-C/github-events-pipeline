require "rails_helper"

RSpec.describe EventIngester do
  subject(:ingester) { described_class.new(logger: logger) }

  let(:logger) { RecordingLogger.new }

  # empty_counts is the documented single owner of the counts shape; each
  # example states only its nonzero deltas so a shape change is a one-line
  # diff here instead of one edit per literal.
  def counts_with(**deltas)
    described_class.empty_counts.merge(**deltas)
  end

  describe "a real /events page" do
    let(:page) { GithubFixtures.json_body(:events_200) }
    let(:push_count) { GithubFixtures.push_events.size }

    it "persists exactly the PushEvents with reconciling counts" do
      counts = ingester.ingest(page)

      expect(counts).to eq(counts_with(events_seen: page.size, push_events_new: push_count))
      expect(RawEvent.count).to eq(push_count)
      expect(RawEvent.distinct.pluck(:event_type)).to eq([ "PushEvent" ])
      expect(PushEvent.count).to eq(push_count)
    end

    it "stores the full raw payload and a received_at timestamp" do
      ingester.ingest(page)

      sample = GithubFixtures.first_push
      row = RawEvent.find_by!(github_event_id: sample["id"])
      expect(row.payload).to eq(sample)
      expect(row.received_at).to be_present
    end

    it "stores the structured projection alongside the raw row" do
      ingester.ingest(page)

      sample = GithubFixtures.first_push
      row = PushEvent.find_by!(github_event_id: sample["id"])
      # The field-by-field mapping is pinned in the parser's own spec; this
      # spec owns only the wiring — parser output lands as columns.
      expect(row).to have_attributes(PushEventParser.call(sample).attributes)
    end

    it "skips every row as a duplicate on re-ingest (idempotency)" do
      ingester.ingest(page)
      counts = ingester.ingest(page)

      expect(counts).to eq(counts_with(events_seen: page.size, duplicates_skipped: push_count))
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
      expect(counts).to eq(counts_with(events_seen: 7, push_events_new: 2, malformed_skipped: 4))
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
    let(:pushes) { GithubFixtures.push_events.first(2) }
    let(:mangled) do
      pushes[1].deep_dup.tap { |event| event["payload"].delete("push_id") }
    end

    it "persists the raw row, skips the structured row, warns once, never raises" do
      counts = ingester.ingest([ pushes[0], mangled ])

      expect(counts).to eq(counts_with(events_seen: 2, push_events_new: 2, structured_skipped: 1))
      expect(RawEvent.count).to eq(2)
      expect(PushEvent.count).to eq(1)
      expect(PushEvent.find_by(github_event_id: mangled["id"])).to be_nil
      expect(logger.messages(:warn)).to contain_exactly(
        hash_including(event: "ingest.structured_skipped",
                       reason: "invalid_push_id", detail: mangled["id"])
      )
    end

    it "does not claim a skipped projection for a row the database rejected" do
      # push_id past bigint fails the parser, and past ~131k digits jsonb
      # refuses the raw payload too ("value overflows numeric format") —
      # the scrub can't fix that. The event must land in malformed_skipped
      # alone: a structured_skipped warn here would falsely promise that a
      # raw row was kept to rebuild from.
      doomed = pushes[1].deep_dup.tap { |event| event["payload"]["push_id"] = 10**140_000 }

      counts = ingester.ingest([ pushes[0], doomed ])

      expect(counts).to eq(counts_with(events_seen: 2, push_events_new: 1, malformed_skipped: 1))
      expect(RawEvent.find_by(github_event_id: doomed["id"])).to be_nil
      expect(logger.messages(:warn)).to contain_exactly(hash_including(reason: "row_rejected"))
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
    let(:pushes) { GithubFixtures.push_events.first(3) }
    let(:poisoned) do
      pushes[1].deep_dup.tap { |event| event["payload"]["ref"] = "refs/heads/nul\u0000branch" }
    end

    it "falls back to per-row inserts, scrubs the refused row, and keeps the batch" do
      counts = ingester.ingest([ pushes[0], poisoned, pushes[2] ])

      expect(counts).to eq(counts_with(events_seen: 3, push_events_new: 3, structured_skipped: 1))
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

      expect(counts).to eq(counts_with(events_seen: 1, push_events_new: 1))
      expect(RawEvent.find_by!(github_event_id: poisoned_elsewhere["id"])
        .payload["payload_scrubbed"]).to be(true)
      structured = PushEvent.find_by!(github_event_id: poisoned_elsewhere["id"])
      expect(structured.actor_login).to eq(pushes[1]["actor"]["login"])
      expect(logger.messages(:warn))
        .to contain_exactly(hash_including(reason: "payload_scrubbed"))
    end

    it "retries a transiently-refused row unscrubbed — no forged scrub marker" do
      attempts = 0
      allow(RawEvent).to receive(:insert_all).and_wrap_original do |original, *args, **kwargs|
        attempts += 1
        raise ActiveRecord::Deadlocked, "deadlock detected" if attempts <= 2
        original.call(*args, **kwargs)
      end

      counts = ingester.ingest([ pushes[0] ])

      expect(counts).to eq(counts_with(events_seen: 1, push_events_new: 1))
      expect(RawEvent.find_by!(github_event_id: pushes[0]["id"]).payload)
        .not_to have_key("payload_scrubbed")
      expect(PushEvent.count).to eq(1)
      expect(logger.messages(:warn)).to be_empty
    end

    it "retries a connection-blip row unscrubbed too — data shape, not an allowlist, decides" do
      attempts = 0
      allow(RawEvent).to receive(:insert_all).and_wrap_original do |original, *args, **kwargs|
        attempts += 1
        raise ActiveRecord::ConnectionFailed, "server closed the connection unexpectedly" if attempts <= 2
        original.call(*args, **kwargs)
      end

      counts = ingester.ingest([ pushes[0] ])

      expect(counts).to eq(counts_with(events_seen: 1, push_events_new: 1))
      expect(RawEvent.find_by!(github_event_id: pushes[0]["id"]).payload)
        .not_to have_key("payload_scrubbed")
      expect(logger.messages(:warn)).to be_empty
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

      expect(counts).to eq(counts_with(events_seen: 1, malformed_skipped: 1))
      expect(RawEvent.count).to eq(0)
      expect(logger.messages(:warn))
        .to contain_exactly(hash_including(reason: "invalid_event_id", detail: "123456"))
    end
  end

  describe "rows jsonb cannot serialize (invalid UTF-8)" do
    let(:pushes) { GithubFixtures.push_events.first(2) }

    it "scrubs the raw row and keeps the structured row when the bad bytes sit outside extracted fields" do
      poisoned = pushes[0].deep_dup.tap do |event|
        event["actor"]["display_login"] = "kam\xC3kade"
      end

      counts = ingester.ingest([ poisoned ])

      expect(counts).to eq(counts_with(events_seen: 1, push_events_new: 1))
      raw = RawEvent.find_by!(github_event_id: poisoned["id"])
      expect(raw.payload["payload_scrubbed"]).to be(true)
      expect(raw.payload["actor"]["display_login"]).to eq("kam�kade")
      expect(PushEvent.find_by!(github_event_id: poisoned["id"]).actor_login)
        .to eq(pushes[0]["actor"]["login"])
      expect(logger.messages(:warn))
        .to contain_exactly(hash_including(reason: "payload_scrubbed"))
    end

    it "keeps the batch, scrubs raw, and skips structured when the bad bytes sit in an extracted field" do
      poisoned = pushes[1].deep_dup.tap do |event|
        event["payload"]["ref"] = "refs/heads/bad\xC3"
      end

      counts = ingester.ingest([ pushes[0], poisoned ])

      expect(counts).to eq(counts_with(events_seen: 2, push_events_new: 2, structured_skipped: 1))
      expect(RawEvent.count).to eq(2)
      expect(RawEvent.find_by!(github_event_id: poisoned["id"])
        .payload["payload_scrubbed"]).to be(true)
      expect(PushEvent.find_by(github_event_id: poisoned["id"])).to be_nil
      expect(logger.messages(:warn)).to contain_exactly(
        hash_including(reason: "payload_scrubbed", detail: poisoned["id"]),
        hash_including(event: "ingest.structured_skipped",
                       reason: "invalid_ref", detail: poisoned["id"])
      )
    end
  end

  describe "in-page repeats (each id parsed, counted, and warned at most once)" do
    let(:push) { GithubFixtures.first_push }
    let(:mangled) do
      push.deep_dup.tap { |event| event["payload"].delete("push_id") }
    end

    it "counts a repeated id as a duplicate so counts still reconcile" do
      counts = ingester.ingest([ push, push.dup ])

      expect(counts).to eq(counts_with(events_seen: 2, push_events_new: 1, duplicates_skipped: 1))
    end

    it "warns and counts a repeated parse-rejected id once" do
      counts = ingester.ingest([ mangled, mangled.deep_dup ])

      expect(counts).to eq(counts_with(events_seen: 2, push_events_new: 1,
                                       duplicates_skipped: 1, structured_skipped: 1))
      expect(logger.messages(:warn))
        .to contain_exactly(hash_including(event: "ingest.structured_skipped",
                                           reason: "invalid_push_id", detail: mangled["id"]))
    end

    it "never claims a skip for an id whose projection was persisted (divergent copies)" do
      # First occurrence wins, matching the raw row that is persisted — the
      # later mangled copy must not warn a skip that never happened.
      counts = ingester.ingest([ push, mangled ])

      expect(counts).to eq(counts_with(events_seen: 2, push_events_new: 1, duplicates_skipped: 1))
      expect(PushEvent.find_by!(github_event_id: push["id"])).to be_present
      expect(logger.messages(:warn)).to be_empty
    end
  end

  describe "enrichment enqueueing" do
    let(:page) { GithubFixtures.json_body(:events_200) }
    let(:push_count) { GithubFixtures.push_events.size }
    let(:queuer) { instance_double(EnrichmentQueuer, call: nil) }

    subject(:ingester) { described_class.new(logger: logger, queuer: queuer) }

    it "hands every parsed-ok row to the queuer after persistence" do
      ingester.ingest(page)

      expect(queuer).to have_received(:call) do |rows|
        expect(rows.size).to eq(push_count)
        rows.each do |row|
          expect(row[:structured]).to be_present
          expect(row[:payload]).to be_a(Hash)
        end
      end
    end

    it "excludes parse-rejected events from enrichment" do
      good = GithubFixtures.push_events.first
      bad = GithubFixtures.push_events.second.deep_dup
      bad["payload"]["head"] = "not-a-sha"

      ingester.ingest([ good, bad ])

      expect(queuer).to have_received(:call) do |rows|
        expect(rows.map { |row| row[:github_event_id] }).to eq([ good["id"] ])
      end
    end

    it "absorbs a queuer failure without touching the page's counts" do
      allow(queuer).to receive(:call).and_raise(RuntimeError, "boom")

      counts = ingester.ingest(page)

      expect(counts).to eq(counts_with(events_seen: page.size, push_events_new: push_count))
      expect(RawEvent.count).to eq(push_count)
      expect(logger.messages(:error).first)
        .to include(event: "enrich.enqueue_failed", error_class: "RuntimeError")
    end
  end
end
