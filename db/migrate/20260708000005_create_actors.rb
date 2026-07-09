# Enrichment target for event actors. Identity columns (login, url,
# avatar_url) are stubbed from the event payload at ingest; data/etag/
# fetched_at/fetch_status belong to the enrichment fetch. Strings carry no
# DB limit: the parser and queuer are the single validation layer, matching
# how push_events bounds its fields in code (docs/DECISIONS.md D-020).
class CreateActors < ActiveRecord::Migration[8.1]
  def change
    create_table :actors do |t|
      t.bigint :github_id, null: false
      t.string :login, null: false
      # Nullable: a payload URL that fails the SSRF guard is never stored,
      # and a NULL url makes the row permanently unclaimable for fetching.
      t.string :url
      # Persist-only reference (docs/DECISIONS.md D-007) — never fetched.
      t.string :avatar_url
      t.jsonb :data
      t.string :etag
      t.datetime :fetched_at
      t.string :fetch_status, null: false, default: "pending"
      t.timestamps
    end
    # Externally-sourced id: unique index so every write can be an upsert
    # and a retried ingest can never mint a second row for one entity.
    add_index :actors, :github_id, unique: true
  end
end
