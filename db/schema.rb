# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_08_000002) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "rate_limit_states", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "etag"
    t.integer "poll_interval"
    t.integer "remaining"
    t.datetime "reset_at"
    t.integer "singleton_guard", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["singleton_guard"], name: "index_rate_limit_states_on_singleton_guard", unique: true
  end

  create_table "raw_events", force: :cascade do |t|
    t.string "event_type", null: false
    t.string "github_event_id", null: false
    t.jsonb "payload", null: false
    t.datetime "received_at", null: false
    t.index ["github_event_id"], name: "index_raw_events_on_github_event_id", unique: true
  end
end
