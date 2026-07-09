# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Specs assert enqueues via ActiveJob::TestHelper and drive performs
  # explicitly; Solid Queue's tables exist in the test schema but are never
  # touched. Explicit for the same reason the app adapter is (D-010): never
  # trust an env default to pick the queue backend.
  config.active_job.queue_adapter = :test

  # Always eager load: a boot error in any autoloaded file must fail the
  # suite, not the long-running services. Unconditional (not keyed off CI)
  # so ad-hoc rspec runs keep the same guarantee as the compose test service.
  config.eager_load = true

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end
