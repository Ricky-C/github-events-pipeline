# Makes every enrichment decision for one claimed Actor/Repository — budget
# gate, conditional fetch, Result-to-state-machine mapping, persistence —
# and returns a plain Outcome value; EnrichmentJob translates that into
# Active Job mechanics. Split from the job so the policy is unit-testable
# without a queue (CLAUDE.md: jobs stay thin).
class EnrichmentFetcher
  include StructuredLogging
  self.log_component = "worker"

  # Enrichment never spends the window down to zero: polling has priority
  # (D-006) and the persisted mirror can lag a few requests behind reality
  # (a desynced shard was observed live — D-022), so a small reserve keeps
  # the poller from ever being starved by enrichment.
  ENRICHMENT_RESERVE = 5

  # Parking before any reset_at has been observed (rate-limited at boot):
  # a short blind wait beats guessing at the window.
  PARK_FALLBACK = 60

  # De-synchronizes parked jobs from the ingester's own reset wake-up so a
  # fresh window doesn't open with simultaneous requests.
  MAX_PARK_JITTER = 30

  # :done — the record reached a settled state (fetched/not_found/rejected).
  # :parked — budget or rate limit; re-enqueue a fresh job at run_at.
  # :retry — transient fetch failure; raise so retry_on owns the backoff.
  Outcome = Data.define(:action, :run_at, :error) do
    def initialize(action:, run_at: nil, error: nil) = super
  end

  def initialize(client: GithubClient.new, logger: Rails.logger, clock: Time,
                 jitter: -> { rand(0..MAX_PARK_JITTER) })
    @client = client
    @logger = logger
    @clock = clock
    @jitter = jitter
  end

  def call(record)
    budget = @client.budget
    unless budget.spendable?(reserve: ENRICHMENT_RESERVE, at: @clock.now)
      return park(record, reason: "budget", reset_at: budget.reset_at)
    end

    result = @client.fetch_resource(record.url, etag: record.etag)
    case result.status
    when :ok then persist(record, result)
    when :not_modified then revalidate(record)
    when :not_found then terminal(record)
    when :rejected_url then reject(record, result)
    when :rate_limited
      park(record, reason: "rate_limited", retry_after: result.retry_after,
           reset_at: result.reset_at)
    else
      retry_later(record, result)
    end
  end

  private

  def persist(record, result)
    return reject_body(record, result.body) unless result.body.is_a?(Hash)

    update_fetched(record, data: result.body, etag: result.etag)
    log(:info, "enrich.success", record, not_modified: false)
    done
  end

  # /users and /repos answer with JSON objects; a 200 carrying an array or a
  # scalar is not enrichment data. Stored, it would put a bare value under
  # `data`, mark the record `fetched`, and let the 24h TTL hide the anomaly
  # for a day — and it is the one input that reaches the scrub path below as
  # something it cannot mark. Terminal, like any other unusable response.
  # Warn, not error: a data-shape anomaly upstream, not a guard catching an
  # attack — the same register as enrich.scrubbed (D-025).
  def reject_body(record, body)
    record.update!(fetch_status: "rejected")
    log(:warn, "enrich.rejected", record, reason: "non_object_body", body_class: body.class.name)
    done
  end

  # 304: the stored data is still current — touch fetched_at so the TTL
  # window restarts, leave data and etag exactly as they were.
  def revalidate(record)
    update_fetched(record)
    log(:info, "enrich.success", record, not_modified: true)
    done
  end

  # Deleted users/repos are routine in the public firehose: terminal state,
  # never retried, never re-claimable (D-005 lineage; phase plan).
  def terminal(record)
    record.update!(fetch_status: "not_found")
    log(:info, "enrich.terminal", record, reason: "not_found")
    done
  end

  # The client refused the stored URL pre-flight (or a redirect target) —
  # zero requests were made. Terminal, with the security log the threat
  # model requires for every guard refusal.
  def reject(record, result)
    record.update!(fetch_status: "rejected")
    log(:error, "security.url_rejected", record, reason: result.error)
    done
  end

  # The record deliberately stays enqueued while parked: that is the
  # in-flight dedup — later events for the same entity skip enqueueing
  # while this job waits out the window.
  def park(record, reason:, retry_after: nil, reset_at: nil)
    run_at = park_at(retry_after: retry_after, reset_at: reset_at)
    log(:info, "enrich.parked", record, reason: reason, run_at: run_at.iso8601)
    Outcome.new(action: :parked, run_at: run_at)
  end

  # Header precedence, the stale-reset fallback, and the bound that keeps a
  # far-future park from wedging this record at `enqueued` forever all live in
  # RateWindow (D-024, D-025). What is this caller's own is the blind wait it
  # falls back to and the jitter that de-synchronizes it from the poller.
  def park_at(retry_after:, reset_at:)
    now = @clock.now
    now + GithubClient::RateWindow.wait(retry_after: retry_after, reset_at: reset_at,
                                        now: now, fallback: PARK_FALLBACK) + @jitter.call
  end

  def retry_later(record, result)
    log(:warn, "enrich.retry", record, status: result.status, error: result.error)
    Outcome.new(action: :retry, error: "#{result.status} #{result.error}".strip)
  end

  def update_fetched(record, **attrs)
    save = { fetched_at: @clock.now, fetch_status: "fetched", **attrs }
    # Savepoint: a PG refusal must not abort a wrapping transaction —
    # the transactional test suite, or any future caller's (D-018).
    record.class.transaction(requires_new: true) { record.update!(save) }
  rescue *JsonScrubber::ROW_ERRORS => error
    raise unless save[:data] && JsonScrubber.data_shaped?(error)
    # A hostile profile field (NUL, invalid bytes) would otherwise leave the
    # record cycling claim → fail → release forever. Same trade as ingest
    # (D-018): a scrubbed-and-marked copy over no enrichment at all. `persist`
    # refuses every non-object body, so the data here is always a Hash and the
    # marker always lands — an unmarked scrubbed copy would be a forgery.
    scrubbed = JsonScrubber.scrub_unstorable(save[:data]).merge("payload_scrubbed" => true)
    record.class.transaction(requires_new: true) { record.update!(save.merge(data: scrubbed)) }
    log(:warn, "enrich.scrubbed", record, error_class: error.class.name)
  end

  def done = Outcome.new(action: :done)

  def log(level, event, record, **fields)
    log_event(level, event, entity: record.model_name.singular,
                            github_id: record.github_id, **fields)
  end
end
