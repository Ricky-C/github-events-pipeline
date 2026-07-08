# Projects one PushEvent hash (string-keyed JSON.parse output) into
# column-ready attributes for push_events, or reports why it can't.
#
# The contract (D-020, D-021): attributes returned as :ok are always
# storable — string caps, encoding validity, bigint ranges, and timestamp
# bounds are verified here, so the structured insert can never be the
# statement that poisons the shared raw+structured transaction in
# EventIngester. Anything unverifiable is rejected, never coerced:
# truncating or repairing a ref, SHA, or login would persist a forged
# identifier (the same reasoning as D-018's event-id rule).
#
# Runs after EventIngester's event-id validation; the id stays the
# ingester's concern and is neither re-checked nor returned here.
class PushEventParser
  # GitHub refuses refs longer than 255 bytes at push time ("GH005: Sorry,
  # refs longer than 255 bytes are not allowed"), so a longer ref cannot
  # reach the feed; counting characters accepts a strict superset of that.
  # Longer is hostile, not truncatable (D-021 corrects D-020's NAME_MAX
  # citation — the bound stands, the guarantor is GitHub's cap).
  MAX_REF_LENGTH = 255
  # GitHub caps owner logins at 39 chars and repository names at 100:
  # 39 + "/" + 100.
  MAX_REPOSITORY_NAME_LENGTH = 140
  # GitHub user logins cap at 39, but integration logins carry suffixes
  # ("github-actions[bot]") — 64 is bounded headroom, the same idiom as
  # EventIngester::MAX_EVENT_ID_LENGTH.
  MAX_LOGIN_LENGTH = 64
  # GitHub hosts SHA-1 repositories only; when SHA-256 repos land this is a
  # one-regex change plus a rebuild from raw (D-004 guarantees the rebuild).
  SHA_PATTERN = /\A\h{40}\z/
  # Exactly the shape GitHub serves: whole seconds, explicit zone. A
  # zone-less string parses in process-local time — an environment-dependent
  # instant — so it is rejected, not assumed UTC (D-021).
  TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})\z/
  # The storability bounds: PG would refuse an id past bigint or a year it
  # can't represent, and a refused statement would take the whole shared
  # transaction down — so out-of-range is malformed here, not a DB error.
  BIGINT_RANGE = (0..(2**63 - 1)).freeze
  YEAR_RANGE = (2000..9999).freeze

  # Same shape as GithubClient::Result: expected outcomes are values, not
  # exceptions. Exactly one of attributes/reason is set.
  Result = Data.define(:status, :attributes, :reason) do
    def initialize(status:, attributes: nil, reason: nil) = super
    def ok? = status == :ok
    def malformed? = status == :malformed
  end

  def self.call(event)
    new(event).call
  end

  def initialize(event)
    @event = event
  end

  def call
    catch(:malformed) do
      malformed!("event_not_object") unless @event.is_a?(Hash)
      # A D-018-scrubbed payload had NUL or invalid bytes repaired in place,
      # so nothing parsed from it can be trusted as authentic — a rebuild
      # from scrubbed raw must not mint structured rows the original ingest
      # refused (D-021). Live ingest always parses the pre-scrub event.
      malformed!("payload_scrubbed") if @event["payload_scrubbed"]
      Result.new(status: :ok, attributes: attributes)
    end
  end

  private

  # Hash-literal evaluation order fixes the validation order, so the first
  # failing field determines the single reported reason.
  def attributes
    payload = object(@event["payload"], "payload_not_object")
    # repo/actor id and name come from the same top-level object so the
    # pair stays mutually consistent (payload.repository_id mirrors repo.id
    # in captured pages, but only repo carries the name).
    repo = object(@event["repo"], "repo_not_object")
    actor = object(@event["actor"], "actor_not_object")
    {
      push_id: id_number(payload["push_id"], "invalid_push_id"),
      ref: bounded_string(payload["ref"], MAX_REF_LENGTH, "invalid_ref"),
      head_sha: sha(payload["head"], "invalid_head_sha"),
      # Absent/null before is a first push to the ref — a legitimate NULL.
      # A present-but-invalid value is still malformed (D-020 null policy).
      before_sha: payload["before"].nil? ? nil : sha(payload["before"], "invalid_before_sha"),
      repository_github_id: id_number(repo["id"], "invalid_repository_id"),
      repository_name: bounded_string(repo["name"], MAX_REPOSITORY_NAME_LENGTH, "invalid_repository_name"),
      actor_github_id: id_number(actor["id"], "invalid_actor_id"),
      actor_login: bounded_string(actor["login"], MAX_LOGIN_LENGTH, "invalid_actor_login"),
      event_created_at: timestamp(@event["created_at"])
    }
  end

  def object(value, reason)
    malformed!(reason) unless value.is_a?(Hash)
    value
  end

  def id_number(value, reason)
    malformed!(reason) unless value.is_a?(Integer) && BIGINT_RANGE.cover?(value)
    value
  end

  # Rejected, never coerced: truncating or repairing an identifying string
  # stores a forged one (D-018). The predicate is shared with
  # EventIngester's id check so the raw and structured layers can't drift.
  def bounded_string(value, max, reason)
    malformed!(reason) unless StorableString.valid?(value, max: max)
    value
  end

  # valid_encoding? must run before the regex: Regexp#match? raises
  # ArgumentError on invalid UTF-8, and an exception here would cost the
  # whole page, not the row (D-021).
  def sha(value, reason)
    malformed!(reason) unless value.is_a?(String) && value.valid_encoding? && SHA_PATTERN.match?(value)
    value
  end

  def timestamp(value)
    unless value.is_a?(String) && value.valid_encoding? && TIMESTAMP_PATTERN.match?(value)
      malformed!("invalid_created_at")
    end
    time = begin
      Time.iso8601(value)
    rescue ArgumentError
      malformed!("invalid_created_at")
    end
    # Time.iso8601 normalizes calendar-invalid values (Feb 30 → Mar 2,
    # 24:00 → next day, :60 → next minute) instead of raising. Only a value
    # that round-trips verbatim is stored as it arrived — anything else is
    # a coercion, and coercions are rejected (D-020, D-021).
    malformed!("invalid_created_at") unless time.iso8601 == value
    malformed!("invalid_created_at") unless YEAR_RANGE.cover?(time.year)
    time
  end

  def malformed!(reason)
    throw :malformed, Result.new(status: :malformed, reason: reason)
  end
end
