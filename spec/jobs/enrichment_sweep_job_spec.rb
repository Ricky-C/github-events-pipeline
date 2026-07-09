require "rails_helper"

RSpec.describe EnrichmentSweepJob do
  it "delegates to the sweep and runs on the enrichment queue" do
    sweep = instance_double(EnrichmentSweep, call: 0)
    allow(EnrichmentSweep).to receive(:new).and_return(sweep)

    described_class.perform_now

    expect(sweep).to have_received(:call)
    expect(described_class.new.queue_name).to eq("enrichment")
  end
end
