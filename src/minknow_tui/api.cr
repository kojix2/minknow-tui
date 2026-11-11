require "minknow"
require "minknow/src/generated/minknow_api/statistics.pb"
require "minknow/src/generated/minknow_api/statistics.grpc"
require "minknow/src/generated/minknow_api/notifications.pb"
require "minknow/src/generated/minknow_api/notifications.grpc"
require "minknow/src/generated/minknow_api/log.pb"
require "minknow/src/generated/minknow_api/log.grpc"
require "minknow/src/generated/minknow_api/data.grpc"
require "minknow/src/generated/minknow_api/run_until.pb"
require "minknow/src/generated/minknow_api/run_until.grpc"
require "./model"
require "./options"

module MinknowTui
  # All protobuf normalization lives here, outside the view and domain models.
  module Decode
    extend self

    def time(value : Google::Protobuf::Timestamp?) : Time?
      value.try { |timestamp| Time.unix(timestamp.seconds) + timestamp.nanos.nanoseconds }
    end

    def name(value : Proto::OpenEnum(T), prefix = "") : String forall T
      return "Unknown(#{value.raw})" unless value.known?
      value.to_s.sub(/^#{prefix}/, "").split('_').map(&.capitalize).join(' ')
    end

    def run(value : MinknowApi::Protocol::ProtocolRunInfo) : Run
      r = Run.new(value.run_id)
      r.sample = MinknowTui.text(value.user_info.try(&.sample_id).try(&.value) || "")
      r.experiment = MinknowTui.text(value.user_info.try(&.protocol_group_id).try(&.value) || "")
      r.protocol = MinknowTui.text(value.protocol_id)
      r.kit = MinknowTui.text(value.user_info.try(&.kit_info).try(&.sequencing_kit) || "")
      r.state = name(value.state, "PROTOCOL_")
      phase = value.phase_history.max_by? { |snapshot| time(snapshot.timestamp).try(&.to_unix_ms) || 0_i64 }
      r.phase = name(phase.try(&.phase) || value.phase, "PHASE_")
      r.output = MinknowTui.text(value.reported_output_path || value.output_path)
      r.started_at = time(value.start_time)
      r.ended_at = time(value.end_time)
      r.acquisitions = value.acquisition_run_ids.dup
      r
    end

    def flow_cell(p : Position, value : MinknowApi::Device::GetFlowCellInfoResponse)
      if p.flow_cell != value.flow_cell_id || p.has_flow_cell != value.has_flow_cell
        p.pore_states.clear
        p.state_styles.clear
        p.pore_updated_at = nil
      end
      p.has_flow_cell = value.has_flow_cell
      p.flow_cell = MinknowTui.text(value.flow_cell_id)
      p.product = MinknowTui.text(value.product_code)
      p.channels = value.channel_count
    end

    def device(p : Position, value : MinknowApi::Device::GetDeviceInfoResponse)
      p.device = MinknowTui.text(value.device_id)
      p.device_type = name(value.device_type)
      p.simulated = value.is_simulated
    end

    def summary(m : Metrics, value : MinknowApi::Acquisition::AcquisitionYieldSummary)
      m.reads = value.read_count
      m.pass_calls = value.basecalled_pass_read_count
      m.fail_calls = value.basecalled_fail_read_count
      m.pass_bases = value.basecalled_pass_bases
      m.fail_bases = value.basecalled_fail_bases
      m.estimated_bases = value.estimated_selected_bases
      m.processed = (value.fraction_basecalled + value.fraction_skipped).to_f64.clamp(0.0, 1.0)
      if m.basecalling_enabled == false
        m.pass_calls = m.fail_calls = m.pass_bases = m.fail_bases = nil
        m.n50 = m.processed = nil
      end
      m.updated_at = Time.utc
    end

    def styles(info : MinknowApi::Acquisition::ChannelStateInfo?) : Hash(String, StateStyle)
      result = {} of String => StateStyle
      info.try(&.groups).try &.each do |group|
        group.states.each do |state|
          style = state.style
          group_name = group.name.empty? ? state.name : group.name
          result[state.name] = StateStyle.new(MinknowTui.text(style.try(&.label) || state.name).gsub(/[{}]/, ""),
            MinknowTui.text(style.try(&.description) || ""), style.try(&.colour) || "",
            MinknowTui.text(group_name).gsub(/[{}]/, ""), state.global_order, group.style.try(&.colour) || "")
        end
      end
      result
    end

    def n50(m : Metrics, called : Number, estimated : Number)
      m.n50 = called > 0 && m.basecalling_enabled != false ? called.to_f64 : nil
      m.estimated_n50 = estimated > 0 ? estimated.to_f64 : nil
    end

    def temperature(value : MinknowApi::Device::GetTemperatureResponse) : Tuple(String, Float64)?
      if t = value.minion
        t.heatsink_temperature.try { |v| {"Heatsink", v.value.to_f64} }
      elsif t = value.promethion
        t.flowcell_temperature.try { |v| {"Flow cell", v.value.to_f64} }
      elsif t = value.pebble
        t.asic_temperature.try { |v| {"ASIC", v.value.to_f64} }
      end
    end

    def temperature(value : MinknowApi::Statistics::TemperaturePacket) : Tuple(String, Float64)?
      if t = value.minion
        {"Heatsink", t.heatsink_temperature}
      elsif t = value.promethion
        {"Flow cell", t.flowcell_temperature}
      elsif t = value.pebble
        {"ASIC", t.asic_temperature}
      end
    end
  end

  class Api
    alias MA = MinknowApi
    getter store : Store
    @root = Scope.new
    @positions = {} of String => Tuple(Position, Scope, GRPC::Channel)
    @details = Scope.new
    @logs = Scope.new
    @selected_position : String? = nil
    @selection_generation = UInt64::MAX
    @selected_tab = -1
    @config : Minknow::ConnectionConfig
    @manager_channel : GRPC::Channel? = nil

    def initialize(@store, @options : Options)
      tls = !{"0", "false", "no"}.includes?((ENV["MINKNOW_TLS"]? || "true").downcase)
      @config = Minknow::ConnectionConfig.new(host: @options.host, port: @options.port, tls: tls, auto_local_auth: false)
      store.endpoint = @config.authority
    end

    def start
      spawn do
        delay = 1
        while @root.active?
          begin
            connect
            break
          rescue ex
            @store.connection = failure(ex)
            @store.changed
            @root.pause(delay.seconds)
            delay = Math.min(delay * 2, 30)
          end
        end
      end
      spawn do
        while @root.active?
          selection_changed
          @root.pause(0.1.seconds)
        end
      end
    end

    def stop
      @root.stop
      @details.stop
      @logs.stop
      @positions.each_value { |(_, scope, channel)| scope.stop; channel.close }
      @positions.clear
      @manager_channel.try(&.close)
    end

    private def channel(config : Minknow::ConnectionConfig) : GRPC::Channel
      GRPC::Channel.new(config.address, tls_context: config.tls_context,
        endpoint_config: GRPC::EndpointConfig.new(connect_timeout: 5.seconds))
    end

    private def context : GRPC::ClientContext
      GRPC::ClientContext.new(metadata: @config.effective_metadata, deadline: 5.seconds)
    end

    private def stream_context : GRPC::ClientContext
      GRPC::ClientContext.new(metadata: @config.effective_metadata)
    end

    # Resolve local authentication explicitly with a deadline. The shard's
    # automatic token lookup currently has no deadline of its own.
    private def authenticate(client : MA::Manager::ManagerService::Client)
      enabled = !{"0", "false", "no"}.includes?((ENV["MINKNOW_API_USE_LOCAL_TOKEN"]? || "true").downcase)
      return unless @config.localhost? && enabled && @config.authentication_token.nil?
      response = client.local_authentication_token_path(MA::Manager::LocalAuthenticationTokenPathRequest.new, context)
      return unless @root.active? && File.file?(response.path)
      token = JSON.parse(File.read(response.path))["token"]?.try(&.as_s?)
      @config = Minknow::ConnectionConfig.new(host: @config.host, port: @config.port,
        tls: @config.tls?, authentication_token: token, auto_local_auth: false)
    rescue GRPC::StatusError
      # Guest access and explicit client certificates can still work.
    rescue IO::Error | JSON::ParseException
      @store.event("TUI", "WARN", "Local authentication token could not be read")
    end

    private def open_manager
      ch = channel(@config)
      client = MA::Manager::ManagerService::Client.new(ch)
      begin
        version = client.get_version_info(MA::Manager::GetVersionInfoRequest.new, context)
      rescue ex
        ch.close
        if !@options.explicit_port? && @config.port == 9501 && !@config.client_certificate_configured? && refused?(ex)
          @config = @config.with_port(9502)
          @store.endpoint = @config.authority
          @store.event("TUI", "INFO", "Manager port 9501 refused the connection; trying TLS port 9502")
        end
        raise ex
      end
      {ch, client, version}
    end

    private def connect
      ch, client, version = open_manager
      unless @root.active?
        ch.close
        return
      end
      @manager_channel = ch
      @store.version = version.minknow.try(&.full) || "Unknown"
      @store.distribution = version.distribution_version
      authenticate(client)
      return unless @root.active?
      @store.connection = "Connected"
      @store.event("TUI", "INFO", "Connected to #{@store.endpoint}")
      if host = attempt(@root, @store.capabilities, "describe_host") { client.describe_host(MA::Manager::DescribeHostRequest.new, context) }
        @store.host_description = MinknowTui.text("#{host.description} #{host.serial}")
      end
      watch_positions(client)
      poll(@root, @store.capabilities, "manager_health", 15.seconds) do
        client.get_version_info(MA::Manager::GetVersionInfoRequest.new, context)
        if @root.active?
          @store.connection = "Connected"
          @store.changed
        end
      end
      poll(@root, @store.capabilities, "manager_disk", 15.seconds) do
        value = client.get_disk_space_info(MA::Manager::GetDiskSpaceInfoRequest.new, context)
        if @root.active?
          @store.disk = value.filesystem_disk_space_info.map { |disk| "#{MinknowTui.text(disk.filesystem_id)}: #{MinknowTui.number(disk.bytes_available, "B")} free / #{MinknowTui.number(disk.bytes_capacity, "B")}#{disk.recommend_alert ? " [LOW SPACE]" : ""}" }.join("\n")
          @store.disk_updated_at = Time.utc
        end
      end
      notifications = MA::Notifications::NotificationsService::Client.new(ch)
      watch(@root, @store.capabilities, "notifications") do
        request = MA::Notifications::StreamNotificationsRequest.new
        request.include_updates_for_existing = true
        consume(@root, notifications.stream_notifications(request, stream_context)) do |response|
          response.notifications.each do |notification|
            next unless content = notification.content
            @store.event("Host", Decode.name(content.type_, "NOTIFICATION_TYPE_"), content.notification_text,
              Decode.time(notification.created_at) || Time.utc, "notification:#{notification.id}:#{Decode.time(notification.last_updated_at).try(&.to_unix_ms)}")
          end
        end
      end
    end

    private def watch_positions(client)
      poll(@root, @store.capabilities, "positions", 5.seconds) do
        if @store.capabilities["watch_positions"]? == "Unsupported" || @store.positions.empty?
          values = [] of MA::Manager::FlowCellPosition
          consume(@root, client.flow_cell_positions(MA::Manager::FlowCellPositionsRequest.new, context)) { |response| values.concat response.positions }
          if @root.active?
            values.each { |position| update_position(position) }
            (@store.positions.keys - values.map(&.name)).each { |id| remove_position(id) }
          end
        end
      end
      watch(@root, @store.capabilities, "watch_positions") do
        consume(@root, client.watch_flow_cell_positions(MA::Manager::WatchFlowCellPositionsRequest.new, stream_context)) do |response|
          (response.additions + response.changes).each { |position| update_position(position) }
          response.removals.each { |id| remove_position(id) }
        end
      end
    end

    def self.refused?(ex : Exception) : Bool
      current : Exception? = ex
      while cause = current
        return true if cause.is_a?(Socket::ConnectError) && cause.message.to_s.downcase.includes?("refused")
        current = cause.cause
      end
      false
    end

    private def refused?(ex : Exception) : Bool
      self.class.refused?(ex)
    end

    def self.failure(ex : Exception) : String
      if ex.is_a?(GRPC::StatusError)
        case ex.code
        when GRPC::StatusCode::UNIMPLEMENTED                                        then return "Unsupported"
        when GRPC::StatusCode::UNAUTHENTICATED, GRPC::StatusCode::PERMISSION_DENIED then return "Authentication required"
        when GRPC::StatusCode::FAILED_PRECONDITION                                  then return "Not applicable / no active run"
        when GRPC::StatusCode::NOT_FOUND                                            then return "Not found"
        end
      end
      "Reconnecting (#{ex.class})"
    end

    private def failure(ex : Exception) : String
      self.class.failure(ex)
    end

    # ServerStream#each does not raise for trailer errors in this transport.
    def self.check_status(status : GRPC::Status)
      raise GRPC::StatusError.new(status) unless status.ok?
    end

    private def consume(scope : Scope, stream : GRPC::ServerStream(T), & : T ->) forall T
      id = scope.register { stream.cancel }
      begin
        stream.each { |value| yield value if scope.active? }
        self.class.check_status(stream.status) if scope.active?
      ensure
        scope.unregister(id)
        stream.cancel
      end
    end

    private def attempt(scope : Scope, caps : Hash(String, String), key : String, & : -> T) : T? forall T
      return unless scope.active?
      return if caps[key]? == "Unsupported"
      value = yield
      return unless scope.active?
      caps[key] = "Available"
      @store.changed
      value
    rescue ex
      if scope.active?
        previous = caps[key]?
        caps[key] = failure(ex)
        @store.connection = caps[key] if key == "manager_health"
        if previous != caps[key] && caps[key] != "Not applicable / no active run"
          @store.event("TUI", "WARN", "#{key}: #{caps[key]}")
        end
      end
      nil
    end

    private def poll(scope : Scope, caps : Hash(String, String), key : String, interval : Time::Span, &block : ->)
      spawn do
        while scope.active? && caps[key]? != "Unsupported"
          attempt(scope, caps, key) { block.call }
          scope.pause(interval)
        end
      end
    end

    private def watch(scope : Scope, caps : Hash(String, String), key : String, finite = false, &block : ->)
      spawn do
        delay = 1
        while scope.active? && caps[key]? != "Unsupported"
          started = Time.instant
          attempt(scope, caps, key) { block.call }
          # Historical streams terminate successfully; do not request them again.
          break if finite && caps[key]? == "Available"
          delay = 1 if Time.instant - started > 30.seconds
          scope.pause(delay.seconds)
          delay = Math.min(delay * 2, 30)
        end
      end
    end

    private def update_position(raw : MA::Manager::FlowCellPosition)
      p = @store.positions[raw.name] ||= Position.new(raw.name)
      p.software = Decode.name(raw.state, "STATE_")
      p.protocol_state = Decode.name(raw.protocol_state, "PROTOCOL_")
      p.error = MinknowTui.text(raw.error_info)
      p.simulated = raw.is_simulated
      p.device_type = Decode.name(raw.device_type)
      port = raw.rpc_ports.try(&.secure).try(&.to_i)
      if (!port || port == 0) && !@config.client_certificate_configured?
        port = raw.rpc_ports.try(&.secure_grpc_web).try(&.to_i)
      end
      port = nil if port == 0
      if old = @positions[raw.name]?
        if old[0].port != port
          old[1].stop
          old[2].close
          @positions.delete(raw.name)
          p.capabilities.clear
          p.current_run = nil
          p.current_acquisition = nil
          p.runs.clear
          p.live = Metrics.new
          p.pore_states.clear
          p.pore_updated_at = nil
          p.connected = false
          @store.reset_detail if @store.position_id == raw.name
        end
      end
      p.port = port
      @store.changed
      return if !port || @positions.has_key?(raw.name)
      scope = Scope.new
      ch = channel(@config.with_port(port))
      @positions[raw.name] = {p, scope, ch}
      start_position(p, scope, ch)
      # A restarted position may have changed ports while it was selected.
      @selected_position = nil if @store.position_id == raw.name
    end

    private def remove_position(id : String)
      if old = @positions.delete(id)
        old[1].stop
        old[2].close
      end
      @store.positions.delete(id)
      @store.select_position(nil) if @store.position_id == id
      @store.event("TUI", "INFO", "Position removed: #{MinknowTui.text(id)}")
    end

    private def apply_run(p : Position, raw : MA::Protocol::ProtocolRunInfo, current = false)
      return if raw.run_id.empty?
      r = Decode.run(raw)
      p.runs[r.id] = r
      if current
        p.current_run = r.ended_at ? nil : r.id
        p.current_acquisition = nil if r.ended_at
      end
      @store.sync_selection if @store.position_id == p.name
      @store.changed
    end

    private def apply_acquisition(p : Position, raw : MA::Acquisition::AcquisitionRunInfo)
      return if raw.run_id.empty?
      id = raw.end_time ? nil : raw.run_id
      if id != p.current_acquisition
        p.live = Metrics.new
        p.pore_states.clear
        p.pore_updated_at = nil
      end
      p.current_acquisition = id
      p.live.basecalling_enabled = raw.config_summary.try(&.basecalling_enabled)
      raw.yield_summary.try { |summary| Decode.summary(p.live, summary) }
      @store.sync_selection if @store.position_id == p.name
      @store.changed
    end

    private def start_position(p : Position, scope : Scope, ch : GRPC::Channel)
      instance = MA::Instance::InstanceService::Client.new(ch)
      protocol = MA::Protocol::ProtocolService::Client.new(ch)
      acquisition = MA::Acquisition::AcquisitionService::Client.new(ch)
      device = MA::Device::DeviceService::Client.new(ch)
      watch(scope, p.capabilities, "activity") do
        consume(scope, instance.stream_instance_activity(MA::Instance::StreamInstanceActivityRequest.new, stream_context)) do |response|
          response.device_info.try(&.device_info).try { |v| Decode.device(p, v) }
          response.flow_cell_info.try { |v| Decode.flow_cell(p, v) }
          response.protocol_run_info.try { |v| apply_run(p, v, true) }
          response.acquisition_run_info.try { |v| apply_acquisition(p, v) }
          response.yield_summary.try { |v| Decode.summary(p.live, v) }
          response.n50.try { |v| Decode.n50(p.live, v.n50, v.estimated_n50) }
          response.flow_cell_health.try { |v| p.live.channel_states = v.channel_state_percentages.transform_values(&.to_f64) }
          p.updated_at = Time.utc
          p.connected = true
          p.capabilities["activity"] = "Available"
          @store.changed
        end
      end
      start_reconciliation(p, scope, protocol, acquisition, device)
      start_history(p, scope, protocol)
      poll(scope, p.capabilities, "temperature", 5.seconds) do
        value = device.get_temperature(MA::Device::GetTemperatureRequest.new, context)
        if scope.active? && (t = Decode.temperature(value))
          p.live.temperature_label, p.live.temperature = t
          @store.changed
        end
      end
      # Position-level disk RPC replaces deprecated Manager disk RPC where available.
      poll(scope, p.capabilities, "disk", 15.seconds) do
        value = instance.get_disk_space_info(MA::Instance::GetDiskSpaceInfoRequest.new, context)
        if scope.active?
          @store.disk = value.filesystem_disk_space_info.map { |disk| "#{MinknowTui.text(disk.filesystem_id)}: #{MinknowTui.number(disk.bytes_available, "B")} free / #{MinknowTui.number(disk.bytes_capacity, "B")}#{disk.recommend_alert ? " [LOW SPACE]" : ""}" }.join("\n")
          @store.disk_updated_at = Time.utc
        end
      end
    end

    private def start_reconciliation(p, scope, protocol, acquisition, device)
      last_reconcile = Time.instant - 15.seconds
      poll(scope, p.capabilities, "reconcile", 5.seconds) do
        # Each request has its own fresh deadline, even after hours of runtime.
        if p.capabilities["activity"]? == "Unsupported" || Time.instant - last_reconcile >= 15.seconds
          last_reconcile = Time.instant
          raw_run = attempt(scope, p.capabilities, "current_protocol") { protocol.get_current_protocol_run(MA::Protocol::GetCurrentProtocolRunRequest.new, context) }
          if raw_run
            apply_run(p, raw_run, true)
          elsif p.capabilities["current_protocol"]? == "Not applicable / no active run"
            p.current_run = nil
          end
          raw_acq = attempt(scope, p.capabilities, "current_acquisition") { acquisition.get_current_acquisition_run(MA::Acquisition::GetCurrentAcquisitionRunRequest.new, context) }
          if raw_acq
            apply_acquisition(p, raw_acq)
          elsif p.capabilities["current_acquisition"]? == "Not applicable / no active run"
            p.current_acquisition = nil
          end
          attempt(scope, p.capabilities, "flow_cell") do
            value = device.get_flow_cell_info(MA::Device::GetFlowCellInfoRequest.new, context)
            Decode.flow_cell(p, value) if scope.active?
          end
          attempt(scope, p.capabilities, "device") do
            value = device.get_device_info(MA::Device::GetDeviceInfoRequest.new, context)
            Decode.device(p, value) if scope.active?
          end
          next unless scope.active?
          p.connected = p.capabilities["flow_cell"]? == "Available"
          p.updated_at = Time.utc if p.connected?
          @store.sync_selection if @store.position_id == p.name
        end
      end
    end

    private def start_history(p, scope, protocol)
      poll(scope, p.capabilities, "history", 15.seconds) do
        response = protocol.list_protocol_runs(MA::Protocol::ListProtocolRunsRequest.new, context)
        next unless scope.active?
        (p.runs.keys - response.run_ids).each { |id| p.runs.delete(id) unless id == p.current_run }
        response.run_ids.each do |id|
          break unless scope.active?
          next if p.runs[id]?.try(&.ended_at)
          request = MA::Protocol::GetRunInfoRequest.new
          request.run_id = id
          value = attempt(scope, p.capabilities, "run_info") { protocol.get_run_info(request, context) }
          apply_run(p, value) if value && scope.active?
        end
        @store.sync_selection if @store.position_id == p.name
      end
    end

    private def selection_changed
      if @selected_position != @store.position_id
        @logs.stop
        @logs = Scope.new
        @selected_position = @store.position_id
        if entry = @positions[@store.position_id]?
          p, _, ch = entry
          scope = @logs
          client = MA::Log::LogService::Client.new(ch)
          watch(scope, p.capabilities, "user_messages") do
            request = MA::Log::GetUserMessagesRequest.new
            request.include_old_messages = true
            consume(scope, client.get_user_messages(request, stream_context)) do |message|
              @store.event(p.name, Decode.name(message.severity, "MESSAGE_SEVERITY_"), message.user_message,
                Decode.time(message.time) || Time.utc)
            end
          end
        end
      end
      return if @selection_generation == @store.generation && @selected_tab == @store.tab
      @details.stop
      @details = Scope.new
      @selection_generation = @store.generation
      @selected_tab = @store.tab
      if entry = @positions[@store.position_id]?
        if @store.tab == 4
          start_channels(entry[0], @details, entry[2])
        elsif @store.acquisition_id
          start_detail(entry[0], @details, entry[2])
        end
      end
    end

    private def start_channels(p : Position, scope : Scope, ch : GRPC::Channel)
      client = MA::Data::DataService::Client.new(ch)
      load_channel_styles(p, scope, ch)
      watch(scope, p.capabilities, "channels") do
        while scope.active? && (p.channels == 0 || p.has_flow_cell == false)
          p.capabilities["channels"] = p.has_flow_cell == false ? "No flow cell" : "Waiting for channel count"
          @store.changed
          scope.pause(0.5.seconds)
        end
        next unless scope.active?
        request = MA::Data::GetChannelStatesRequest.new
        request.first_channel = 1_u32
        request.last_channel = p.channels
        request.wait_for_processing = true
        p.capabilities["channels"] = "Waiting for acquisition / channel snapshot"
        @store.changed
        first = true
        consume(scope, client.get_channel_states(request, stream_context)) do |response|
          unless response.channel_states.empty?
            p.pore_states.clear if first
            first = false
            response.channel_states.each do |state|
              name = state.state_case.state_name? ? MinknowTui.text(state.state_name) : "Unknown(#{state.state_id})"
              p.update_channel(state.channel.to_i, ChannelState.new(name, state.config.try(&.well) || 0_u32,
                state.acquisition_raw_index, state.analysis_raw_index))
            end
            p.pore_updated_at = Time.utc
          end
          p.capabilities["channels"] = "Available"
          @store.changed
        end
      end
    end

    private def load_channel_styles(p : Position, scope : Scope, ch : GRPC::Channel)
      if acquisition_id = p.current_acquisition
        acquisition = MA::Acquisition::AcquisitionService::Client.new(ch)
        spawn do
          request = MA::Acquisition::GetAcquisitionRunInfoRequest.new
          request.run_id = acquisition_id
          attempt(scope, p.capabilities, "channel_styles") do
            value = acquisition.get_acquisition_info(request, context)
            p.state_styles = Decode.styles(value.config_summary.try(&.channel_state_info)) if scope.active? && p.current_acquisition == acquisition_id
          end
        end
      end
    end

    private def start_detail(p : Position, scope : Scope, ch : GRPC::Channel)
      id = @store.acquisition_id
      return unless id
      metrics = @store.detail
      statistics = MA::Statistics::StatisticsService::Client.new(ch)
      caps = scope.capabilities
      # UNIMPLEMENTED is endpoint capability, not a per-run failure. Cache it
      # across tab/acquisition changes, but reset on a new position connection.
      p.capabilities.each do |key, value|
        caps[key.sub("detail.", "")] = value if key.starts_with?("detail.") && value == "Unsupported"
      end
      poll_summary(p, scope, ch, id, metrics, caps, @store.generation)
      start_n50(scope, caps, statistics, id, metrics) if {0, 2}.includes?(@store.tab)
      start_tab_streams(scope, caps, ch, statistics, id, metrics)
      publish_detail_capabilities(p, scope, caps, @store.generation, @store.tab)
    end

    private def poll_summary(p, scope, ch, id, metrics, caps, generation)
      acquisition = MA::Acquisition::AcquisitionService::Client.new(ch)
      poll(scope, caps, "summary", 5.seconds) do
        request = MA::Acquisition::GetAcquisitionRunInfoRequest.new
        request.run_id = id
        value = acquisition.get_acquisition_info(request, context)
        if scope.active? && @store.current?(generation)
          if config = value.config_summary
            metrics.basecalling_enabled = config.basecalling_enabled
            metrics.sample_rate = config.sample_rate > 0 ? config.sample_rate : nil
            metrics.state_styles = Decode.styles(config.channel_state_info)
            model = config.basecalling_model_names.try(&.simplex_model) || ""
            model = config.basecalling_config_filename if model.empty?
            model = config.basecalling_model_version if model.empty?
            metrics.basecall_model = MinknowTui.text(model)
            metrics.alignment_reference = MinknowTui.text(config.alignment_reference_files.join(", "))
            metrics.alignment_bed = MinknowTui.text(config.alignment_bed_file)
            metrics.barcoding_kits = MinknowTui.text(config.barcoding_kits.join(", "))
            p.state_styles = metrics.state_styles if id == p.current_acquisition
          end
          value.yield_summary.try { |v| Decode.summary(metrics, v) }
          if id == p.current_acquisition
            metrics.n50 ||= p.live.n50
            metrics.estimated_n50 ||= p.live.estimated_n50
          end
        end
      end
    end

    private def start_tab_streams(scope, caps, ch, statistics, id, metrics)
      case @store.tab
      when 0 then watch_remaining(scope, caps, ch, id, metrics)
      when 1 then watch_yield(scope, caps, statistics, id, metrics)
      when 2 then watch_quality(scope, caps, statistics, id, metrics)
      when 3
        watch_temperature(scope, caps, statistics, id, metrics)
        watch_bias(scope, caps, statistics, id, metrics)
      when 5 then watch_duty(scope, caps, statistics, id, metrics)
      end
    end

    private def publish_detail_capabilities(p, scope, caps, generation, tab)
      # Keep capability diagnostics up to date while streams are active.
      spawn do
        while scope.active? && @store.current?(generation) && @store.tab == tab
          caps.each { |key, value| p.capabilities["detail.#{key}"] = value }
          @store.changed
          scope.pause(0.5.seconds)
        end
      end
    end

    private def start_n50(scope, caps, statistics, id, metrics)
      n50_fallback_started = false
      poll(scope, caps, "n50", 15.seconds) do
        request = MA::Statistics::ReadLengthN50Request.new
        request.acquisition_run_id = id
        response = attempt(scope, caps, "read_length_n50") { statistics.read_length_n50(request, context) }
        if scope.active?
          response.try(&.n50_data).try { |v| Decode.n50(metrics, v.basecalled_n50, v.estimated_n50) }
          if caps["read_length_n50"]? == "Unsupported" && @store.tab == 0 && !n50_fallback_started
            n50_fallback_started = true
            histogram(scope, caps, statistics, id, metrics)
          end
        end
      end
    end

    private def watch_yield(scope, caps, statistics, id, metrics)
      watch(scope, caps, "yield", finite: true) do
        request = MA::Statistics::StreamAcquisitionOutputRequest.new
        request.acquisition_run_id = id
        request.data_selection = MA::Statistics::DataSelection.new.tap(&.step=(60_u64))
        consume(scope, statistics.stream_acquisition_output(request, stream_context)) do |response|
          response.snapshots.each do |group|
            group.snapshots.each do |snapshot|
              next unless y = snapshot.yield_summary
              metrics.pass.put(snapshot.seconds, y.basecalled_pass_bases)
              metrics.fail.put(snapshot.seconds, y.basecalled_fail_bases)
              metrics.estimated.put(snapshot.seconds, y.estimated_selected_bases)
            end
          end
          @store.changed
        end
      end
    end

    private def watch_quality(scope, caps, statistics, id, metrics)
      histogram(scope, caps, statistics, id, metrics)
      spawn do
        while scope.active? && metrics.basecalling_enabled.nil?
          scope.pause(0.1.seconds)
        end
        if scope.active?
          if metrics.basecalling_enabled
            watch_qscore(scope, caps, statistics, id, metrics)
            watch_qscore_time(scope, caps, statistics, id, metrics)
          else
            caps["qscore_histogram"] = "Disabled (basecalling off)"
            caps["qscore_time"] = "Disabled (basecalling off)"
          end
        end
      end
      watch_duty(scope, caps, statistics, id, metrics)
    end

    private def watch_duty(scope, caps, statistics, id, metrics)
      watch(scope, caps, "duty_time", finite: true) do
        request = MA::Statistics::StreamDutyTimeRequest.new
        request.acquisition_run_id = id
        request.data_selection = MA::Statistics::DataSelection.new.tap(&.step=(60_u64))
        consume(scope, statistics.stream_duty_time(request, stream_context)) do |response|
          response.bucket_ranges.each_with_index do |range, index|
            values = response.channel_states.transform_values { |state| state.state_times[index]?.try(&.to_f64) || 0.0 }
            metrics.put_duty(DutyBucket.new(range.start.to_i, range.end_.to_i, values))
            if index == response.bucket_ranges.size - 1
              total = values.values.sum
              metrics.channel_states = values.transform_values { |v| total > 0 ? v * 100 / total : 0.0 }
              metrics.occupancy = response.pore_occupancy[index]?.try(&.to_f64)
            end
          end
          @store.changed
        end
      end
    end

    private def watch_qscore(scope, caps, statistics, id, metrics)
      watch(scope, caps, "qscore_histogram", finite: true) do
        request = MA::Statistics::StreamQScoreHistogramRequest.new
        request.acquisition_run_id = id
        request.poll_time_seconds = 60_u32
        consume(scope, statistics.stream_q_score_histogram(request, stream_context)) do |response|
          data = response.histogram_data.find do |item|
            item.filtering.any? { |filter| filter.read_type.raw == 0 && filter.call_status.raw == 0 }
          end || response.histogram_data.find do |item|
            item.filtering.any? { |filter| filter.read_type.raw == 0 }
          end || response.histogram_data.first?
          if data
            metrics.qscore_histogram = response.bucket_ranges.map_with_index do |range, index|
              HistogramBin.new(range.start.to_f64, range.end_.to_f64, (data.bucket_values[index]? || 0_u64).to_f64)
            end
            metrics.qscore_modal = data.modal_q_score.to_f64
          end
          @store.changed
        end
      end
    end

    private def watch_qscore_time(scope, caps, statistics, id, metrics)
      watch(scope, caps, "qscore_time", finite: true) do
        request = MA::Statistics::StreamBoxplotRequest.new
        request.acquisition_run_id = id
        request.dataset_width = 60_u32
        consume(scope, statistics.stream_basecall_boxplots(request, stream_context)) do |response|
          points = response.datasets.each_with_index.compact_map do |dataset, index|
            {index * 3600.0, dataset.q50.to_f64} if dataset.count > 0
          end.to_a
          metrics.qscore_medians.replace(points)
          @store.changed
        end
      end
    end

    private def watch_bias(scope, caps, statistics, id, metrics)
      watch(scope, caps, "bias_voltage", finite: true) do
        request = MA::Statistics::StreamBiasVoltagesRequest.new
        request.acquisition_run_id = id
        consume(scope, statistics.stream_bias_voltages(request, stream_context)) do |response|
          response.bias_voltages.each { |packet| metrics.bias_voltages.put(packet.time_seconds, packet.bias_voltage) }
          @store.changed
        end
      end
    end

    private def watch_remaining(scope, caps, ch, id, metrics)
      client = MA::RunUntil::RunUntilService::Client.new(ch)
      watch(scope, caps, "remaining", finite: true) do
        request = MA::RunUntil::StreamUpdatesRequest.new
        request.acquisition_run_id = id
        consume(scope, client.stream_updates(request, stream_context)) do |response|
          estimates = response.update.try(&.estimated_time_remaining_update).try(&.stop_estimates).try(&.estimated_times)
          next unless estimates
          times = estimates.values.compact_map { |estimate| Decode.time(estimate.estimated.try(&.min_time)) }
          metrics.remaining_until = times.min?
          metrics.remaining_estimated = estimates.keys != ["runtime"] || estimates.values.any? do |estimate|
            value = estimate.estimated
            value.nil? || value.min_time != value.max_time
          end
          @store.changed
        end
      end
    end

    private def watch_temperature(scope, caps, statistics, id, metrics)
      watch(scope, caps, "temperature_history", finite: true) do
        request = MA::Statistics::StreamTemperatureRequest.new
        request.acquisition_run_id = id
        index = 0
        consume(scope, statistics.stream_temperature(request, stream_context)) do |response|
          # API temperature buckets are implicit one-minute intervals and
          # initial history is followed by incremental packets.
          response.temperatures.each do |packet|
            if t = Decode.temperature(packet)
              metrics.temperature_label, metrics.temperature = t
              metrics.temperatures.put(index * 60, t[1])
            end
            index += 1
          end
          @store.changed
        end
      end
    end

    private def apply_histogram(metrics, response)
      metrics.histogram_unit = case response.read_length_type.raw
                               when 2 then "basecalled bp"
                               when 1 then "estimated bp"
                               when 0 then "MinKNOW events"
                               else        Decode.name(response.read_length_type)
                               end
      if data = response.histogram_data.first?
        metrics.histogram = response.bucket_ranges.map_with_index do |bucket, index|
          HistogramBin.new(bucket.start.to_f64, bucket.end_.to_f64, (data.bucket_values[index]? || 0_u64).to_f64)
        end
        if response.read_length_type.to_s == "BasecalledBases"
          metrics.n50 = data.n50 > 0 ? data.n50.to_f64 : nil
        elsif response.read_length_type.to_s == "EstimatedBases"
          metrics.estimated_n50 = data.n50 > 0 ? data.n50.to_f64 : nil
        end
      end
    end

    private def histogram(scope, caps, client, id, metrics)
      watch(scope, caps, "read_lengths", finite: true) do
        types = attempt(scope, caps, "read_length_types") { client.get_read_length_types(MA::Statistics::GetReadLengthTypesRequest.new.tap(&.acquisition_run_id=(id)), context) }
        available = types.try(&.available_types) || [] of Proto::OpenEnum(MA::Statistics::ReadLengthType)
        if caps["read_length_types"]? == "Unsupported"
          available = [2, 1, 0].map { |raw| Proto::OpenEnum(MA::Statistics::ReadLengthType).new(raw) }
        end
        available = available.sort_by { |kind| kind.raw == 2 ? 0 : kind.raw == 1 ? 1 : 2 }
        last_error : GRPC::StatusError? = nil
        completed = false
        available.each do |type|
          break unless scope.active?
          request = MA::Statistics::StreamReadLengthHistogramRequest.new
          request.acquisition_run_id = id
          request.read_length_type = type
          request.poll_time_seconds = 60_u32
          request.data_selection = MA::Statistics::DataSelection.new.tap(&.step=(1000_u64))
          begin
            consume(scope, client.stream_read_length_histogram(request, stream_context)) do |response|
              caps["read_lengths"] = "Available"
              apply_histogram(metrics, response)
              @store.changed
            end
            completed = true
            break
          rescue ex : GRPC::StatusError
            unless {GRPC::StatusCode::FAILED_PRECONDITION, GRPC::StatusCode::INVALID_ARGUMENT}.includes?(ex.code)
              raise ex
            end
            last_error = ex
          end
        end
        if !completed && scope.active?
          raise(last_error || GRPC::StatusError.new(GRPC::StatusCode::FAILED_PRECONDITION, "No read length data yet"))
        end
      end
    end
  end
end
