# Captures structured log hashes for assertions without touching stdout.
class RecordingLogger
  attr_reader :entries

  def initialize
    @entries = []
  end

  %i[ debug info warn error fatal ].each do |severity|
    define_method(severity) { |message| @entries << [ severity, message ] }
  end

  # event: filters structured entries by their :event key — the one log-shape
  # assumption, kept here so every spec filters the same way instead of
  # hand-rolling per-file copies that can drift from the entry shape.
  def messages(severity = nil, event: nil)
    selected = severity ? @entries.select { |sev, _| sev == severity } : @entries
    selected = selected.select { |_, message| message[:event] == event } if event
    selected.map { |_, message| message }
  end
end
