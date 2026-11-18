require "spec"
require "file/tempfile"
require "./support/fake_minknow"

private def with_token_file(contents : String, &)
  file = File.tempfile("minknow-tui-token", ".json")
  file.close
  File.write(file.path, contents)
  begin
    yield file.path
  ensure
    file.delete
  end
end

describe "MinKNOW compatibility over local HTTP/2" do
  it "resumes channel monitoring when a position endpoint returns without changing the historical selection" do
    with_fake_minknow do |api, store, peers, calls|
      peers.each do |peer|
        peer.active_run = false
        peer.channels_available = true
        # Let history load before reconciliation to keep the selection stable.
        peer.device_info_delay = 0.1.seconds
      end
      api.start
      wait_for { store.positions["X1"]?.try(&.runs.size) == 2 }
      store.select_position("X1")
      store.select_run("current")
      store.tab = 4
      position = store.positions["X1"]
      wait_for { position.capabilities["channels"]? == "Available" }

      peers.each(&.rpc_available=(false))
      wait_for { position.port.nil? }
      sleep 0.3.seconds
      generation = store.generation
      previous = calls.count(&.ends_with?("/get_channel_states"))
      peers.each(&.rpc_available=(true))
      wait_for { position.connected? && !position.port.nil? && position.capabilities["device"]? == "Available" }
      wait_for { calls.count(&.ends_with?("/get_channel_states")) > previous && position.capabilities["channels"]? == "Available" }
      store.generation.should eq(generation)
      store.run_id.should eq("current")
      store.acquisition_id.should eq("current-seq")
    end
  end

  it "preserves newer watch additions when a delayed position snapshot completes" do
    with_fake_minknow do |api, store, peers, _|
      peers.each do |peer|
        peer.watch_positions_available = true
        peer.watch_position_names = ["X1", "X2"]
        peer.positions_delay = 0.25.seconds
      end
      api.start
      wait_for { store.positions.has_key?("X2") }
      store.select_position("X2")
      peers.each(&.position_names=(["X1", "X2"]))
      wait_for { store.capabilities["positions"]? == "Available" }
      store.positions.has_key?("X2").should be_true
      store.position_id.should eq("X2")
    end
  end

  it "reconciles positions removed during a watch interruption" do
    with_fake_minknow do |api, store, peers, calls|
      peers.each do |peer|
        peer.watch_positions_available = true
        peer.position_names = ["X1", "X2"]
      end
      api.start
      wait_for { store.positions.has_key?("X2") }
      store.select_position("X2")
      peers.each(&.position_names=(["X1"]))
      wait_for { calls.count(&.ends_with?("/watch_flow_cell_positions")) >= 2 }
      wait_for { !store.positions.has_key?("X2") }
      store.positions.has_key?("X1").should be_true
      store.position_id.should be_nil
    end
  end

  it "refreshes local authentication after the discovered token changes" do
    with_token_file({"token" => "initial"}.to_json) do |path|
      with_fake_minknow(local_auth: true) do |api, store, peers, calls|
        peers.each do |peer|
          peer.auth_token = "initial"
          peer.local_token_path = path
        end
        api.start
        wait_for { store.capabilities["manager_health"]? == "Available" && store.positions["X1"]?.try(&.connected?) == true }
        lookups = calls.count(&.ends_with?("/local_authentication_token_path"))
        File.write(path, {"token" => "replaced"}.to_json)
        peers.each(&.auth_token=("replaced"))
        wait_for { store.positions["X1"].capabilities["current_protocol"]? == "Authentication required" }
        wait_for(25.seconds) { store.positions["X1"].capabilities["current_protocol"]? == "Available" }
        wait_for { store.positions["X1"].connected? }
        calls.count(&.ends_with?("/local_authentication_token_path")).should be > lookups
      end
    end
  end

  it "retries discovery when the local token file is initially incomplete" do
    with_token_file("[]") do |path|
      with_fake_minknow(local_auth: true) do |api, store, peers, _|
        peers.each do |peer|
          peer.auth_token = "ready"
          peer.local_token_path = path
        end
        api.start
        wait_for { store.capabilities["manager_health"]? == "Available" && store.positions["X1"]?.try(&.capabilities["current_protocol"]?) == "Authentication required" }
        # Force the next reconciliation to run before the refreshed token arrives.
        peers.each(&.local_token_delay=(1.second))
        File.write(path, {"token" => "ready"}.to_json)
        # Token refresh and reconciliation each poll every 15 seconds; allow either order.
        wait_for(40.seconds) { store.positions["X1"].capabilities["current_protocol"]? == "Available" }
      end
    end
  end

  it "keeps an explicitly configured authentication token" do
    with_fake_minknow(local_auth: true, authentication_token: "explicit") do |api, store, peers, calls|
      peers.each(&.auth_token=("explicit"))
      api.start
      wait_for { store.capabilities["manager_health"]? == "Available" && store.positions["X1"]?.try(&.connected?) == true }
      calls.any?(&.ends_with?("/local_authentication_token_path")).should be_false
    end
  end

  it "reloads live channel styles on acquisition changes while historical selection stays fixed" do
    with_fake_minknow do |api, store, peers, _|
      peers.each(&.channels_available=(true))
      api.start
      wait_for { store.positions["X1"]?.try(&.runs.size) == 2 }
      store.select_position("X1")
      store.select_run("old")
      store.tab = 4
      position = store.positions["X1"]
      wait_for { position.state_styles["strand"]?.try(&.label) == "Sequencing" }
      generation = store.generation
      peers.each do |peer|
        peer.current_acquisition_id = "current-seq-2"
        peer.channel_label = "New acquisition strand label"
      end
      wait_for { position.current_acquisition == "current-seq-2" && position.state_styles["strand"]?.try(&.label) == "New acquisition strand label" }
      store.run_id.should eq("old")
      store.generation.should eq(generation)
    end
  end

  it "streams live channels independently of selected history and unsubscribes on tab changes" do
    with_fake_minknow do |api, store, peers, calls|
      peers.each(&.channels_available=(true))
      api.start
      wait_for { store.positions["X1"]?.try(&.runs.size) == 2 }
      store.select_position("X1")
      store.select_run("old")
      store.tab = 4
      position = store.positions["X1"]
      wait_for { position.pore_states[1]?.try(&.name) == "unblocking" }
      position.pore_states.size.should eq(1)
      position.pore_states[1].well.should eq(2)
      store.acquisition_id.should eq("old-seq")
      position.current_acquisition.should eq("current-seq")
      calls.should contain("channels:1-512")
      store.tab = 0
      sleep 0.2.seconds
      count = calls.count(&.ends_with?("/get_channel_states"))
      sleep 1.2.seconds
      calls.count(&.ends_with?("/get_channel_states")).should eq(count)
    end
  end

  it "reports an unsupported live channel API while keeping run monitoring usable" do
    with_fake_minknow do |api, store, _, _|
      api.start
      wait_for { store.positions["X1"]?.try(&.runs.size) == 2 }
      store.select_position("X1")
      store.tab = 4
      wait_for { store.position.try(&.capabilities["channels"]?) == "Unsupported" }
      store.tab = 0
      wait_for { store.detail.reads == 100_i64 }
    end
  end

  it "does not report disconnection when activity works but flow-cell info is unsupported" do
    with_fake_minknow do |api, store, peers, _|
      peers.each do |peer|
        case peer.service_full_name
        when "minknow_api.instance.InstanceService"
          peer.activity_available = true
        when "minknow_api.device.DeviceService"
          peer.flow_cell_available = false
          peer.flow_cell_delay = 0.25.seconds
        end
      end
      api.start
      wait_for do
        if position = store.positions["X1"]?
          position.capabilities["reconcile"]? == "Available" &&
            position.capabilities["flow_cell"]? == "Unsupported" &&
            position.capabilities["activity"]? == "Available"
        else
          false
        end
      end
      store.positions["X1"].connected?.should be_true
      store.positions["X1"].status.should_not eq("Disconnected (last known)")
    end
  end

  it "uses histogram N50 as a fallback and decodes overlapping yield, quality and temperature streams" do
    with_fake_minknow do |api, store, peers, calls|
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
      wait_for { store.detail.qscore_histogram.first?.try(&.count) == 25.0 }
      wait_for { store.detail.qscore_medians.points == [{0.0, 18.0}, {3600.0, 19.0}] }
      calls.should contain("boxplot-width:60")
      store.detail.state_styles["strand"].label.should eq("Sequencing")
      store.detail.channel_states["strand"].should eq(75.0)
      store.detail.histogram.first.count.should eq(7.0)
      store.tab = 3
      wait_for { store.detail.temperatures.points.size == 3 }
      store.detail.temperatures.points.should eq([{0.0, 35.0}, {60.0, 36.0}, {120.0, 37.0}])
      wait_for { store.detail.bias_voltages.points.size == 3 }
      store.detail.bias_voltages.points.last.should eq({120.0, -170.0})
      store.tab = 5
      wait_for { store.detail.duty_buckets.size == 1 }
      store.detail.activity_buckets.first.states["Sequencing"].should eq(75.0)
    end
  end

  it "shows run-until estimates and keeps unsupported optional streams scoped to their tabs" do
    with_fake_minknow do |api, store, peers, calls|
      peers.each(&.remaining_available=(true))
      api.start
      wait_for { store.positions["X1"]?.try(&.runs.size) == 2 }
      store.select_position("X1")
      wait_for { store.detail.remaining_until != nil }
      store.detail.remaining_estimated?.should be_false
      calls.any?(&.ends_with?("/stream_updates")).should be_true
      store.tab = 3
      wait_for { store.position.try(&.capabilities["detail.bias_voltage"]?) == "Unsupported" }
      store.tab = 5
      wait_for { store.position.try(&.capabilities["detail.duty_time"]?) == "Unsupported" }
    end
  end

  it "does not request Q-score streams when basecalling is disabled" do
    with_fake_minknow do |api, store, peers, calls|
      peers.each(&.basecalling_enabled=(false))
      api.start
      wait_for { store.positions["X1"]?.try(&.runs.size) == 2 }
      store.select_position("X1")
      store.tab = 2
      wait_for { store.position.try(&.capabilities["detail.qscore_histogram"]?) == "Disabled (basecalling off)" }
      calls.any?(&.ends_with?("/stream_q_score_histogram")).should be_false
      calls.any?(&.ends_with?("/stream_basecall_boxplots")).should be_false
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
