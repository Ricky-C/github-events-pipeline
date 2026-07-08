# The persisted mirror of GitHub's rate headers plus the /events ETag —
# one logical row shared by the ingester and (from Phase 3) the worker.
# Headers are the source of truth; this copy is best-effort and
# self-corrects on every real response (docs/specs/GITHUB-CLIENT.md).
class RateLimitState < ApplicationRecord
  SINGLETON_GUARD = 0

  # nil until the first real response has been observed (boot state).
  def self.current
    find_by(singleton_guard: SINGLETON_GUARD)
  end

  # Single-statement partial upsert of only the observed columns: a resource
  # fetch updating remaining/reset_at can never clobber the /events
  # etag/poll_interval, and concurrent writers are last-write-wins by design
  # (docs/DECISIONS.md D-014).
  def self.record!(attrs)
    upsert({ singleton_guard: SINGLETON_GUARD, **attrs }, unique_by: :singleton_guard)
  end
end
