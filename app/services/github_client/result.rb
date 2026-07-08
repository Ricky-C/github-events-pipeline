class GithubClient
  # Immutable outcome of one client call — expected outcomes (304s, 404s,
  # rate limiting) are values, not exceptions (docs/specs/GITHUB-CLIENT.md).
  # Exactly one status per call; the caller makes all policy.
  Result = Data.define(:status, :body, :etag, :poll_interval, :rate, :retry_after, :error) do
    def initialize(status:, body: nil, etag: nil, poll_interval: nil, rate: nil, retry_after: nil, error: nil)
      super
    end

    def ok? = status == :ok
    def not_modified? = status == :not_modified
    def rate_limited? = status == :rate_limited
    def terminal? = status == :not_found || status == :rejected_url
    def retryable? = status == :transient_error
  end
end
