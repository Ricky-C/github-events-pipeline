require "rails_helper"

# Contract checklist coverage for enrichment fetches: the URL guard
# allow/deny table and the follow-once redirect policy
# (docs/specs/GITHUB-CLIENT.md). Phase 3 consumes this unchanged.
RSpec.describe GithubClient, "#fetch_resource" do
  subject(:client) { described_class.new }

  let(:user_url) { "https://api.github.com/users/octocat" }
  let(:user_body) { '{"login":"octocat","id":583231}' }
  let(:rate_headers) { { "x-ratelimit-remaining" => "41", "x-ratelimit-reset" => "1783600000" } }

  describe "URL guard" do
    it "allows exactly https://api.github.com and performs the request" do
      stub = stub_request(:get, user_url).to_return(status: 200, headers: rate_headers, body: user_body)

      result = client.fetch_resource(user_url)
      expect(result).to be_ok
      expect(result.body).to eq("login" => "octocat", "id" => 583231)
      expect(stub).to have_been_requested
    end

    {
      "http scheme" => "http://api.github.com/users/x",
      "subdomain-suffixed host" => "https://api.github.com.evil.com/users/x",
      "unrelated host" => "https://evil.com/users/x",
      "port override" => "https://api.github.com:8443/users/x",
      "userinfo" => "https://user@api.github.com/users/x",
      "IPv4 literal" => "https://140.82.112.6/users/x",
      "IPv6 literal" => "https://[2606:50c0::1]/users/x",
      "trailing-dot host" => "https://api.github.com./users/x",
      "dot-dot path segment" => "https://api.github.com/users/../../x",
      "unparseable URL" => "https://api.github.com/users/\nx",
      "nil" => nil
    }.each do |label, url|
      it "rejects #{label} with zero HTTP requests" do
        result = client.fetch_resource(url)

        expect(result.status).to eq(:rejected_url)
        expect(result).to be_terminal
        expect(result.error).to be_present
        expect(WebMock).not_to have_requested(:get, /./)
      end
    end
  end

  it "sends If-None-Match when an etag is given and maps 304 to :not_modified" do
    etag = 'W/"resource-etag"'
    stub = stub_request(:get, user_url)
      .with(headers: { "If-None-Match" => etag })
      .to_return(status: 304, headers: rate_headers)

    result = client.fetch_resource(user_url, etag: etag)
    expect(result).to be_not_modified
    expect(stub).to have_been_requested
  end

  it "maps 404 to terminal :not_found and still mirrors rate headers" do
    stub_request(:get, user_url).to_return(GithubApiStubs.not_found_404(remaining: 41))

    result = client.fetch_resource(user_url)
    expect(result.status).to eq(:not_found)
    expect(result).to be_terminal
    expect(RateLimitState.current.remaining).to eq(41)
  end

  it "never clobbers the /events etag or poll_interval from a resource response" do
    RateLimitState.record!(etag: 'W/"events-etag"', poll_interval: 60)
    stub_request(:get, user_url).to_return(status: 200, headers: rate_headers, body: user_body)

    client.fetch_resource(user_url)
    state = RateLimitState.current
    expect(state.etag).to eq('W/"events-etag"')
    expect(state.poll_interval).to eq(60)
    expect(state.remaining).to eq(41)
  end

  describe "redirect policy" do
    let(:renamed_url) { "https://api.github.com/users/octocat-renamed" }

    it "follows a single 301 whose target passes the guard" do
      stub_request(:get, user_url).to_return(GithubApiStubs.redirect_301(to: renamed_url))
      stub_request(:get, renamed_url).to_return(status: 200, headers: rate_headers, body: user_body)

      result = client.fetch_resource(user_url)
      expect(result).to be_ok
      expect(a_request(:get, renamed_url)).to have_been_made
    end

    it "maps a second consecutive 301 to :transient_error" do
      stub_request(:get, user_url).to_return(GithubApiStubs.redirect_301(to: renamed_url))
      stub_request(:get, renamed_url)
        .to_return(GithubApiStubs.redirect_301(to: "https://api.github.com/users/again"))

      result = client.fetch_resource(user_url)
      expect(result).to be_retryable
      expect(result.error).to include("redirect")
      expect(WebMock).not_to have_requested(:get, "https://api.github.com/users/again")
    end

    it "rejects a redirect to a guarded-out target without requesting it" do
      stub_request(:get, user_url).to_return(GithubApiStubs.redirect_301(to: "https://evil.com/users/x"))

      result = client.fetch_resource(user_url)
      expect(result.status).to eq(:rejected_url)
      expect(WebMock).not_to have_requested(:get, "https://evil.com/users/x")
    end

    it "maps a 301 without a Location header to :transient_error" do
      stub_request(:get, user_url).to_return(status: 301)

      result = client.fetch_resource(user_url)
      expect(result).to be_retryable
    end
  end
end
