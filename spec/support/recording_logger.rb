# Captures structured log hashes for assertions without touching stdout.
class RecordingLogger
  attr_reader :entries

  def initialize
    @entries = []
  end

  %i[ debug info warn error fatal ].each do |severity|
    define_method(severity) { |message| @entries << [ severity, message ] }
  end

  def messages(severity = nil)
    selected = severity ? @entries.select { |sev, _| sev == severity } : @entries
    selected.map { |_, message| message }
  end
end
