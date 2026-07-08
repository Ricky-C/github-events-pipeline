# Synthesized GitHub responses for the cases that cannot be captured live
# without draining the shared 60/hr budget (docs/DECISIONS.md D-015):
# rate-limit exhaustion, 404s, server errors. Shapes mirror real GitHub
# responses; the happy paths use real captures via GithubFixtures.
module GithubApiStubs
  module_function

  def rate_limited_403(reset_at:)
    {
      status: 403,
      headers: { "x-ratelimit-remaining" => "0", "x-ratelimit-reset" => reset_at.to_i.to_s },
      body: '{"message":"API rate limit exceeded for <ip>.","documentation_url":"https://docs.github.com/rest"}'
    }
  end

  def too_many_requests_429(retry_after: 60)
    {
      status: 429,
      headers: { "retry-after" => retry_after.to_s },
      body: '{"message":"You have exceeded a secondary rate limit."}'
    }
  end

  def not_found_404(remaining: 42, reset_at: Time.now + 1800)
    {
      status: 404,
      headers: { "x-ratelimit-remaining" => remaining.to_s, "x-ratelimit-reset" => reset_at.to_i.to_s },
      body: '{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}'
    }
  end

  def redirect_301(to:)
    { status: 301, headers: { "location" => to }, body: "" }
  end
end
