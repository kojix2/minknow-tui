require "../../src/minknow_tui/api"

# An actual local HTTP/2 peer. It deliberately rejects watch/activity/statistics
# streams using trailers, as an older Core would, while basic unary RPCs work.
class FakeMinKnow < GRPC::Service
  alias MA = MinknowApi
  getter calls : Array(String)
  property? authenticated = true
  property? slow_old_summary = false
  property? empty = false
  property? active_run = true
  property? statistics_available = false

  def initialize(@service_full_name : String, @port : Int32, @calls = [] of String)
  end

  getter service_full_name : String

  # A flat RPC table keeps this test peer easy to inspect.
  # ameba:disable Metrics/CyclomaticComplexity
  def dispatch(method : String, request_body : Bytes, ctx : GRPC::ServerContext) : {Bytes, GRPC::Status}
    @calls << "#{service_full_name}/#{method}"
    return {Bytes.empty, GRPC::Status.new(GRPC::StatusCode::UNAUTHENTICATED)} unless authenticated?
    response = case {service_full_name, method}
               when {"minknow_api.manager.ManagerService", "get_version_info"}
                 MA::Instance::GetVersionInfoResponse.new.tap do |reply|
                   reply.minknow = MA::Instance::GetVersionInfoResponse::MinknowVersion.new.tap(&.full=("6.0.0-fixture"))
                 end
               when {"minknow_api.manager.ManagerService", "describe_host"}
                 MA::Manager::DescribeHostResponse.new.tap(&.description=("Fake MinKNOW"))
               when {"minknow_api.protocol.ProtocolService", "list_protocol_runs"}
                 MA::Protocol::ListProtocolRunsResponse.new.tap(&.run_ids=(["current", "old"]))
               when {"minknow_api.protocol.ProtocolService", "get_current_protocol_run"}
                 return {Bytes.empty, GRPC::Status.new(GRPC::StatusCode::FAILED_PRECONDITION)} unless active_run?
                 protocol("current")
               when {"minknow_api.protocol.ProtocolService", "get_run_info"}
                 protocol(MA::Protocol::GetRunInfoRequest.decode(request_body).run_id)
               when {"minknow_api.acquisition.AcquisitionService", "get_current_acquisition_run"}
                 return {Bytes.empty, GRPC::Status.new(GRPC::StatusCode::FAILED_PRECONDITION)} unless active_run?
                 acquisition("current-seq")
               when {"minknow_api.acquisition.AcquisitionService", "get_acquisition_info"}
                 id = MA::Acquisition::GetAcquisitionRunInfoRequest.decode(request_body).run_id
                 @calls << "summary:#{id}"
                 sleep 0.5.seconds if slow_old_summary? && id.starts_with?("old")
                 acquisition(id)
               when {"minknow_api.device.DeviceService", "get_flow_cell_info"}
                 MA::Device::GetFlowCellInfoResponse.new.tap { |reply| reply.has_flow_cell = true; reply.flow_cell_id = "TEST001" }
               when {"minknow_api.device.DeviceService", "get_device_info"}
                 MA::Device::GetDeviceInfoResponse.new.tap(&.device_id=("FIXTURE"))
               when {"minknow_api.device.DeviceService", "get_temperature"}
                 MA::Device::GetTemperatureResponse.new
               when {"minknow_api.statistics.StatisticsService", "get_read_length_types"}
                 return {Bytes.empty, GRPC::Status.unimplemented} unless statistics_available?
                 MA::Statistics::GetReadLengthTypesResponse.new.tap do |reply|
                   reply.available_types = [1, 2].map { |v| Proto::OpenEnum(MA::Statistics::ReadLengthType).new(v) }
                 end
               else
                 return {Bytes.empty, GRPC::Status.unimplemented}
               end
    {response.encode, GRPC::Status.ok}
  end

  def server_streaming?(method : String) : Bool
    {"flow_cell_positions", "watch_flow_cell_positions", "stream_instance_activity", "stream_notifications", "get_user_messages",
     "stream_acquisition_output", "stream_duty_time", "stream_read_length_histogram", "stream_temperature"}.includes?(method)
  end

  def dispatch_server_stream(method : String, request : Bytes, ctx : GRPC::ServerContext, writer : GRPC::RawResponseStream) : GRPC::Status
    @calls << "#{service_full_name}/#{method}"
    return GRPC::Status.new(GRPC::StatusCode::UNAUTHENTICATED) unless authenticated?
    if statistics_available? && service_full_name == "minknow_api.statistics.StatisticsService"
      return statistics_stream(method, request, writer)
    end
    return GRPC::Status.unimplemented unless method == "flow_cell_positions"
    response = MA::Manager::FlowCellPositionsResponse.new
    unless empty?
      position = MA::Manager::FlowCellPosition.new
      position.name = "X1"
      position.state = Proto::OpenEnum(MA::Manager::FlowCellPosition::State).new(1)
      position.rpc_ports = MA::Manager::FlowCellPosition::RpcPorts.new.tap(&.secure=(@port.to_u32))
      response.positions = [position]
      response.total_count = 1
    end
    writer.send_raw(response.encode)
    GRPC::Status.ok
  end

  private def statistics_stream(method, request, writer)
    case method
    when "stream_acquisition_output"
      # The second response revises the first cumulative snapshot.
      [100_i64, 120_i64].each do |bases|
        snapshot = MA::Statistics::AcquisitionOutputSnapshot.new
        snapshot.seconds = 60_u32
        snapshot.yield_summary = MA::Acquisition::AcquisitionYieldSummary.new.tap(&.basecalled_pass_bases=(bases))
        group = MA::Statistics::StreamAcquisitionOutputResponse::FilteredSnapshots.new.tap(&.snapshots=([snapshot]))
        response = MA::Statistics::StreamAcquisitionOutputResponse.new.tap(&.snapshots=([group]))
        writer.send_raw(response.encode)
      end
    when "stream_read_length_histogram"
      req = MA::Statistics::StreamReadLengthHistogramRequest.decode(request)
      response = MA::Statistics::StreamReadLengthHistogramResponse.new
      response.read_length_type = req.read_length_type
      response.bucket_ranges = [MA::Statistics::StreamReadLengthHistogramResponse::BucketRange.new.tap { |b| b.start = 0_u64; b.end_ = 1000_u64 }]
      response.histogram_data = [MA::Statistics::StreamReadLengthHistogramResponse::ReadLengthHistogramData.new.tap { |histogram| histogram.n50 = 12345_f32; histogram.bucket_values = [7_u64] }]
      writer.send_raw(response.encode)
    when "stream_duty_time"
      response = MA::Statistics::StreamDutyTimeResponse.new
      response.bucket_ranges = [MA::Statistics::StreamDutyTimeResponse::BucketRange.new.tap(&.end_=(60_u32))]
      response.channel_states["strand"] = MA::Statistics::StreamDutyTimeResponse::ChannelStateData.new.tap(&.state_times=([75_u64]))
      response.channel_states["pore"] = MA::Statistics::StreamDutyTimeResponse::ChannelStateData.new.tap(&.state_times=([25_u64]))
      response.pore_occupancy = [0.75_f32]
      writer.send_raw(response.encode)
    when "stream_temperature"
      [[35.0, 36.0], [37.0]].each do |temperatures|
        response = MA::Statistics::StreamTemperatureResponse.new
        response.temperatures = temperatures.map do |temperature|
          MA::Statistics::TemperaturePacket.new.tap do |packet|
            packet.minion = MA::Statistics::TemperaturePacket::MinIONTemperature.new.tap(&.heatsink_temperature=(temperature))
          end
        end
        writer.send_raw(response.encode)
      end
    else
      return GRPC::Status.unimplemented
    end
    GRPC::Status.ok
  end

  private def protocol(id)
    MA::Protocol::ProtocolRunInfo.new.tap do |run|
      run.run_id = id
      run.protocol_id = "sequencing"
      run.output_path = "/data/#{id}"
      run.acquisition_run_ids = ["#{id}-cal", "#{id}-seq"]
      run.start_time = Google::Protobuf::Timestamp.new.tap(&.seconds=(100_i64))
      run.end_time = Google::Protobuf::Timestamp.new.tap(&.seconds=(200_i64)) if id == "old"
    end
  end

  private def acquisition(id)
    MA::Acquisition::AcquisitionRunInfo.new.tap do |info|
      info.run_id = id
      info.config_summary = MA::Acquisition::AcquisitionConfigSummary.new.tap(&.basecalling_enabled=(true))
      info.yield_summary = MA::Acquisition::AcquisitionYieldSummary.new.tap do |y|
        y.read_count = id.starts_with?("old") ? 50_i64 : 100_i64
        y.basecalled_pass_bases = id.starts_with?("old") ? 5000_i64 : 10000_i64
      end
      info.end_time = Google::Protobuf::Timestamp.new.tap(&.seconds=(200_i64)) if id.starts_with?("old")
    end
  end
