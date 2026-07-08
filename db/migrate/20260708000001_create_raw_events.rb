class CreateRawEvents < ActiveRecord::Migration[8.1]
  def change
    # Append-only facts: received_at is the meaningful timestamp, so no
    # created_at/updated_at pair. Writes are insert_all with ON CONFLICT
    # DO NOTHING against the unique github_event_id index — every ingest
    # may be a retry (CLAUDE.md conventions).
    create_table :raw_events do |t|
      t.string :github_event_id, null: false
      t.string :event_type, null: false
      t.jsonb :payload, null: false
      t.datetime :received_at, null: false
    end
    add_index :raw_events, :github_event_id, unique: true
  end
end
