require "rails_helper"

RSpec.describe StructuredLogging do
  let(:klass) do
    Class.new do
      include StructuredLogging
      self.log_component = "tester"

      def initialize(logger: nil)
        @logger = logger
      end

      def say(**fields) = log_event(:info, "test.event", **fields)
    end
  end

  it "stamps component and event ahead of the caller's fields" do
    logger = RecordingLogger.new
    klass.new(logger: logger).say(detail: "x")

    expect(logger.messages(:info))
      .to contain_exactly({ component: "tester", event: "test.event", detail: "x" })
  end

  it "falls back to Rails.logger when no logger was injected" do
    allow(Rails.logger).to receive(:info)
    klass.new.say

    expect(Rails.logger).to have_received(:info)
      .with(hash_including(component: "tester", event: "test.event"))
  end

  it "refuses to log for a class that never declared its component" do
    # D-027's contract: a forgotten declaration is a hard error on first
    # log, never a silent component:null on every line.
    undeclared = Class.new { include StructuredLogging }.new

    expect { undeclared.send(:log_event, :info, "test.event") }
      .to raise_error(ArgumentError, /log_component/)
  end

  it "inherits the component in subclasses" do
    # Jobs declare their component once on the shared parent; the
    # class_attribute is what carries it down.
    logger = RecordingLogger.new
    Class.new(klass).new(logger: logger).say

    expect(logger.messages(:info).last[:component]).to eq("tester")
  end
end
