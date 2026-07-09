# One row per GitHub repository, ever (github_id unique): identity stubbed
# from event payloads at ingest, enrichment data filled in by
# EnrichRepositoryJob.
class Repository < ApplicationRecord
  include Enrichable
end
