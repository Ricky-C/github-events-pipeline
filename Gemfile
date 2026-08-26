source "https://rubygems.org"

# Single source of truth for the Ruby version: CI reads .ruby-version via
# setup-ruby, the Dockerfile ARG must match, and this pin makes bundler fail
# the image build if they ever drift.
ruby file: ".ruby-version"

gem "rails", "~> 8.1.3"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"

# Postgres-backed Active Job adapter — job durability = database durability,
# one system of record (docs/DECISIONS.md D-002, D-010)
gem "solid_queue", "~> 1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  gem "rspec-rails"
end

group :test do
  # Blocks all real HTTP in the suite; specs run against captured fixtures only
  gem "webmock"
end
