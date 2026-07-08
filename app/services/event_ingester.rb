# Takes one parsed /events page, keeps the PushEvents, and lands them in
# raw_events in a single idempotent statement. Malformed elements are
# first-class outcomes: warned and counted, never raised — one bad element
# must not cost the batch.
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
      unless id.is_a?(String) && !id.empty? && id.length <= MAX_EVENT_ID_LENGTH
        malformed += 1
        warn_malformed("invalid_event_id", detail: id.to_s.slice(0, MAX_EVENT_ID_LENGTH))
        next
      end
      rows << { github_event_id: id, event_type: event["type"], payload: event }
    end

    # The API page itself can repeat an id; PG's DO NOTHING would tolerate
    # it, but deduping first keeps the returned counts honest — an in-page
    # repeat is a duplicate too, so duplicates are measured against the
    # pre-dedupe candidate count (seen = new + duplicates + non-push + malformed).
    candidates = rows.size
    inserted = insert(rows.uniq { |row| row[:github_event_id] })
    counts(events.size, inserted, candidates - inserted, malformed)
  end

  private

  def insert(rows)
    return 0 if rows.empty?

    received_at = Time.current
    result = RawEvent.insert_all(
      rows.map { |row| row.merge(received_at: received_at) },
      unique_by: :github_event_id,
      # On Postgres, returning yields only the rows actually inserted —
      # exact new-vs-duplicate counts from one round trip.
      returning: [ :github_event_id ]
    )
    result.length
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
