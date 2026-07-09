# Owns the cadence policy the client deliberately doesn't (docs/specs/
# GITHUB-CLIENT.md § Caller Contracts): the client reports facts, this loop
# decides how long to wait on each of them. In continuous mode it never
# exits nonzero — a poll loop that crashes overnight ingests nothing.
class IngestRunner
  DEFAULT_POLL_INTERVAL = 60
  # Never poll faster than this, even when X-Poll-Interval asks for it.
  # Conditional polls are not free: measured 304s decrement
  # X-RateLimit-Remaining (D-017, D-022), so honoring the served 60s
  # interval would spend the entire 60/hr budget on polling and starve
  # enrichment. 120s caps polling at ~30 req/hr; a served interval larger
  # than the floor still wins.
  POLL_FLOOR = 120
  BACKOFF_BASE = 5
  BACKOFF_CAP = 300
  # 5 * 2**7 already exceeds the cap; clamping keeps a weeks-long outage
  # from growing 2**@attempt into an ever-larger bignum.
  MAX_BACKOFF_ATTEMPT = 7
  # Jitter keeps a restarted fleet (or ingester + future enrichment worker)
  # from stampeding the API at the same reset instant.
  MAX_JITTER = 10
  # Sleep in short slices so SIGTERM is honored within ~1s of arriving,
  # comfortably inside compose's stop grace period.
  SLEEP_SLICE = 1

  # One-shot mode raises this for any poll that isn't :ok/:not_modified so
  # verification runs exit nonzero (D-016) — Results are values, not
  # exceptions, so a failed poll would otherwise look like success to
  # anything keying on the exit code.
  PollFailed = Class.new(StandardError)

  # traps: false lets specs drive the loop without replacing the test
  # process's own TERM/INT handlers. state: should match the store the
  # client persists to — the runner reads the last poll interval from it.
  def initialize(client: GithubClient.new, ingester: EventIngester.new,
                 sleeper: Kernel.method(:sleep), clock: Time,
                 state: RateLimitState,
                 logger: Rails.logger, jitter: -> { rand(0..MAX_JITTER) },
                 traps: true)
    @client = client
    @ingester = ingester
    @sleeper = sleeper
    @clock = clock
    @state = state
    @logger = logger
    @jitter = jitter
    @traps = traps
    @shutdown = false
    @attempt = 0
  end

  def run(once: false)
    trap_signals if @traps && !once

    loop do
      # One-shot mode lets failures propagate — a verification run should
      # be loud. Continuous mode absorbs everything and backs off instead.
      if once
        _wait, result = cycle
        unless result.ok? || result.not_modified?
          raise PollFailed, "one-shot poll failed: #{result.status} #{result.error}".strip
        end
        break
      end

      begin
        wait, _result = cycle
        interruptible_sleep(wait)
      rescue StandardError => e
        @logger.error(component: "ingester", event: "poll.error",
                      error_class: e.class.name, message: e.message)
        interruptible_sleep(backoff)
      end

      if @shutdown
        @logger.info(component: "ingester", event: "shutdown.clean")
        break
      end
    end
  end

  private

  # Runs one poll, logs the cycle, returns the sleep duration and the result.
  def cycle
    result = @client.poll_events
    counts = result.ok? ? @ingester.ingest(result.body) : EventIngester.empty_counts
    wait = wait_for(result)

    @logger.info({
      component: "ingester", event: "poll.cycle", status: result.status,
      not_modified: result.not_modified?,
      budget_remaining: @client.budget.remaining, sleep_for: wait
    }.merge(counts))

    [ wait, result ]
  end

  def wait_for(result)
    case result.status
    when :ok
      @attempt = 0
      floored(result.poll_interval)
    when :not_modified
      @attempt = 0
      floored(result.poll_interval || @state.current&.poll_interval)
    when :rate_limited
      @attempt = 0
      until_reset(result)
    else
      # :transient_error and anything unexpected: capped exponential backoff.
      backoff
    end
  end

  def floored(interval)
    [ interval || DEFAULT_POLL_INTERVAL, POLL_FLOOR ].max
  end

  def until_reset(result)
    reset_at = result.rate&.fetch(:reset_at, nil)
    # Retry-After wins when present: a secondary/abuse limit asks for a short
    # wait while the same response still carries the primary bucket's far-off
    # reset — sleeping to the reset would park the loop for the wrong reason
    # (spec § HTTP → Result Mapping: "honor retry-after if present").
    base = result.retry_after || (reset_at ? (reset_at - @clock.now).ceil : DEFAULT_POLL_INTERVAL)
    # A reset_at already in the past must not become a zero-sleep hot loop
    # against a limited API — always wait at least a second.
    [ base, 1 ].max + @jitter.call
  end

  def backoff
    wait = [ BACKOFF_BASE * (2**@attempt), BACKOFF_CAP ].min + @jitter.call
    @attempt = [ @attempt + 1, MAX_BACKOFF_ATTEMPT ].min
    wait
  end

  def trap_signals
    # Traps only set a flag — no logging or IO in signal context.
    [ "TERM", "INT" ].each { |signal| Signal.trap(signal) { @shutdown = true } }
  end

  def interruptible_sleep(duration)
    remaining = duration
    while remaining > 0 && !@shutdown
      slice = [ remaining, SLEEP_SLICE ].min
      @sleeper.call(slice)
      remaining -= slice
    end
  end
end
