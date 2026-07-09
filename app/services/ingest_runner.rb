# Owns the cadence policy the client deliberately doesn't (docs/specs/
# GITHUB-CLIENT.md § Caller Contracts): the client reports facts, this loop
# decides how long to wait on each of them. Continuous mode absorbs and
# backs off on transient failures — a poll loop that crashes overnight
# ingests nothing — but it is not silent forever: a permanent error, or a
# transient streak that outlives MAX_CONSECUTIVE_FAILURES, exits nonzero so
# compose's restart policy can recycle the container (D-026).
class IngestRunner
  include StructuredLogging
  self.log_component = "ingester"

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

  # What may raise out of a cycle is a database error or a bug — never the
  # network, which the client converts to Result values. These are the
  # database-availability shapes; anything else is treated as permanent and
  # escalates immediately. StatementInvalid is here knowingly: a dead DB
  # mid-statement surfaces as it, and its permanent look-alike (a bad
  # migration) recurs identically every cycle, so the consecutive cap below
  # is that case's terminal state (D-026).
  TRANSIENT_ERRORS = [
    ActiveRecord::ConnectionNotEstablished,
    ActiveRecord::ConnectionTimeoutError,
    # Covers ConnectionFailed and QueryCanceled (via QueryAborted),
    # Deadlocked (via TransactionRollbackError), and LockWaitTimeout.
    ActiveRecord::StatementInvalid
  ].freeze
  # ~20 min of capped backoff between first failure and escalation — longer
  # than any routine db restart, short enough that an outage surfaces as a
  # visible container restart instead of an evening of silence.
  MAX_CONSECUTIVE_FAILURES = 10
  # Enough frames on the fatal line to place the raise site without turning
  # it into a wall — a bug that needs the full trace reproduces under
  # one-shot mode, which still raises raw (D-016).
  ESCALATION_BACKTRACE_LINES = 5

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
    @consecutive_failures = 0
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
        # Any completed cycle proves the database answered, whatever the
        # poll's Result said — the escalation counter measures a streak.
        @consecutive_failures = 0
        interruptible_sleep(wait)
      rescue *TRANSIENT_ERRORS => e
        @consecutive_failures += 1
        log_event(:error, "poll.error", error_class: e.class.name, message: e.message,
                                        consecutive: @consecutive_failures)
        # A pending SIGTERM outranks escalation on both arms (D-028): the
        # operator asked for a stop, so the failure is reported at error
        # level and the exit stays the clean one they requested.
        if @consecutive_failures >= MAX_CONSECUTIVE_FAILURES && !@shutdown
          escalate(e, "transient_failures_exhausted", consecutive: @consecutive_failures)
        end
        interruptible_sleep(backoff)
      rescue StandardError => e
        # Not a database-availability shape: retrying re-runs the same bug.
        if @shutdown
          log_event(:error, "poll.error", error_class: e.class.name, message: e.message)
        else
          escalate(e, "permanent_error")
        end
      end

      if @shutdown
        log_event(:info, "shutdown.clean")
        break
      end
    end
  end

  # The single stop seam: the signal traps call it, and specs call it
  # instead of poking the ivar, so a rename cannot silently strand them.
  def request_shutdown
    @shutdown = true
  end

  private

  # Runs one poll, logs the cycle, returns the sleep duration and the result.
  def cycle
    result = @client.poll_events
    counts = result.ok? ? @ingester.ingest(result.body) : EventIngester.empty_counts
    wait = wait_for(result)

    if result.rate_limited?
      # Its own info line, on top of poll.cycle: an exhausted shared budget
      # is the system working as designed, and an operator scanning logs
      # must be able to tell that apart from an error without decoding
      # cycle fields. The README's verify section points at this event.
      log_event(:info, "poll.rate_limited", reset_at: result.reset_at&.iso8601,
                                            retry_after: result.retry_after, sleep_for: wait)
    end

    log_event(:info, "poll.cycle", status: result.status, not_modified: result.not_modified?,
                                   budget_remaining: @client.budget.remaining, sleep_for: wait,
                                   **counts)

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

  # Header precedence and the rate-window bound belong to the client, and the
  # enrichment parks read them from the same place (D-024, D-025). This loop
  # supplies only its own blind fallback and its jitter.
  def until_reset(result)
    GithubClient::RateWindow.wait(retry_after: result.retry_after, reset_at: result.reset_at,
                                  now: @clock.now, fallback: DEFAULT_POLL_INTERVAL) + @jitter.call
  end

  def backoff
    wait = [ BACKOFF_BASE * (2**@attempt), BACKOFF_CAP ].min + @jitter.call
    @attempt = [ @attempt + 1, MAX_BACKOFF_ATTEMPT ].min
    wait
  end

  # Exiting nonzero is the escalation channel: compose's restart policy
  # recycles the container, which is the replacement for the Phase 0
  # boot-time SELECT 1 this loop's catch-all absorbed (D-026). The fatal
  # line is the last thing this process says — `exit`, not `raise`, keeps
  # rails runner's backtrace dump from breaking the one-JSON-object-per-line
  # contract, so the line itself carries the trimmed backtrace an operator
  # needs (D-028). `consecutive` arrives via fields only when the reason is
  # a streak — a permanent error is not a tally.
  def escalate(error, reason, **fields)
    log_event(:fatal, "poll.escalated", reason: reason,
                                        error_class: error.class.name, message: error.message,
                                        backtrace: error.backtrace&.first(ESCALATION_BACKTRACE_LINES),
                                        **fields)
    exit 1
  end

  def trap_signals
    # Traps only set a flag — no logging or IO in signal context.
    [ "TERM", "INT" ].each { |signal| Signal.trap(signal) { request_shutdown } }
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
