require "active_support/core_ext/integer/time"

# Containers run RAILS_ENV=development for zero-secret boot (docs/DECISIONS.md
# D-010). Development defaults assume an interactive laptop session; this is a
# long-running unattended service, so anything that differs is set explicitly
# here rather than inherited.
Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Long-running processes, not an edit-reload loop: load everything at boot.
  config.enable_reloading = false
  config.eager_load = true

  # Show full error reports.
  config.consider_all_requests_local = true

  # Change to :null_store to avoid any caching.
  config.cache_store = :memory_store

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Dev-mode SQL log decoration is noise in structured JSON logs (D-010);
  # SQL itself logs at debug and is already below the info threshold.
  config.active_record.verbose_query_logs = false
  config.active_record.query_log_tags_enabled = false
  config.active_job.verbose_enqueue_logs = false

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end
