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
end
