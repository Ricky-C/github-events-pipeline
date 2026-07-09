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
  # EnrichmentFetcher park sites and IngestRunner#until_reset — so the bound
  # cannot drift between them.
  module RateWindow
    MAX_WAIT = 1.hour.to_i

    module_function

    # The floor of 1 is not cosmetic: a reset already in the past, or a
    # `Retry-After: 0`, would otherwise become a zero-delay hot loop against
    # an API that has just asked us to stop.
    def clamp(seconds) = seconds.clamp(1, MAX_WAIT)
  end
end
