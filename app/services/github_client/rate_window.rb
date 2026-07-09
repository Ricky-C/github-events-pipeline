class GithubClient
  # GitHub's primary rate limit resets on a one-hour window, so no honest
  # `x-ratelimit-reset` or `Retry-After` ever asks for a longer wait. A larger
  # value is a desynced shard or a proxy-rewritten header (D-022 records that
  # the shards do desync), and honoring it is not conservative — it is fatal:
  # a parked enrichment job leaves its record `enqueued`, which is the
  # in-flight dedup, so a wait past the window wedges that entity forever
  # (docs/DECISIONS.md D-024).
  #
  # Every wait computed from a rate header goes through here — the two
  # EnrichmentFetcher park sites and IngestRunner#until_reset — so neither the
  # bound nor the precedence between the two headers can drift between them.
  module RateWindow
    MAX_WAIT = 1.hour.to_i

    module_function

    # The one place a rate header becomes a duration.
    #
    # Retry-After wins whenever it is present: a secondary limit asks for a
    # short wait while the very same response still reports the primary
    # bucket's far-off reset, and sleeping to that reset would park for the
    # wrong reason (spec § HTTP → Result Mapping: "honor retry-after if
    # present").
    #
    # A `reset_at` already in the past says the mirror is stale, not that the
    # window has rolled — so the caller's blind `fallback` is the honest wait.
    # Retrying in a second against an API that has just said stop was never a
    # useful reading of a header we know to be wrong (D-025).
    def wait(retry_after:, reset_at:, now:, fallback:)
      seconds =
        if retry_after
          retry_after
        elsif reset_at && reset_at > now
          (reset_at - now).ceil
        else
          fallback
        end
      clamp(seconds)
    end

    # The floor of 1 is not cosmetic: a `Retry-After: 0` would otherwise
    # become a zero-delay hot loop against an API that has just asked us
    # to stop.
    def clamp(seconds) = seconds.clamp(1, MAX_WAIT)
  end
end
