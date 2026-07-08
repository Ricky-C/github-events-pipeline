class CreatePushEvents < ActiveRecord::Migration[8.1]
  def change
    # Structured projection of raw_events PushEvent payloads (D-004): real
    # columns for plain-SQL analytics, rebuildable one-way from raw.
    # github_event_id is an FK by convention only — no DB constraint, so raw
    # rows can age out independently and rebuilds need no ordering ceremony;
    # the shared ingest transaction is what keeps the pair honest (D-020).
    # No received_at/timestamps: event_created_at is the analytical time
    # axis; ingest time lives on raw_events (join on github_event_id).
    # String columns carry no DB limit — length caps are enforced once, in
    # PushEventParser, before persistence (docs/THREAT-MODEL.md, D-020),
    # mirroring how EventIngester bounds github_event_id for raw_events.
    create_table :push_events do |t|
      t.string :github_event_id, null: false
      t.bigint :push_id, null: false
      t.string :ref, null: false
      t.string :head_sha, null: false
      # before is NULL for a first push to a ref; a present-but-invalid
      # value is rejected by the parser instead (D-020 null policy).
      t.string :before_sha
      t.bigint :repository_github_id, null: false
      t.string :repository_name, null: false
      t.bigint :actor_github_id, null: false
      t.string :actor_login, null: false
      t.datetime :event_created_at, null: false
    end
    # The unique id is the idempotency guarantee for ON CONFLICT DO NOTHING
    # re-ingest — every write may be a retry (CLAUDE.md conventions).
    add_index :push_events, :github_event_id, unique: true
    add_index :push_events, :push_id
    add_index :push_events, :repository_github_id
    add_index :push_events, :actor_github_id
    # "Pushes over time" is the stated analytical goal (PHASE-2-PLAN).
    add_index :push_events, :event_created_at
  end
end
