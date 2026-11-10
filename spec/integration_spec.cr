require "spec"
require "./support/fake_minknow"

describe "MinKNOW compatibility over local HTTP/2" do
  it "uses histogram N50 as a fallback and decodes overlapping yield, quality and temperature streams" do
    with_fake_minknow do |api, store, peers, _|
      peers.each(&.statistics_available=(true))
      api.start
      wait_for { store.positions["X1"]?.try(&.runs.size) == 2 }
      store.select_position("X1")
      wait_for { store.detail.n50 == 12345.0 }
      wait_for { store.positions["X1"].capabilities["detail.read_length_n50"]? == "Unsupported" }
      store.tab = 1
      wait_for { store.detail.pass.points == [{60.0, 120.0}] }
      store.tab = 2
      wait_for { store.detail.occupancy == 0.75 }
      store.detail.channel_states["strand"].should eq(75.0)
      store.detail.histogram.first[1].should eq(7.0)
      store.tab = 3
      wait_for { store.detail.temperatures.points.size == 3 }
      store.detail.temperatures.points.should eq([{0.0, 35.0}, {60.0, 36.0}, {120.0, 37.0}])
    end
  end

  it "falls back from unsupported streams, loads runs and continues when optional APIs are absent" do
    with_fake_minknow do |api, store, _, calls|
      api.start
      wait_for { store.positions["X1"]?.try(&.runs.size) == 2 }
      wait_for { store.capabilities["watch_positions"]? == "Unsupported" }
      position = store.positions["X1"]
      wait_for { position.capabilities["activity"]? == "Unsupported" }
      store.select_position("X1")
      wait_for { store.detail.reads == 100_i64 }
      store.version.should eq("6.0.0-fixture")
      store.run_id.should eq("current")
      store.acquisition_id.should eq("current-seq")
      position.flow_cell.should eq("TEST001")
      position.capabilities["history"].should eq("Available")
      store.tab = 1
      wait_for { position.capabilities["detail.yield"]? == "Unsupported" }
      store.detail.pass_bases.should eq(10000)
      # Missing optional APIs must not cause control or mutation RPCs.
      calls.any? { |call| call.includes?("start_protocol") || call.includes?("stop_protocol") || call.includes?("set_") }.should be_false
    end
  end

  it "discards a delayed historical response after switching acquisition" do
    with_fake_minknow do |api, store, peers, calls|
      peers.each(&.slow_old_summary=(true))
      api.start
      wait_for { store.positions["X1"]?.try(&.runs.size) == 2 }
      store.select_position("X1")
      wait_for { store.detail.reads == 100_i64 }
      store.select_run("old")
      wait_for { calls.includes?("summary:old-seq") }
      store.select_run("current")
      wait_for { store.detail.reads == 100_i64 }
      sleep 0.7.seconds
      store.acquisition_id.should eq("current-seq")
      store.detail.reads.should eq(100)
    end
  end

  it "keeps zero positions usable and distinguishes authentication failure" do
    with_fake_minknow do |api, store, peers, _|
      peers.each(&.empty=(true))
      api.start
      wait_for { store.connection == "Connected" && store.capabilities["positions"]? == "Available" }
      store.positions.should be_empty
    end
    with_fake_minknow do |api, store, peers, _|
      peers.each(&.authenticated=(false))
      api.start
      wait_for { store.connection == "Authentication required" }
      store.capabilities.values.should_not contain("Unsupported")
    end
  end

  it "treats idle positions as normal and reconciles unplugging and reconnecting" do
    with_fake_minknow do |api, store, peers, _|
      peers.each(&.active_run=(false))
      api.start
      wait_for { store.positions["X1"]?.try(&.capabilities["current_protocol"]?) == "Not applicable / no active run" }
      position = store.positions["X1"]
      position.current_run.should be_nil
      position.current_acquisition.should be_nil
      position.status.should_not eq("Sequencing")
      store.select_position("X1")
      peers.each(&.empty=(true))
      wait_for { store.positions.empty? }
      store.position_id.should be_nil
      peers.each(&.empty=(false))
      wait_for { store.positions.has_key?("X1") }
      store.positions["X1"].should_not be(position)
    end
  end
end
