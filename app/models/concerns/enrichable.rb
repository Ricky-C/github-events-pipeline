# The enrichment state machine shared by Actor and Repository:
#
#   pending  → enqueued            (queuer wins the claim)
#   enqueued → fetched             (job: 200 or 304)
#            | not_found           (job: 404 — terminal, never retried)
#            | rejected            (job: SSRF guard refusal, or a 200 whose
#                                   body is not a JSON object — terminal)
#            | pending             (job gives up on transients; re-claimable)
#   fetched  → enqueued            (claim again once the TTL has expired)
#
# Solid Queue has no native enqueue-uniqueness, so in-flight dedup is this
# claim: a single atomic UPDATE that also folds in the TTL gate. Claim and
# job INSERT commit together in one transaction on the one database
# (ApplicationJob pins enqueue_after_transaction_commit = false, the knob
# Rails 8.1 ignores at application level — D-024), so there is no window
# where the status says enqueued but no job exists, or vice versa
# (docs/DECISIONS.md D-023).
module Enrichable
  extend ActiveSupport::Concern

  # Skip re-fetching an entity enriched within this window: the firehose
  # repeats actors heavily, and every duplicate fetch wastes irreplaceable
  # budget (docs/DECISIONS.md D-005). Staleness up to the TTL is accepted.
  ENRICHMENT_TTL = 24.hours

  FETCH_STATUSES = %w[pending enqueued fetched not_found rejected].freeze

  class_methods do
    # True exactly once per claimable window, however many concurrent
    # callers race: the WHERE carries the full precondition, so losing
    # callers match zero rows instead of read-modify-writing a stale state.
    # A NULL url (payload URL refused by the SSRF guard at ingest) is never
    # claimable — there is nothing safe to fetch.
    def claim_for_enrichment(github_id)
      where(github_id: github_id)
        .where.not(url: nil)
        .where(
          "fetch_status = 'pending' OR (fetch_status = 'fetched' AND fetched_at <= ?)",
          ENRICHMENT_TTL.ago
        )
        .update_all(fetch_status: "enqueued", updated_at: Time.current) == 1
    end

    # The claim UPDATE and its job INSERT commit or roll back together: Solid
    # Queue's rows live in the same database, and the enqueue happens inline,
    # so neither half can exist without the other (D-023). Both callers that
    # start enrichment — the ingest queuer and the sweep — go through here, so
    # the pairing cannot drift between them.
    def claim_and_enqueue(github_id:, job_class:, record_id:)
      transaction do
        claim_for_enrichment(github_id).tap { |won| job_class.perform_later(record_id) if won }
      end
    end

    # Give-up path (retry exhaustion, unexpected job error): return the row
    # to the claimable pool. Guarded on enqueued so a racing terminal write
    # (not_found/rejected) is never stomped back to pending.
    def release_claim(id)
      where(id: id, fetch_status: "enqueued")
        .update_all(fetch_status: "pending", updated_at: Time.current)
    end
  end
end
