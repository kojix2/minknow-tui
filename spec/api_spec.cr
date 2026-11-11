require "spec"
require "../src/minknow_tui/api"

describe MinknowTui::Decode do
  it "supports old phases and distinguishes absent output paths from explicitly empty paths" do
    raw = MinknowApi::Protocol::ProtocolRunInfo.new
    raw.run_id = "run"
    raw.phase = Proto::OpenEnum(MinknowApi::Protocol::ProtocolPhase).new(999)
    raw.output_path = "/old/path"
    decoded = MinknowTui::Decode.run(raw)
    decoded.phase.should eq("Unknown(999)")
    decoded.output.should eq("/old/path")
    raw.reported_output_path = ""
    MinknowTui::Decode.run(raw).output.should eq("")
    first = MinknowApi::Protocol::ProtocolPhaseSnapshot.new
    first.phase = Proto::OpenEnum(MinknowApi::Protocol::ProtocolPhase).new(1000)
    first.timestamp = Google::Protobuf::Timestamp.new.tap(&.seconds=(100_i64))
    raw.phase_history = [first]
    MinknowTui::Decode.run(raw).phase.should eq("Unknown(1000)")
  end

  it "keeps acquired reads, basecall counts and basecalled/estimated bases separate" do
    raw = MinknowApi::Acquisition::AcquisitionYieldSummary.new
    raw.read_count = 10_i64
    raw.basecalled_pass_read_count = 12_i64
    raw.basecalled_pass_bases = 100_i64
    raw.estimated_selected_bases = 150_i64
    metrics = MinknowTui::Metrics.new
    MinknowTui::Decode.summary(metrics, raw)
    metrics.reads.should eq(10)
    metrics.pass_calls.should eq(12)
    metrics.pass_bases.should eq(100)
    metrics.estimated_bases.should eq(150)
    metrics.basecalling_enabled = false
    MinknowTui::Decode.summary(metrics, raw)
    metrics.pass_bases.should be_nil
    metrics.processed.should be_nil
    metrics.reads.should eq(10)
  end
end

describe MinknowTui::Api do
  it "formats an IPv6 manager endpoint unambiguously" do
    store = MinknowTui::Store.new
    MinknowTui::Api.new(store, MinknowTui::Options.new(["--host", "::1", "--port", "9501"]))
    store.endpoint.should eq("[::1]:9501")
  end

  it "checks stream trailer status rather than assuming successful enumeration" do
    expect_raises(GRPC::StatusError) { MinknowTui::Api.check_status(GRPC::Status.unimplemented) }
    MinknowTui::Api.failure(GRPC::StatusError.new(GRPC::Status.unimplemented)).should eq("Unsupported")
    MinknowTui::Api.failure(GRPC::StatusError.new(GRPC::StatusCode::UNAUTHENTICATED)).should eq("Authentication required")
    MinknowTui::Api.failure(GRPC::StatusError.new(GRPC::StatusCode::FAILED_PRECONDITION)).should eq("Not applicable / no active run")
  end

  it "cancels registered streams once and immediately cancels late registrations" do
    scope = MinknowTui::Scope.new
    count = 0
    scope.register { count += 1; nil }
    scope.stop
    scope.stop
    scope.register { count += 1; nil }
    count.should eq(2)
  end
end
