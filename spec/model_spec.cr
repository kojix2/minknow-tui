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
  it "trims one percent from each end for display without changing N50" do
    metrics = MinknowTui::Metrics.new
    metrics.n50 = 12000.0
    metrics.histogram = (0...1000).map do |index|
      MinknowTui::HistogramBin.new(index * 1000.0, (index + 1) * 1000.0,
        index < 30 ? 1000.0 : index == 900 ? 1.0 : 0.0)
    end
    bars = metrics.histogram_bars(16)
    bars.size.should be <= 16
    bars.count { |bin| bin.count > 0 }.should be > 8
    bars.first.count.should be < 2000
    bars.last.upper.should eq(30000)
    bars.sum(&.count).should be_close(29400.98, 0.01)
    metrics.n50.should eq(12000)
    full = metrics.histogram_bars(16, full_range: true)
    full.last.upper.should eq(901000)
    full.sum(&.count).should eq(30001)
    metrics.histogram_bars(1).size.should eq(1)
  end

  it "replaces overlapping duty buckets and groups history at five minutes after 48 minutes" do
    metrics = MinknowTui::Metrics.new
    metrics.state_styles["strand"] = MinknowTui::StateStyle.new("Sequencing", "", "#52d687", "Sequencing", 1_u32)
    metrics.state_styles["adapter"] = MinknowTui::StateStyle.new("Adapter", "", "#52d687", "Sequencing", 2_u32)
    metrics.put_duty(MinknowTui::DutyBucket.new(0, 60, {"strand" => 3.0, "adapter" => 1.0}))
    metrics.put_duty(MinknowTui::DutyBucket.new(0, 60, {"strand" => 2.0, "adapter" => 2.0}))
    metrics.activity_buckets.first.states["Sequencing"].should eq(100.0)
    metrics.activity_buckets(true, false).first.states.should eq({"strand" => 2.0, "adapter" => 2.0})
    metrics.sample_rate = 2_u32
    metrics.activity_buckets(true, false).first.states.should eq({"strand" => 1.0, "adapter" => 1.0})
    metrics.put_duty(MinknowTui::DutyBucket.new(2880, 2940, {"strand" => 4.0}))
    metrics.activity_buckets.size.should eq(2)
    metrics.activity_buckets.first.finish.should eq(300)
  end

  it "normalizes API state and group colors for terminal rendering" do
    style = MinknowTui::StateStyle.new("", "", "12AbEF", "", 0_u32, "#112233")
    style.terminal_colour.should eq("#12AbEF")
    style.group_terminal_colour.should eq("#112233")
    MinknowTui::StateStyle.normalize_colour("bad{tag}").should be_nil
  end

  it "does not invent a distribution when the API supplies no reads or one coarse bin" do
    metrics = MinknowTui::Metrics.new
    metrics.histogram_bars(16).should be_empty
    metrics.histogram = [MinknowTui::HistogramBin.new(0.0, 41000.0, 200.0)]
    metrics.histogram_bars(16).first.count.should eq(196.0)
  end

  it "keeps empty bins between populated read-length ranges" do
    metrics = MinknowTui::Metrics.new
    metrics.histogram = [MinknowTui::HistogramBin.new(0.0, 1.0, 10.0),
                         MinknowTui::HistogramBin.new(1.0, 2.0, 0.0),
                         MinknowTui::HistogramBin.new(2.0, 3.0, 10.0)]
    metrics.histogram_bars(3, full_range: true).map(&.count).should eq([10.0, 0.0, 10.0])
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
  it "clears stale detail status on selection and tab changes while retaining unsupported APIs" do
    store = MinknowTui::Store.new
    position = MinknowTui::Position.new("X1")
    store.positions[position.name] = position
    store.select_position("X1")
    position.capabilities["detail.yield"] = "Available"
    position.capabilities["detail.bias"] = "Unsupported"
    store.select_acquisition("other")
    position.capabilities.has_key?("detail.yield").should be_false
    position.capabilities["detail.bias"].should eq("Unsupported")
    position.capabilities["detail.qscore"] = "Available"
    store.tab = 2
    position.capabilities.has_key?("detail.qscore").should be_false
    position.capabilities["detail.bias"].should eq("Unsupported")
  end

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
