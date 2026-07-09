class GithubClient
  # Snapshot of the persisted budget mirror (docs/specs/GITHUB-CLIENT.md
  # § Budget). All fields nil-able: before the first real response the
  # budget is unknown and callers act optimistically.
  Budget = Struct.new(:remaining, :reset_at, :updated_at) do
    # False only when remaining is known, at or below the reserve, and the
    # window that reading came from has not yet rolled.
    #
    # The reserve check alone would deadlock after exhaustion: nothing
    # refreshes the mirror until some request is made, so a stale
    # "remaining: 0" would park every caller forever (or hot-loop them at a
    # past reset_at). Once the observed window has rolled, spend — the first
    # request refreshes the mirror either way. An unknown budget is spendable
    # for the same reason: boot must not deadlock (D-023, D-025).
    def spendable?(reserve: 0, at: Time.current)
      return true if remaining.nil? || remaining > reserve

      reset_at.present? && reset_at <= at
    end

    def exhausted?
      remaining == 0
    end

    def unknown?
      remaining.nil?
    end
  end
end
