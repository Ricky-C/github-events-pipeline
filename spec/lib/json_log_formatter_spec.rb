require "rails_helper"

RSpec.describe JsonLogFormatter do
  subject(:formatter) { described_class.new }

  let(:time) { Time.utc(2026, 7, 8, 12, 0, 0) }

  it "emits one JSON object per line with ts and level" do
    line = formatter.call("INFO", time, nil, "booted")

    expect(line).to end_with("\n")
    parsed = JSON.parse(line)
    expect(parsed).to eq("ts" => "2026-07-08T12:00:00.000Z", "level" => "info", "msg" => "booted")
  end

  it "merges hash messages into the entry for structured events" do
    line = formatter.call("INFO", time, nil, { component: "ingester", event: "poll.cycle", events_seen: 30 })

    parsed = JSON.parse(line)
    expect(parsed).to include("component" => "ingester", "event" => "poll.cycle", "events_seen" => 30)
    expect(parsed).to include("ts", "level")
  end

  it "neutralizes newline injection in external strings" do
    hostile = "repo-name\n{\"level\":\"info\",\"event\":\"forged\"}"

    line = formatter.call("WARN", time, nil, hostile)

    # The hostile newline must stay inside the JSON string encoding —
    # exactly one physical log line comes out.
    expect(line.strip.lines.count).to eq(1)
    expect(JSON.parse(line)["msg"]).to eq(hostile)
  end

  it "keeps the reserved ts/level fields when a hash message tries to forge them" do
    line = formatter.call("WARN", time, nil, { level: "info", ts: "1970-01-01", event: "db.failure" })

    parsed = JSON.parse(line)
    expect(parsed["level"]).to eq("warn")
    expect(parsed["ts"]).to eq("2026-07-08T12:00:00.000Z")
    expect(parsed["event"]).to eq("db.failure")
  end

  it "does not emit duplicate JSON keys for string-keyed reserved fields" do
    line = formatter.call("INFO", time, nil, { "level" => "error" })

    expect(line.scan('"level"').count).to eq(1)
    expect(JSON.parse(line)["level"]).to eq("info")
  end

  it "replaces invalid UTF-8 instead of raising from inside the logging path" do
    line = formatter.call("INFO", time, nil, "repo-\xC3".b)

    expect(JSON.parse(line)["msg"]).to start_with("repo-")
  end

  it "scrubs invalid UTF-8 inside hash message values" do
    line = formatter.call("INFO", time, nil, { repo_name: "bad-\xC3".b, nested: { names: ["ok", "bad-\xC3".b] } })

    parsed = JSON.parse(line)
    expect(parsed["repo_name"]).to start_with("bad-")
    expect(parsed["nested"]["names"].last).to start_with("bad-")
  end

  it "logs exception class and backtrace, not just the message" do
    error = begin
      raise ArgumentError, "boom"
    rescue ArgumentError => e
      e
    end

    msg = JSON.parse(formatter.call("ERROR", time, nil, error))["msg"]
    expect(msg).to include("boom (ArgumentError)")
    expect(msg).to include(__FILE__)
  end
end
