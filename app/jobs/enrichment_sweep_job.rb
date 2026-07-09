# Mechanics-only shell over EnrichmentSweep (CLAUDE.md: jobs stay thin).
# Scheduled by config/recurring.yml; runs on the enrichment queue so it can
# never overlap an enrichment fetch (worker concurrency is 1).
class EnrichmentSweepJob < ApplicationJob
  queue_as :enrichment

  def perform = EnrichmentSweep.new.call
end
