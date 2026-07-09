# Mechanics-only shell over EnrichmentFetcher (CLAUDE.md: jobs stay thin —
# every decision lives in the service). Subclasses supply record_class.
class EnrichmentJob < ApplicationJob
  include StructuredLogging
  self.log_component = "worker"

  queue_as :enrichment

  # A :transient_error Result surfaces as an exception on purpose: Active
  # Job's retry_on owns the backoff schedule and the attempts cap.
  TransientFetch = Class.new(StandardError)

  retry_on TransientFetch, wait: :polynomially_longer, attempts: 5 do |job, error|
    # Retries exhausted: discard with an error log (phase plan: capped
    # attempts, then discard) and return the record to the claimable pool
    # so a later event for the same entity can try again.
    job.give_up(error)
  end

  def perform(id)
    record = self.class.record_class.find_by(id: id)
    return unless record

    outcome = EnrichmentFetcher.new.call(record)
    case outcome.action
    when :parked
      # A fresh scheduled job, not retry_job: parking is expected budget
      # behavior, not a failure, so it must never consume the
      # transient-retry attempts. The record stays enqueued — that is the
      # in-flight dedup while the job waits out the window.
      self.class.set(wait_until: outcome.run_at).perform_later(id)
    when :retry
      raise TransientFetch, outcome.error
    end
  rescue TransientFetch
    # retry_on owns it; the record stays enqueued between attempts.
    raise
  rescue StandardError
    # An error retry_on doesn't manage would otherwise strand the record in
    # enqueued forever — nothing re-runs a failed execution on its own. This
    # assumes the error was transient: a deterministic one re-runs on the next
    # claim, with no equivalent of the attempts cap above (accepted, D-024).
    # It can only run while this process lives; a hard kill takes the record
    # with it, which is what EnrichmentSweep exists to reconcile.
    self.class.record_class.release_claim(id)
    raise
  end

  def give_up(error)
    id = arguments.first
    self.class.record_class.release_claim(id)
    log_event(:error, "enrich.retry_exhausted", job: self.class.name, record_id: id,
                                                error_class: error.class.name, message: error.message)
  end

  def self.record_class
    raise NotImplementedError, "#{name} must define .record_class"
  end
end
