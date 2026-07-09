# Takes one parsed /events page, keeps the PushEvents, and lands each in
# raw_events plus its structured push_events projection — both inside one
# idempotent transaction, with a savepointed per-row fallback when
# PostgreSQL refuses a row the pre-checks can't see (D-018, D-021).
# Malformed elements are first-class outcomes: warned and counted, never
# raised — one bad element must not cost the batch. A payload the parser
# rejects still lands raw; only its structured projection is skipped, and
# that skip is warned only once the raw row's fate is known (D-020, D-021).
class EventIngester
  include StructuredLogging
  self.log_component = "ingester"

  # Real GitHub event ids are ~11-digit numeric strings; 64 chars is
  # generous headroom while still bounding what payload-derived data can
  # reach an indexed column (docs/THREAT-MODEL.md length validation).
  # event_type needs no cap: only the exact string "PushEvent" is persisted.
  # payload size is bounded upstream by the client's 5 MB response cap.
  MAX_EVENT_ID_LENGTH = 64

  # Everything a single row can raise, and the scrub-and-mark answer when
  # the row's own data is at fault, live in JsonScrubber — shared with the
  # enrichment fetcher, which persists the same kind of payload (D-018,
  # D-021).
  ROW_ERRORS = JsonScrubber::ROW_ERRORS

  # Single owner of the counts shape — also the zero for callers whose
  # cycle never reaches ingest (IngestRunner logs it on non-ok polls).
  def self.empty_counts
    { events_seen: 0, push_events_new: 0, duplicates_skipped: 0, malformed_skipped: 0,
      structured_skipped: 0 }
  end

  def initialize(logger: Rails.logger, queuer: EnrichmentQueuer.new)
    @logger = logger
    @queuer = queuer
  end

  # events: the parsed body array from GithubClient::Result#body.
  # => { events_seen:, push_events_new:, duplicates_skipped:, malformed_skipped:,
  #      structured_skipped: }
  def ingest(events)
    unless events.is_a?(Array)
      warn_ingest("ingest.malformed", "body_not_array", detail: events.class.name)
      return self.class.empty_counts
    end

    rows = []
    parse_skips = {}
    malformed = 0
    in_page_repeats = 0
    seen_ids = Set.new
    events.each do |event|
      unless event.is_a?(Hash)
        malformed += 1
        warn_ingest("ingest.malformed", "element_not_object", detail: event.class.name)
        next
      end
      next unless event["type"] == "PushEvent"

      id = event["id"]
      # NUL and invalid bytes are rejected here rather than scrubbed: they
      # can't be stored in the indexed id column and scrubbing an
      # identifier would forge a new one (D-018, D-021).
      unless StorableString.valid?(id, max: MAX_EVENT_ID_LENGTH)
        malformed += 1
        warn_ingest("ingest.malformed", "invalid_event_id",
                    detail: id.to_s.scrub.delete("\u0000").slice(0, MAX_EVENT_ID_LENGTH))
        next
      end
      # The API page itself can repeat an id. Repeats are skipped before
      # the parser runs, so every id is parsed, counted, and warned at most
      # once per ingest — telemetry matches what is persisted (D-021). The
      # repeat still counts as a duplicate below, keeping the partition
      # exact (seen = new + duplicates + non-push + malformed).
      unless seen_ids.add?(id)
        in_page_repeats += 1
        next
      end

      parsed = PushEventParser.call(event)
      parse_skips[id] = parsed.reason if parsed.malformed?
      rows << { github_event_id: id, event_type: event["type"], payload: event,
                structured: parsed.ok? ? parsed.attributes.merge(github_event_id: id) : nil }
    end

    candidates = rows.size + in_page_repeats
    result = insert(rows)
    # structured_skipped is an overlay, not a partition term: a
    # parse-rejected event lands in new or duplicates. It is settled only
    # now, once the raw outcome is known — a row the database refused even
    # after scrubbing counts as malformed alone, so the skip warn's "raw
    # row kept" meaning is true every time it fires (D-021). The ids were
    # validated above, so they are safe to log verbatim.
    skipped = parse_skips.except(*result[:rejected_ids])
    skipped.each do |skipped_id, reason|
      warn_ingest("ingest.structured_skipped", reason, detail: skipped_id)
    end
    enqueue_enrichment(rows, result[:rejected_ids])
    { events_seen: events.size,
      push_events_new: result[:inserted],
      duplicates_skipped: candidates - result[:inserted] - result[:rejected_ids].size,
      malformed_skipped: malformed + result[:rejected_ids].size,
      structured_skipped: skipped.size }
  end

  private

  # Enrichment is additive and strictly best-effort: by the time ingest
  # runs, the client's ETag has advanced past this page, so raising here
  # would report a fully persisted page as a poll failure. A missed enqueue
  # self-heals — the firehose repeats entities and the TTL re-claims them
  # (D-005). Deliberately outside the raw transaction: a stub failure must
  # never cost raw persistence. Only parsed-ok rows whose raw row landed
  # qualify — a rejected row's identity fields were never verified against
  # a persisted event. The counts partition stays untouched; the queuer
  # logs its own events.
  def enqueue_enrichment(rows, rejected_ids)
    eligible = rows.select do |row|
      row[:structured] && !rejected_ids.include?(row[:github_event_id])
    end
    @queuer.call(eligible) if eligible.any?
  rescue StandardError => e
    log_event(:error, "enrich.enqueue_failed", error_class: e.class.name, message: e.message)
  end

  def insert(rows)
    return { inserted: 0, rejected_ids: [] } if rows.empty?

    received_at = Time.current
    stamped = rows.map { |row| row.merge(received_at: received_at) }
    { inserted: insert_batch(stamped), rejected_ids: [] }
  rescue *ROW_ERRORS => e
    insert_each(stamped, batch_error: e)
  end

  # The savepoint (requires_new) keeps a refused statement from aborting any
  # wrapping transaction — without it, the per-row retries below would all
  # die with PG::InFailedSqlTransaction inside the transactional test suite
  # or any future caller-supplied transaction.
  def insert_batch(rows)
    RawEvent.transaction(requires_new: true) do
      inserted = RawEvent.insert_all(
        rows.map { |row| row.except(:structured) },
        unique_by: :github_event_id,
        # On Postgres, returning yields only the rows actually inserted —
        # exact new-vs-duplicate counts from one round trip.
        returning: [ :github_event_id ]
      ).length
      # Structured rows share the raw transaction on purpose: the client's
      # ETag has already advanced past this page, so a crash that landed raw
      # without structured would be a permanently torn event — the feed
      # never re-serves it. All parsed-ok rows are written, not just newly
      # inserted raw ones: DO NOTHING makes every re-ingest self-heal raw
      # rows that predate push_events or arrive via overlapping poll windows.
      structured = rows.filter_map { |row| row[:structured] }
      PushEvent.insert_all(structured, unique_by: :github_event_id) if structured.any?
      inserted
    end
  end

  # A refused row gets one retry: scrubbed only when the failure describes
  # the row's data ("\u0000" or invalid bytes in the payload, unstorable
  # in jsonb — D-018, D-021), unmodified for everything else — see
  # JsonScrubber.data_shaped?. A row that fails both attempts counts as
  # rejected.
  def insert_each(rows, batch_error:)
    inserted = 0
    rejected_ids = []
    rows.each do |row|
      inserted += insert_batch([ row ])
    rescue *ROW_ERRORS => e
      begin
        data_shaped = JsonScrubber.data_shaped?(e)
        inserted += insert_batch([ data_shaped ? scrub(row) : row ])
        warn_ingest("ingest.malformed", "payload_scrubbed", detail: row[:github_event_id]) if data_shaped
      rescue *ROW_ERRORS => retry_error
        rejected_ids << row[:github_event_id]
        warn_ingest("ingest.malformed", "row_rejected",
                    detail: "#{row[:github_event_id]} (#{retry_error.class.name})")
      end
    end

    # Every row refused means the failure was never row-specific (dead DB,
    # deadlock — StatementInvalid covers those too): re-raise the original
    # so the caller's backoff and loud one-shot paths see it.
    raise batch_error if rejected_ids.size == rows.size
    { inserted: inserted, rejected_ids: rejected_ids }
  end

  # The marker key records that this copy is not authentic — the parser
  # refuses to rebuild from it (D-018, D-021).
  def scrub(row)
    row.merge(payload: JsonScrubber.scrub_unstorable(row[:payload]).merge("payload_scrubbed" => true))
  end

  def warn_ingest(event, reason, detail:)
    # Never the payload itself at this level (CLAUDE.md logging rules) —
    # reason + truncated identifying detail is enough to investigate.
    log_event(:warn, event, reason: reason, detail: detail)
  end
end
