require "json"
require "logger"
require "time"

# One JSON object per line to stdout. Hash messages are merged into the
# entry so services can log structured events directly:
#
#   Rails.logger.info(component: "ingester", event: "poll.cycle", events_seen: 30)
#
# String messages become {"msg": "..."} — JSON encoding neutralizes
# newline/control-character log injection from external strings
# (docs/THREAT-MODEL.md threat 2).
class JsonLogFormatter < ::Logger::Formatter
  # Logger severities are a fixed set; the frozen map spares a per-line downcase.
  LEVELS = ::Logger::SEV_LABEL.to_h { |label| [ label, label.downcase ] }.freeze

  def call(severity, time, _progname, message)
    # Reserved keys are declared first (so they lead the line) and win every
    # merge conflict below — a hash message carrying payload-derived ts/level
    # keys must not be able to forge the entry's severity or timestamp.
    entry = { ts: time.utc.iso8601(3), level: LEVELS.fetch(severity) { severity.downcase } }

    case message
    when Hash
      entry.merge!(sanitize_hash(message)) { |_key, reserved, _forged| reserved }
    else
      # msg2str keeps exception class + backtrace when an Exception is logged.
      entry[:msg] = utf8(msg2str(message))
    end

    JSON.generate(entry) << "\n"
  end

  private

  # Keys are symbolized so a string "level"/"ts" key can't slip past the
  # symbol-keyed reserved fields as a duplicate JSON key.
  def sanitize_hash(hash)
    hash.to_h { |key, value| [ utf8(key.to_s).to_sym, sanitize(value) ] }
  end

  def sanitize(value)
    case value
    when String then utf8(value)
    when Hash then sanitize_hash(value)
    when Array then value.map { |element| sanitize(element) }
    else value
    end
  end

  # JSON.generate raises on bytes that aren't valid UTF-8; external strings
  # (repo names, payload fragments) must never be able to crash the logging
  # path, so bad bytes are replaced instead.
  def utf8(string)
    if string.encoding == Encoding::UTF_8
      string.valid_encoding? ? string : string.scrub
    else
      string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end
  rescue EncodingError
    string.dup.force_encoding(Encoding::UTF_8).scrub
  end
end
