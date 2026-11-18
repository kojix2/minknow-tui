require "spec"
require "file/tempfile"
require "../src/minknow_tui/api"

private class TestCAConfig < MinknowTui::ConnectionConfig
  property ca_paths = [] of String

  private def default_ca_certificate_paths : Array(String)
    ca_paths
  end
end

private def with_ca_environment(trusted_ca : String? = nil, auto_detect : String? = nil, &)
  previous_ca = ENV["MINKNOW_TRUSTED_CA"]?
  previous_auto = ENV["MINKNOW_AUTO_DETECT_CA"]?
  ENV["MINKNOW_TRUSTED_CA"] = trusted_ca
  ENV["MINKNOW_AUTO_DETECT_CA"] = auto_detect
  yield
ensure
  ENV["MINKNOW_TRUSTED_CA"] = previous_ca
  ENV["MINKNOW_AUTO_DETECT_CA"] = previous_auto
end

describe MinknowTui::ConnectionConfig do
  it "loads an existing default CA only for loopback hosts with discovery enabled" do
    File.tempfile("minknow-invalid-ca") do |file|
      with_ca_environment do
        {"localhost", "127.0.0.1", "::1", "[::1]"}.each do |host|
          local = TestCAConfig.new(host: host)
          local.ca_paths = [file.path]
          # An empty file fails to load if passed to OpenSSL.
          expect_raises(OpenSSL::Error, /SSL_CTX_load_verify_locations/) { local.tls_context }
        end

        remote = TestCAConfig.new(host: "minion.example")
        remote.ca_paths = [file.path]
        remote.tls_context.try(&.verify_mode).should eq(OpenSSL::SSL::VerifyMode::PEER)
      end

      with_ca_environment(auto_detect: "false") do
        local = TestCAConfig.new(host: "localhost")
        local.ca_paths = [file.path]
        local.tls_context.try(&.verify_mode).should eq(OpenSSL::SSL::VerifyMode::PEER)
      end
    end
  end

  it "honors an explicit CA for remote and derived connections with discovery disabled" do
    File.tempfile("minknow-invalid-ca") do |file|
      with_ca_environment(trusted_ca: file.path, auto_detect: "false") do
        config = MinknowTui::ConnectionConfig.new(host: "minion.example")
        expect_raises(OpenSSL::Error, /SSL_CTX_load_verify_locations/) { config.tls_context }
        expect_raises(OpenSSL::Error, /SSL_CTX_load_verify_locations/) { config.with_port(9502).tls_context }
      end
    end
  end

  it "reports an invalid explicit CA path rather than falling back" do
    File.tempfile("minknow-invalid-ca") do |file|
      with_ca_environment(trusted_ca: "#{file.path}/ca.crt") do
        config = TestCAConfig.new(host: "localhost")
        config.ca_paths = [file.path]
        error = expect_raises(MinknowTui::ConnectionConfig::InvalidCAPath) { config.tls_context }
        MinknowTui::Api.failure(error).should contain("MINKNOW_TRUSTED_CA")
      end
    end
  end
end

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
