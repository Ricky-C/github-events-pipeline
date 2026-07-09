# Turns one ingested page into enrichment work: upserts identity stubs for
# every unique actor/repository and enqueues a job for each entity whose
# claim it wins (Enrichable's atomic TTL-gate + in-flight dedup). Runs in
# the ingester process, after raw persistence, best-effort — EventIngester
# never lets a queuer failure cost the page.
class EnrichmentQueuer
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

    actors.each_value { |attrs| upsert_and_enqueue(Actor, EnrichActorJob, attrs) }
    repositories.each_value { |attrs| upsert_and_enqueue(Repository, EnrichRepositoryJob, attrs) }
  end

  private

  def upsert_and_enqueue(model, job_class, attrs)
    entity = model.model_name.singular
    attrs[:url] = checked_url(entity, attrs)
    if attrs.key?(:avatar_url) && !StorableString.valid?(attrs[:avatar_url], max: MAX_URL_LENGTH)
      # Persist-only display data (D-007): invalid just means no reference,
      # never a rejected row.
      attrs[:avatar_url] = nil
    end

    id = upsert_stub(model, attrs)

    # Claim UPDATE and job INSERT commit or roll back together — Solid
    # Queue rows live in the same database, and enqueue happens inline
    # (enqueue_after_transaction_commit = false). See D-023.
    claimed = model.transaction do
      model.claim_for_enrichment(attrs[:github_id]).tap do |won|
        job_class.perform_later(id) if won
      end
    end

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

  # Identity columns only, and url only when the guard passed it: a hostile
  # event must never null out or replace a previously stored good URL, and
  # the enrichment columns (data/etag/fetched_at/fetch_status) are never in
  # the update set, so a stub refresh can't clobber fetch state. Unlike the
  # push_events insert-ignore (D-021), this is a genuine DO UPDATE — logins
  # and repo names change on rename and the latest identity should win.
  def upsert_stub(model, attrs)
    update_only = attrs.keys - [ :github_id ] - (attrs[:url] ? [] : [ :url ])
    model.upsert(attrs, unique_by: :github_id, update_only: update_only,
                        record_timestamps: true, returning: %i[id]).rows.first.first
  end

  # Payload URLs are untrusted input (D-008): the same guard the client
  # applies pre-flight runs here at ingest, so a refused URL is caught with
  # a security log at the earliest layer and never even persisted.
  def checked_url(entity, attrs)
    status, checked = GithubClient::UrlGuard.check(normalize_brackets(attrs[:url]))
    if status == :ok && StorableString.valid?(checked.to_s, max: MAX_URL_LENGTH)
      return checked.to_s
    end

    reason = status == :ok ? "unstorable_url" : checked
    log(:error, "security.url_rejected", entity, attrs[:github_id], reason: reason,
        detail: JsonScrubber.scrub_unstorable(attrs[:url].to_s).slice(0, 120))
    nil
  end

  # GitHub serves bot actor URLs with raw square brackets
  # (.../users/github-actions[bot]) — RFC 3986 forbids them, so URI.parse
  # (and therefore the guard) rejects the URL as served. Percent-encode
  # exactly those two characters: the escaped form names the same resource
  # and GitHub accepts it, while brackets can't smuggle authority tricks —
  # encoded in host position they simply fail the exact-host match. Bots
  # dominate the firehose (D-005); rejecting them would exclude the most
  # common actors from enrichment (D-023).
  def normalize_brackets(url)
    url.to_s.gsub("[", "%5B").gsub("]", "%5D")
  end

  def log(level, event, entity, github_id, **fields)
    @logger.public_send(level, { component: "ingester", event: event,
                                 entity: entity, github_id: github_id }.merge(fields))
  end
end
