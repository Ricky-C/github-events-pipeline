# Takes one parsed /events page, keeps the PushEvents, and lands them in
# raw_events in a single idempotent statement, with a savepointed per-row
# fallback when PostgreSQL refuses a row the pre-checks can't see (D-018).
# Malformed elements are first-class outcomes: warned and counted, never
# raised — one bad element must not cost the batch.
class EventIngester
  # Real GitHub event ids are ~11-digit numeric strings; 64 chars is
  # generous headroom while still bounding what payload-derived data can
  # reach an indexed column (docs/THREAT-MODEL.md length validation).
  # event_type needs no cap: only the exact string "PushEvent" is persisted.
  # payload size is bounded upstream by the client's 5 MB response cap.
  MAX_EVENT_ID_LENGTH = 64

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  # events: the parsed body array from GithubClient::Result#body.
  # => { events_seen:, push_events_new:, duplicates_skipped:, malformed_skipped: }
  def ingest(events)
    unless events.is_a?(Array)
      warn_malformed("body_not_array", detail: events.class.name)
      return counts(0, 0, 0, 0)
    end

    rows = []
    malformed = 0
    events.each do |event|
      unless event.is_a?(Hash)
        malformed += 1
        warn_malformed("element_not_object", detail: event.class.name)
        next
      end
      next unless event["type"] == "PushEvent"

      id = event["id"]
      # NUL is rejected here rather than scrubbed: it can't be stored in the
      # indexed id column and scrubbing an identifier would forge a new one.
      unless id.is_a?(String) && !id.empty? && id.length <= MAX_EVENT_ID_LENGTH && !id.include?("\u0000")
        malformed += 1
        warn_malformed("invalid_event_id", detail: id.to_s.delete("\u0000").slice(0, MAX_EVENT_ID_LENGTH))
        next
      end
      rows << { github_event_id: id, event_type: event["type"], payload: event }
    end

    # The API page itself can repeat an id; PG's DO NOTHING would tolerate
    # it, but deduping first keeps the returned counts honest — an in-page
    # repeat is a duplicate too, so duplicates are measured against the
    # pre-dedupe candidate count (seen = new + duplicates + non-push + malformed).
    candidates = rows.size
    result = insert(rows.uniq { |row| row[:github_event_id] })
    # Rows the database refused even after scrubbing count as malformed, so
    # the reconciliation (seen = new + duplicates + non-push + malformed)
    # stays exact.
    counts(events.size, result[:inserted],
           candidates - result[:inserted] - result[:rejected],
           malformed + result[:rejected])
  end

  private

  def insert(rows)
    return { inserted: 0, rejected: 0 } if rows.empty?

    received_at = Time.current
    stamped = rows.map { |row| row.merge(received_at: received_at) }
    { inserted: insert_batch(stamped), rejected: 0 }
  rescue ActiveRecord::StatementInvalid => e
    insert_each(stamped, batch_error: e)
  end

  # The savepoint (requires_new) keeps a refused statement from aborting any
  # wrapping transaction — without it, the per-row retries below would all
  # die with PG::InFailedSqlTransaction inside the transactional test suite
  # or any future caller-supplied transaction.
  def insert_batch(rows)
    RawEvent.transaction(requires_new: true) do
      RawEvent.insert_all(
        rows,
        unique_by: :github_event_id,
        # On Postgres, returning yields only the rows actually inserted —
        # exact new-vs-duplicate counts from one round trip.
        returning: [ :github_event_id ]
      ).length
    end
  end

  # PG can refuse a row the pre-checks can't see — "\u0000" anywhere in the
  # payload is unstorable in jsonb (D-018). Retry row by row; a refused row
  # gets one scrubbed retry, then counts as rejected.
  def insert_each(rows, batch_error:)
    inserted = 0
    rejected = 0
    rows.each do |row|
      inserted += insert_batch([ row ])
    rescue ActiveRecord::StatementInvalid
      begin
        inserted += insert_batch([ scrub(row) ])
        warn_malformed("payload_scrubbed", detail: row[:github_event_id])
      rescue ActiveRecord::StatementInvalid => e
        rejected += 1
        warn_malformed("row_rejected", detail: "#{row[:github_event_id]} (#{e.class.name})")
      end
    end

    # Every row refused means the failure was never row-specific (dead DB,
    # deadlock — StatementInvalid covers those too): re-raise the original
    # so the caller's backoff and loud one-shot paths see it.
    raise batch_error if rejected == rows.size
    { inserted: inserted, rejected: rejected }
  end

  def scrub(row)
    row.merge(payload: scrub_nul(row[:payload]).merge("payload_scrubbed" => true))
  end

  # Strip NUL from every string, hash keys included. Raw fidelity is
  # knowingly traded for durability here — NUL can never round-trip
  # through jsonb, so the verbatim payload was unstorable to begin with.
  def scrub_nul(value)
    case value
    when String then value.delete("\u0000")
    when Hash then value.to_h { |key, val| [ scrub_nul(key), scrub_nul(val) ] }
    when Array then value.map { |element| scrub_nul(element) }
    else value
    end
  end

  def counts(seen, new_rows, duplicates, malformed)
    { events_seen: seen, push_events_new: new_rows,
      duplicates_skipped: duplicates, malformed_skipped: malformed }
  end

  def warn_malformed(reason, detail:)
    # Never the payload itself at this level (CLAUDE.md logging rules) —
    # reason + truncated identifying detail is enough to investigate.
    @logger.warn(component: "ingester", event: "ingest.malformed", reason: reason, detail: detail)
  end
end
