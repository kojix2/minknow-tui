require "spec"
require "../src/minknow_tui/model"
require "../src/minknow_tui/options"

describe MinknowTui::Series do
  it "replaces overlapping cumulative snapshots and bounds long histories" do
    series = MinknowTui::Series.new
    series.put(60, 100)
    series.put(60, 120)
    series.put(30, 50)
    series.points.should eq([{30.0, 50.0}, {60.0, 120.0}])
    5000.times { |i| series.put(i, i) }
    series.points.size.should be <= 1440
    series.points.first.should eq({0.0, 0.0})
    series.points.last.should eq({4999.0, 4999.0})
  end
end

describe MinknowTui::Metrics do
  it "zooms past a long sparse tail without discarding reads or changing N50" do
    metrics = MinknowTui::Metrics.new
    metrics.n50 = 12000.0
    metrics.histogram = (0...1000).map do |index|
      MinknowTui::HistogramBin.new(index * 1000.0, (index + 1) * 1000.0,
        index < 30 ? 1000.0 : index == 900 ? 1.0 : 0.0)
    end
    bars = metrics.histogram_bars(16)
    bars.size.should be <= 16
    bars.count { |bin| bin.count > 0 }.should be > 8
    bars[-2].upper.should eq(30000)
    bars.last.upper.infinite?.should_not be_nil
    bars.last.count.should eq(1)
    bars.sum(&.count).should eq(30001)
    metrics.n50.should eq(12000)
    full = metrics.histogram_bars(16, full_range: true)
    full.last.upper.should eq(901000)
    full.sum(&.count).should eq(30001)
    metrics.histogram_bars(1).size.should eq(1)
  end

  it "does not invent a distribution when the API supplies no reads or one coarse bin" do
    metrics = MinknowTui::Metrics.new
    metrics.histogram_bars(16).should be_empty
    metrics.histogram = [MinknowTui::HistogramBin.new(0.0, 41000.0, 200.0)]
    metrics.histogram_bars(16).should eq(metrics.histogram)
  end
end

describe MinknowTui::Position do
  it "replaces sparse channel updates, bounds IDs and ignores older samples" do
    position = MinknowTui::Position.new("X1")
    position.channels = 512_u32
    position.update_channel(1, MinknowTui::ChannelState.new("pore", 1_u32, 100_u64))
    position.update_channel(2, MinknowTui::ChannelState.new("strand", 2_u32, 100_u64))
    position.update_channel(1, MinknowTui::ChannelState.new("unblocking", 1_u32, 110_u64))
    position.update_channel(1, MinknowTui::ChannelState.new("pore", 1_u32, 90_u64))
    position.update_channel(513, MinknowTui::ChannelState.new("strand"))
    position.pore_states.size.should eq(2)
    position.pore_states[1].name.should eq("unblocking")
    position.pore_states[2].well.should eq(2)
  end
end

describe MinknowTui::Store do
  it "defaults to current acquisition, preserves historical selection and invalidates old producers" do
    store = MinknowTui::Store.new
    position = MinknowTui::Position.new("X1")
    run = MinknowTui::Run.new("protocol")
    run.acquisitions = ["calibration", "sequencing"]
    position.runs[run.id] = run
    position.current_run = run.id
    position.current_acquisition = "sequencing"
    store.positions[position.name] = position
    store.select_position("X1")
    store.acquisition_id.should eq("sequencing")
    generation = store.generation
    store.select_acquisition("calibration")
    store.current?(generation).should be_false
    store.sync_selection
    store.acquisition_id.should eq("calibration")
    historical = MinknowTui::Run.new("old")
    historical.acquisitions = ["old-cal", "old-seq"]
    position.runs[historical.id] = historical
    store.select_run("old")
    store.acquisition_id.should eq("old-seq")
    position.current_run = "new"
    store.sync_selection
    store.run_id.should eq("old")
  end

  it "separates hardware/software state from the presence of a sequencing run" do
    p = MinknowTui::Position.new("X1")
    p.software = "Running"
    p.protocol_state = "Idle"
    p.status.should eq("Idle")
    p.has_flow_cell = false
    p.status.should eq("No flow cell")
    p.software = "Hardware Error"
    p.status.should eq("Hardware Error")
  end

  it "deduplicates replayed messages, scopes events and bounds retention" do
    store = MinknowTui::Store.new
    store.position_id = "X1"
    time = Time.utc
    2.times { store.event("X1", "INFO", "Replay {red-fg}\e[31m", time) }
    store.events.size.should eq(1)
    store.events.first.message.should_not contain('\e')
    store.event("X2", "INFO", "Other position")
    store.event("Host", "WARN", "Host notification")
    store.visible_events.size.should eq(2)
    2010.times { |i| store.event("TUI", "INFO", "event #{i}") }
    store.events.size.should eq(2000)
  end
end

describe MinknowTui::Options do
  it "supports demo and explicit manager ports without connecting" do
    options = MinknowTui::Options.new(["--demo", "--host", "example", "--port", "9502"])
    options.demo?.should be_true
    options.explicit_port?.should be_true
    options.host.should eq("example")
    options.port.should eq(9502)
  end

  it "prints help/version and rejects invalid ports" do
    output = IO::Memory.new
    MinknowTui::Options.new(["--help"], output).exit_requested?.should be_true
    output.to_s.should contain("--demo")
    expect_raises(ArgumentError) { MinknowTui::Options.new(["--port", "70000"]) }
  end
end
