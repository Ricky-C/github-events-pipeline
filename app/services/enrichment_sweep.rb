# Returns entities that Solid Queue abandoned to the claimable pool.
#
# The claim is the in-flight dedup (D-023): a record sits at `enqueued` only
# while a job exists to move it, because the claim UPDATE and the job INSERT
# commit together. Solid Queue breaks that pairing exactly once — when a worker
# dies without deregistering. Its recovery paths (`Process#prune`,
# `fail_orphaned_executions`, the supervisor reaping a fork that exited badly)
# all *dead-letter* the claimed execution rather than re-dispatch it, so the
# job stops existing while the record stays `enqueued`: unclaimable forever,
# never enriched, silent. Nothing upstream re-runs a failed execution.
#
# This reconciles the two: a record `enqueued` with no live job is released and
# re-claimed. Dead-letter rows are left alone — they are the operator's record
# of what happened (docs/DECISIONS.md D-024).
class EnrichmentSweep
  # Solid Queue owns recovery for the moments after a crash, and an enqueue is
  # visible the instant its claim commits. A record younger than this is
  # in-flight, not stranded.
  GRACE = 1.minute

  ENTITIES = [ [ Actor, EnrichActorJob ], [ Repository, EnrichRepositoryJob ] ].freeze

  def initialize(logger: Rails.logger, clock: Time)
    @logger = logger
    @clock = clock
  end

  def call
    swept = ENTITIES.sum { |model, job_class| sweep(model, job_class) }
    @logger.info(component: "worker", event: "enrich.sweep", swept: swept)
    swept
  end

  private

  def sweep(model, job_class)
    jobs = unfinished_jobs_by_record(job_class)
    return 0 if jobs.nil?

    stranded = model.where(fetch_status: "enqueued")
                    .where(updated_at: ..(@clock.now - GRACE))
                    .reject { |record| jobs.fetch(record.id, []).any? { |job| live?(job) } }

    stranded.count { |record| reclaim(model, job_class, record, jobs.fetch(record.id, [])) }
  end

  # nil means "refuse to sweep this model". A job whose record id cannot be
  # read is a job whose liveness cannot be judged, and the only mistake this
  # sweep can make is judging a live job dead — which enqueues a duplicate on
  # every run, forever. Discarding the unreadable job would do exactly that,
  # silently. The other model is untouched: the two share nothing but a
  # process (D-025).
  def unfinished_jobs_by_record(job_class)
    jobs = {}
    SolidQueue::Job.where(class_name: job_class.name, finished_at: nil)
                   .includes(:failed_execution).each do |job|
      id = record_id(job)
      return log_abort(job) if id.nil?

      (jobs[id] ||= []) << job
    end
    jobs
  end

  def log_abort(job)
    @logger.error(component: "worker", event: "enrich.sweep_aborted",
                  class_name: job.class_name, solid_queue_job_id: job.id)
    nil
  end

  # A job that will still run: not finished, not dead-lettered, and not parked
  # past the rate window. That last clause frees an entity wedged by a
  # far-future park — impossible to create since the wait clamp landed
  # (GithubClient::RateWindow), but a pre-clamp binary could have left one.
  def live?(job)
    job.failed_execution.nil? && !beyond_window?(job)
  end

  def beyond_window?(job)
    job.scheduled_at.present? && job.scheduled_at > @clock.now + GithubClient::RateWindow::MAX_WAIT
  end

  # Release then re-claim, rather than reaching into Solid Queue's own retry:
  # the claim is this application's state machine, and going through it keeps
  # the TTL gate, the NULL-url refusal, and the claim/enqueue transaction
  # exactly as the ingest path applies them. A record whose URL the guard
  # refused releases to `pending` and stays there — there is nothing to fetch.
  def reclaim(model, job_class, record, record_jobs)
    return false if model.release_claim(record.id).zero?

    discard_beyond_window(record_jobs)
    reclaimed = model.transaction do
      model.claim_for_enrichment(record.github_id).tap do |won|
        job_class.perform_later(record.id) if won
      end
    end
    log(record, reason: reason_for(record_jobs), reclaimed: reclaimed)
    true
  end

  def discard_beyond_window(record_jobs)
    record_jobs.select { |job| beyond_window?(job) }.each do |job|
      job.discard
    rescue SolidQueue::Execution::UndiscardableError
      # Claimed between the read and here; whoever is running it wins.
    end
  end

  def reason_for(record_jobs)
    return "no_job" if record_jobs.empty?
    return "dead_lettered" if record_jobs.any? { |job| job.failed_execution }

    "scheduled_beyond_window"
  end

  def record_id(job)
    id = job.arguments&.dig("arguments", 0)
    id if id.is_a?(Integer)
  end

  def log(record, **fields)
    @logger.warn({ component: "worker", event: "enrich.swept",
                   entity: record.model_name.singular, github_id: record.github_id }.merge(fields))
  end
end
