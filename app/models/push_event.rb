# Writes bypass this class (EventIngester uses insert_all inside the shared
# raw+structured transaction); the unique index on github_event_id is the
# real idempotency guarantee, and PushEventParser is the validation layer —
# no model validations by design (D-020).
class PushEvent < ApplicationRecord
end
