require_relative "boot"

require "rails"
# Headless ingestion pipeline: no mailer, mailbox, text, storage, or cable.
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

require_relative "../lib/json_log_formatter"

module GithubEventsPipeline
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # json_log_formatter is required explicitly above (needed before the
    # autoloader is ready), so Zeitwerk must not manage it.
    config.autoload_lib(ignore: %w[assets tasks json_log_formatter.rb])

    # `docker compose logs -f` is the operator UI: one JSON object per line
    # to stdout, in every environment and process (ingester, worker, console).
    $stdout.sync = true
    json_formatter = JsonLogFormatter.new
    json_logger = ActiveSupport::Logger.new($stdout)
    json_logger.formatter = json_formatter
    config.logger = json_logger
    config.log_formatter = json_formatter
    config.log_level = :info
    config.colorize_logging = false

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Jobs are Postgres rows in the same database as everything else
    # (docs/DECISIONS.md D-002, D-010). Set explicitly: the development-env
    # default is the in-process async adapter, which would fake-pass
    # enrichment without any worker running. Solid Queue itself uses the
    # primary connection because no `config.solid_queue.connects_to` is set —
    # that absence is deliberate, not an omission.
    config.active_job.queue_adapter = :solid_queue

    # The enrichment claim UPDATE and its job INSERT must commit or roll
    # back together in one transaction on the one database (docs/DECISIONS.md
    # D-023); deferring enqueue to after-commit would reopen the
    # crashed-between-claim-and-enqueue window. false is the 8.1 default —
    # pinned because the claim's atomicity silently depends on it.
    config.active_job.enqueue_after_transaction_commit = false
  end
end
