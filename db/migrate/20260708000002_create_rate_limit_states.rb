class CreateRateLimitStates < ActiveRecord::Migration[8.1]
  def change
    # One logical row, enforced by the database: singleton_guard is always 0
    # and uniquely indexed, so every writer converges on the same row via a
    # single-statement upsert — retry-safe and race-tolerant with no
    # read-modify-write (docs/DECISIONS.md D-014, spec § Rate-State Bookkeeping).
    create_table :rate_limit_states do |t|
      t.integer :singleton_guard, null: false, default: 0
      t.string :etag
      t.integer :poll_interval
      t.integer :remaining
      t.datetime :reset_at
      t.timestamps
    end
    add_index :rate_limit_states, :singleton_guard, unique: true
  end
end
