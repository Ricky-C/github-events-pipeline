# Turns one ingested page into enrichment work: upserts identity stubs for
# every unique actor/repository and enqueues a job for each entity whose
# claim it wins (Enrichable's atomic TTL-gate + in-flight dedup). Runs in
# the ingester process, after raw persistence, best-effort — EventIngester
# never lets a queuer failure cost the page.
class EnrichmentQueuer
  include StructuredLogging
  self.log_component = "ingester"

  # Guard-passed api.github.com URLs are short by construction; anything
  # longer than this is not a URL this pipeline should store or fetch
  # (docs/THREAT-MODEL.md length validation).
  MAX_URL_LENGTH = 255

  # Claim-lost fetch_status → the reason logged for skipping the enqueue.
  # A pending row that cannot be claimed has no url (the guard refused it).
  SKIP_REASONS = { "pending" => "no_url", "enqueued" => "in_flight",
                   "not_found" => "not_found", "rejected" => "rejected" }.freeze

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  # rows: ingester-shaped hashes whose :structured attributes are already
  # parser-validated (ids bounded, login/name length-capped — D-020); only
  # the URLs are read from the raw payload and validated here, because
  # push_events deliberately carries no URL columns.
  def call(rows)
    actors = {}
    repositories = {}
    rows.each do |row|
      structured = row[:structured]
      payload = row[:payload]
      # First occurrence wins within a page: one claim attempt per entity.
      actors[structured[:actor_github_id]] ||= {
        github_id: structured[:actor_github_id],
        login: structured[:actor_login],
        url: payload.dig("actor", "url"),
        avatar_url: payload.dig("actor", "avatar_url")
      }
      repositories[structured[:repository_github_id]] ||= {
        github_id: structured[:repository_github_id],
        full_name: structured[:repository_name],
        url: payload.dig("repo", "url")
      }
    end

    actors.each_value { |attrs| upsert_and_enqueue(EnrichActorJob, attrs) }
    repositories.each_value { |attrs| upsert_and_enqueue(EnrichRepositoryJob, attrs) }
  end

  private

  # The job names the model it enriches (`record_class`), so this method takes
  # the job and derives the rest — one mapping, shared with EnrichmentSweep.
  def upsert_and_enqueue(job_class, attrs)
    model = job_class.record_class
    entity = model.model_name.singular
    attrs[:url] = checked_url(entity, attrs)
    if attrs.key?(:avatar_url) && !StorableString.valid?(attrs[:avatar_url], max: MAX_URL_LENGTH)
      # Persist-only display data (D-007): invalid just means no reference,
      # never a rejected row.
      attrs[:avatar_url] = nil
    end

    id = upsert_stub(model, attrs)
    claimed = model.claim_and_enqueue(github_id: attrs[:github_id], job_class: job_class, record_id: id)

    if claimed
      log(:info, "enrich.enqueued", entity, attrs[:github_id])
    else
      status, fetched_at = model.where(github_id: attrs[:github_id]).pick(:fetch_status, :fetched_at)
      if status == "fetched"
        log(:info, "enrich.cache_hit", entity, attrs[:github_id], fetched_at: fetched_at&.iso8601)
      else
        log(:info, "enrich.skipped", entity, attrs[:github_id], reason: SKIP_REASONS.fetch(status, status))
      end
    end
  end

  # Identity columns only, and only the ones this event actually supplied: a
  # nil means "this event told us nothing", never "erase what we know". The
  # url arrives nil when the guard refused it, avatar_url when it failed
  # StorableString or the payload simply omitted it — neither may overwrite a
  # stored good value (D-024 generalizes what D-023 protected only for url).
  # The enrichment columns (data/etag/fetched_at/fetch_status) are never in
  # the update set, so a stub refresh can't clobber fetch state. Unlike the
  # push_events insert-ignore (D-021), this is a genuine DO UPDATE — logins
  # and repo names change on rename and the latest identity should win.
  # login/full_name are parser-guaranteed present, so the set is never empty.
  def upsert_stub(model, attrs)
    update_only = attrs.compact.keys - [ :github_id ]
    model.upsert(attrs, unique_by: :github_id, update_only: update_only,
                        record_timestamps: true, returning: %i[id]).rows.first.first
  end

  # Payload URLs are untrusted input (D-008): the same guard the client
  # applies pre-flight runs here at ingest, so a refused URL is caught with
  # a security log at the earliest layer and never even persisted.
  #
  # An absent or empty URL is not a refusal — the event simply carried none.
  # Passing it to the guard would security-log every such event as "scheme is
  # not https", drowning the signal that means an attack. The stub upserts
  # with a NULL url, is never claimable, and the existing `enrich.skipped
  # no_url` covers the observability (D-025).
  def checked_url(entity, attrs)
    return nil if attrs[:url].blank?

    status, checked = GithubClient::UrlGuard.check(attrs[:url])
    if status == :ok && StorableString.valid?(checked.to_s, max: MAX_URL_LENGTH)
      return checked.to_s
    end

    reason = status == :ok ? "unstorable_url" : checked
    log(:error, "security.url_rejected", entity, attrs[:github_id], reason: reason,
        detail: JsonScrubber.scrub_unstorable(attrs[:url].to_s).slice(0, 120))
    nil
  end

  def log(level, event, entity, github_id, **fields)
    log_event(level, event, entity: entity, github_id: github_id, **fields)
  end
end