end

def wait_for(span = 8.seconds, & : -> Bool)
  deadline = Time.instant + span
  until yield
    raise "Timed out waiting for fixture" if Time.instant >= deadline
    sleep 0.01.seconds
  end
end

def with_fake_minknow(&)
  listener = TCPServer.new("127.0.0.1", 0)
  port = listener.local_address.port
  listener.close
  calls = [] of String
  peers = %w[manager.Manager instance.Instance device.Device protocol.Protocol acquisition.Acquisition statistics.Statistics notifications.Notifications log.Log].map do |name|
    FakeMinKnow.new("minknow_api.#{name}Service", port, calls)
  end
  server = GRPC::Server.new
  peers.each { |peer| server.handle(peer) }
  server.bind("127.0.0.1:#{port}")
  previous_tls = ENV["MINKNOW_TLS"]?
  previous_local = ENV["MINKNOW_API_USE_LOCAL_TOKEN"]?
  ENV["MINKNOW_TLS"] = "false"
  ENV["MINKNOW_API_USE_LOCAL_TOKEN"] = "false"
  server.start
  store = MinknowTui::Store.new
  options = MinknowTui::Options.new(["--host", "127.0.0.1", "--port", port.to_s])
  api = MinknowTui::Api.new(store, options)
  begin
    yield api, store, peers, calls
  ensure
    api.stop
    server.stop
    previous_tls ? (ENV["MINKNOW_TLS"] = previous_tls) : ENV.delete("MINKNOW_TLS")
    previous_local ? (ENV["MINKNOW_API_USE_LOCAL_TOKEN"] = previous_local) : ENV.delete("MINKNOW_API_USE_LOCAL_TOKEN")
  end
end
