class GithubClient
  # Snapshot of the persisted budget mirror (docs/specs/GITHUB-CLIENT.md
  # § Budget). All fields nil-able: before the first real response the
  # budget is unknown and callers act optimistically.
  Budget = Struct.new(:remaining, :reset_at, :updated_at) do
    # false only when remaining is known and at/below the reserve — an
    # unknown budget is spendable so boot doesn't deadlock.
    def spendable?(reserve: 0)
      remaining.nil? || remaining > reserve
    end

    def exhausted?
      remaining == 0
    end

    def unknown?
      remaining.nil?
    end
  end
end
