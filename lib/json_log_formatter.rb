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
  def call(severity, time, _progname, message)
    entry = { ts: time.utc.iso8601(3), level: severity.downcase }

    case message
    when Hash
      entry.merge!(message)
    else
      entry[:msg] = message.to_s
    end

    "#{JSON.generate(entry)}\n"
  end
end
