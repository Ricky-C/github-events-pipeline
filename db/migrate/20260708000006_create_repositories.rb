# Enrichment target for event repositories — same shape and rationale as
# actors (see 20260708000005_create_actors.rb) minus avatar_url.
class CreateRepositories < ActiveRecord::Migration[8.1]
  def change
    create_table :repositories do |t|
      t.bigint :github_id, null: false
      t.string :full_name, null: false
      t.string :url
      t.jsonb :data
      t.string :etag
      t.datetime :fetched_at
      t.string :fetch_status, null: false, default: "pending"
      t.timestamps
    end
    add_index :repositories, :github_id, unique: true
  end
end
