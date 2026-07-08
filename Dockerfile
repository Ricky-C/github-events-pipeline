# syntax=docker/dockerfile:1
# check=error=true

# Containers run RAILS_ENV=development for zero-secret boot (docs/DECISIONS.md
# D-010); the test compose service overrides to RAILS_ENV=test. All gem groups
# are installed — one image serves ingester, worker, migrate, test, and console.

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.10
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Runtime packages: libpq for pg, jemalloc for memory behavior,
# postgresql-client for console-side psql inspection, git so bundler-audit
# can update its advisory db inside the container (docs/THREAT-MODEL.md § hooks).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y git libjemalloc2 libpq5 postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="development" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage keeps compilers out of the runtime image
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Gems cached in their own layer: only Gemfile changes invalidate it
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

COPY . .

RUN bundle exec bootsnap precompile app/ lib/

# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# No server, no EXPOSE: this service has no inbound surface
# (docs/THREAT-MODEL.md). Compose services supply their own commands.
CMD ["/bin/bash"]
