# One row per GitHub actor, ever (github_id unique): identity stubbed from
# event payloads at ingest, enrichment data filled in by EnrichActorJob.
class Actor < ApplicationRecord
  include Enrichable
end
