require "rails_helper"

# The mechanics live in EnrichmentJob and are covered by the actor job spec;
# this pins the repository wiring end to end against the captured fixture.
RSpec.describe EnrichRepositoryJob do
  it "enriches a repository record" do
    repo_url = "https://api.github.com/repos/octocat/Hello-World"
    repository = Repository.create!(github_id: 1296269, full_name: "octocat/Hello-World",
                                    url: repo_url, fetch_status: "enqueued")
    stub_request(:get, repo_url).to_return(GithubFixtures.response(:repo_200))

    described_class.perform_now(repository.id)

    repository.reload
    expect(repository.fetch_status).to eq("fetched")
    expect(repository.data).to eq(GithubFixtures.json_body(:repo_200))
    expect(repository.etag).to eq(GithubFixtures.header(:repo_200, "etag"))
  end
end
