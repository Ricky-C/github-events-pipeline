# Writes bypass this class (EventIngester uses insert_all so a whole poll
# page lands in one statement); the unique index on github_event_id is the
# real idempotency guarantee, not model validations.
class RawEvent < ApplicationRecord
end
