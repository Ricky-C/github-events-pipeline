class ApplicationJob < ActiveJob::Base
  # The enrichment claim UPDATE and its job INSERT must commit or roll back
  # together in one transaction on the one database (docs/DECISIONS.md D-023);
  # deferring the enqueue to after-commit would reopen the
  # crashed-between-claim-and-enqueue window. false is the framework default,
  # pinned because the claim's atomicity depends on it — and pinned *here*
  # rather than in config/application.rb because Rails 8.1's Active Job
  # railtie excludes this key from the options it applies to ActiveJob::Base
  # ("This config can't be applied globally"), which made the old
  # application-level pin a no-op: a labeled setting wired to nothing, exactly
  # what D-019 refuses. spec/models/enrichable_concurrency_spec.rb guards it.
  self.enqueue_after_transaction_commit = false
end
