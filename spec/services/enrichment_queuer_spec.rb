require "rails_helper"

RSpec.describe EnrichmentQueuer do
  include ActiveJob::TestHelper

  subject(:queuer) { described_class.new(logger: logger) }

  let(:logger) { RecordingLogger.new }
  let(:first_actor) { GithubFixtures.first_push["actor"] }
  let(:first_repo) { GithubFixtures.first_push["repo"] }

  # Ingester-shaped rows, built through the real parser so the structured
  # attributes are exactly what production hands the queuer.
  def rows_for(events)
    events.filter_map do |event|
      parsed = PushEventParser.call(event)
      next unless parsed.ok?
      { github_event_id: event["id"], event_type: "PushEvent", payload: event,
        structured: parsed.attributes.merge(github_event_id: event["id"]) }
    end
  end

  def enqueued_classes
    enqueued_jobs.map { |job| job["job_class"] }
  end

  describe "a full captured page" do
    let(:page_rows) { rows_for(GithubFixtures.push_events) }

    it "creates one stub per unique entity and enqueues one job each" do
      unique_actors = page_rows.map { |row| row[:structured][:actor_github_id] }.uniq
      unique_repos = page_rows.map { |row| row[:structured][:repository_github_id] }.uniq
      # The captured page repeats actors — this exercises in-page dedup.
      expect(unique_actors.size).to be < page_rows.size

      queuer.call(page_rows)

      expect(Actor.count).to eq(unique_actors.size)
      expect(Repository.count).to eq(unique_repos.size)
      expect(Actor.distinct.pluck(:fetch_status)).to eq([ "enqueued" ])
      expect(enqueued_classes.count("EnrichActorJob")).to eq(unique_actors.size)
      expect(enqueued_classes.count("EnrichRepositoryJob")).to eq(unique_repos.size)
      expect(logger.messages(:info, event: "enrich.enqueued").size).to eq(unique_actors.size + unique_repos.size)
    end
  end

  describe "identity stubbing" do
    it "persists login, guard-passed url, and avatar_url from the payload" do
      queuer.call(rows_for([ GithubFixtures.first_push ]))

      actor = Actor.find_by!(github_id: first_actor["id"])
      expect(actor.login).to eq(first_actor["login"])
      expect(actor.url).to eq(first_actor["url"])
      expect(actor.avatar_url).to eq(first_actor["avatar_url"])

      repository = Repository.find_by!(github_id: first_repo["id"])
      expect(repository.full_name).to eq(first_repo["name"])
      expect(repository.url).to eq(first_repo["url"])
    end

    it "escapes the raw square brackets GitHub serves in bot actor URLs" do
      bot_event = GithubFixtures.push_events.find { |event| event["actor"]["login"].end_with?("[bot]") }

      queuer.call(rows_for([ bot_event ]))

      actor = Actor.find_by!(github_id: bot_event["actor"]["id"])
      # As served, the URL is RFC-3986-invalid and the guard would reject
      # it — the escaped form names the same resource and passes.
      expect(actor.url).to eq("https://api.github.com/users/github-actions%5Bbot%5D")
      expect(actor.fetch_status).to eq("enqueued")
    end

    it "stores nil for an unstorable avatar_url without rejecting the row" do
      event = GithubFixtures.first_push.deep_dup
      event["actor"]["avatar_url"] = "https://avatars.githubusercontent.com/#{"a" * 300}"

      queuer.call(rows_for([ event ]))

      actor = Actor.find_by!(github_id: first_actor["id"])
      expect(actor.avatar_url).to be_nil
      expect(actor.fetch_status).to eq("enqueued")
    end

    # The escape is a whole-URL gsub, so it must be a fixed point: a payload
    # already carrying the encoded form has to survive it unchanged, or the
    # firehose's most common actors would double-encode to %255B and 404.
    it "leaves an already-escaped bot URL untouched" do
      event = GithubFixtures.first_push.deep_dup
      event["actor"]["url"] = "https://api.github.com/users/dependabot%5Bbot%5D"

      queuer.call(rows_for([ event ]))

      actor = Actor.find_by!(github_id: first_actor["id"])
      expect(actor.url).to eq("https://api.github.com/users/dependabot%5Bbot%5D")
      expect(actor.fetch_status).to eq("enqueued")
    end
  end

  # The escape runs before the guard, on the whole URL. Escaping cannot build
  # an authority: `[` and `]` are legal only inside an IPv6 literal, and the
  # escaped form has no brackets at all, so the host can only be a reg-name or
  # an IPv4 address — never `api.github.com` unless it already was (D-023).
  describe "the bracket escape cannot smuggle an authority" do
    def actor_url_event(url)
      event = GithubFixtures.first_push.deep_dup
      event["actor"]["url"] = url
      event
    end

    [
      [ "an IPv6 loopback literal", "https://[::1]/latest/meta-data" ],
      [ "an IPv4-mapped IPv6 literal", "https://[::ffff:169.254.169.254]/latest/meta-data" ],
      [ "a bracket-wrapped real host", "https://[api.github.com]/users/x" ],
      [ "a bracketed userinfo trick", "https://api.github.com]@evil.com/users/x" ]
    ].each do |description, url|
      it "rejects #{description}" do
        queuer.call(rows_for([ actor_url_event(url) ]))

        actor = Actor.find_by!(github_id: first_actor["id"])
        expect(actor.url).to be_nil
        expect(actor.fetch_status).to eq("pending")
        expect(logger.messages(:error, event: "security.url_rejected").first).to include(entity: "actor")
        expect(enqueued_classes).not_to include("EnrichActorJob")
        expect(WebMock).not_to have_requested(:get, /./)
      end
    end
  end

  # An event that carries no URL told us nothing; it did not attack us. The
  # entity persists as `pending` with a NULL url — unclaimable, and healed by
  # any later event that does carry one — while `security.url_rejected` stays
  # a signal that means what it says (D-025).
  describe "an event supplying no actor URL" do
    def actor_url_event(url)
      event = GithubFixtures.first_push.deep_dup
      url.nil? ? event["actor"].delete("url") : event["actor"]["url"] = url
      event
    end

    { "omits the url key" => nil, "supplies an empty url" => "" }.each do |description, url|
      it "persists a pending, url-less stub and raises no security alarm when the event #{description}" do
        queuer.call(rows_for([ actor_url_event(url) ]))

        actor = Actor.find_by!(github_id: first_actor["id"])
        expect(actor.url).to be_nil
        expect(actor.fetch_status).to eq("pending")
        expect(logger.messages(:error, event: "security.url_rejected")).to be_empty
        expect(logger.messages(:info, event: "enrich.skipped").first).to include(entity: "actor", reason: "no_url")
        expect(enqueued_classes).not_to include("EnrichActorJob")
      end
    end
  end

  describe "TTL gate" do
    it "skips a freshly fetched entity and logs the cache hit" do
      Actor.create!(github_id: first_actor["id"], login: first_actor["login"],
                    url: first_actor["url"], fetch_status: "fetched", fetched_at: 1.hour.ago)

      queuer.call(rows_for([ GithubFixtures.first_push ]))

      expect(enqueued_classes).not_to include("EnrichActorJob")
      expect(enqueued_classes).to include("EnrichRepositoryJob")
      expect(logger.messages(:info, event: "enrich.cache_hit").first)
        .to include(entity: "actor", github_id: first_actor["id"])
    end

    it "re-claims and enqueues once the TTL has expired" do
      actor = Actor.create!(github_id: first_actor["id"], login: first_actor["login"],
                            url: first_actor["url"], fetch_status: "fetched",
                            fetched_at: 25.hours.ago)

      queuer.call(rows_for([ GithubFixtures.first_push ]))

      expect(actor.reload.fetch_status).to eq("enqueued")
      expect(enqueued_classes).to include("EnrichActorJob")
    end
  end

  describe "in-flight and terminal skips" do
    it "skips an in-flight entity" do
      Actor.create!(github_id: first_actor["id"], login: "octo", url: first_actor["url"],
                    fetch_status: "enqueued")

      queuer.call(rows_for([ GithubFixtures.first_push ]))

      expect(enqueued_classes).not_to include("EnrichActorJob")
      expect(logger.messages(:info, event: "enrich.skipped").first).to include(reason: "in_flight")
    end

    it "never enqueues a terminal entity" do
      Actor.create!(github_id: first_actor["id"], login: "octo", url: first_actor["url"],
                    fetch_status: "not_found")

      queuer.call(rows_for([ GithubFixtures.first_push ]))

      expect(enqueued_classes).not_to include("EnrichActorJob")
      expect(logger.messages(:info, event: "enrich.skipped").first).to include(reason: "not_found")
    end
  end

  describe "stub refresh semantics" do
    # A nil identity value means "this event told us nothing", never "erase
    # what we know" — the protection D-023 gave url, generalized (D-024).
    it "keeps a stored avatar_url when a later event omits it" do
      Actor.create!(github_id: first_actor["id"], login: first_actor["login"],
                    url: first_actor["url"], avatar_url: "https://avatars.githubusercontent.com/u/1?v=4")
      event = GithubFixtures.first_push.deep_dup
      event["actor"].delete("avatar_url")

      queuer.call(rows_for([ event ]))

      expect(Actor.find_by!(github_id: first_actor["id"]).avatar_url)
        .to eq("https://avatars.githubusercontent.com/u/1?v=4")
    end

    it "keeps a stored avatar_url when a later event carries an unstorable one" do
      Actor.create!(github_id: first_actor["id"], login: first_actor["login"],
                    url: first_actor["url"], avatar_url: "https://avatars.githubusercontent.com/u/1?v=4")
      event = GithubFixtures.first_push.deep_dup
      event["actor"]["avatar_url"] = "https://avatars.githubusercontent.com/#{"a" * 300}"

      queuer.call(rows_for([ event ]))

      expect(Actor.find_by!(github_id: first_actor["id"]).avatar_url)
        .to eq("https://avatars.githubusercontent.com/u/1?v=4")
    end

    it "updates identity columns and never touches enrichment state" do
      existing = Actor.create!(github_id: first_actor["id"], login: "pre-rename",
                               url: "https://api.github.com/users/pre-rename",
                               fetch_status: "fetched", fetched_at: 1.hour.ago,
                               data: { "kept" => true }, etag: 'W/"kept"')

      queuer.call(rows_for([ GithubFixtures.first_push ]))

      existing.reload
      expect(existing.login).to eq(first_actor["login"])
      expect(existing.url).to eq(first_actor["url"])
      expect(existing.data).to eq("kept" => true)
      expect(existing.etag).to eq('W/"kept"')
      expect(existing.fetch_status).to eq("fetched")
    end
  end

  describe "hostile actor URL (SSRF guard at ingest)" do
    let(:hostile_page) do
      JSON.parse(Rails.root.join("spec/fixtures/github/events_page_with_hostile_url.json").read)
    end

    it "stores no url, enqueues no job, makes no request, and security-logs" do
      queuer.call(rows_for(hostile_page))

      actor = Actor.find_by!(github_id: hostile_page.first["actor"]["id"])
      expect(actor.url).to be_nil
      # Unclaimable without a url — parked as pending, not terminal: a later
      # event carrying a good URL may still enrich this entity.
      expect(actor.fetch_status).to eq("pending")
      expect(enqueued_classes).not_to include("EnrichActorJob")
      expect(enqueued_classes).to include("EnrichRepositoryJob")
      rejection = logger.messages(:error, event: "security.url_rejected").first
      expect(rejection).to include(entity: "actor", github_id: actor.github_id)
      expect(rejection[:detail]).to include("169.254.169.254")
      expect(logger.messages(:info, event: "enrich.skipped").first).to include(reason: "no_url")
      expect(WebMock).not_to have_requested(:get, /./)
    end

    it "never overwrites a previously stored good url" do
      good_url = "https://api.github.com/users/kamkade"
      actor = Actor.create!(github_id: hostile_page.first["actor"]["id"], login: "kamkade",
                            url: good_url, fetch_status: "fetched", fetched_at: 1.hour.ago)

      queuer.call(rows_for(hostile_page))

      expect(actor.reload.url).to eq(good_url)
    end
  end
end
