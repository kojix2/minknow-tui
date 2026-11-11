require "./model"

module MinknowTui
  class Demo
    @scope = Scope.new
    @tick = 0
    @generation = UInt64::MAX
    @tab = -1

    def initialize(@store : Store)
      @store.endpoint = "demo:9501"
      @store.version = "6.10.4 (demo)"
      @store.distribution = "Demo — no MinKNOW connection"
      @store.host_description = "Simulated GridION / DEMO001"
      @store.connection = "Connected [DEMO]"
      @store.disk = "demo-data: 820 GB free / 2.00 TB"
      @store.disk_updated_at = Time.utc
      ["X1", "X2", "X3", "X4"].each_with_index do |name, index|
        p = Position.new(name)
        p.software = index == 3 ? "Hardware Error" : "Running"
        p.protocol_state = "Idle"
        p.error = index == 3 ? "Simulated hardware communication error" : ""
        p.has_flow_cell = index < 2
        p.flow_cell = index < 2 ? "ABC1234#{index}" : ""
        p.product = "FLO-MIN114"
        p.device = "DEMO-#{name}"
        p.device_type, p.channels = index == 1 ? {"PromethION", 3000_u32} : {"MinION", 512_u32}
        p.simulated = true
        p.port = 8000 + index
        p.connected = index != 3
        p.live.temperature = 35.1
        p.live.temperature_label = "Heatsink"
        3.times do |j|
          run = Run.new("demo-#{name}-protocol-#{j}")
          run.sample = j == 0 ? "sample-A" : "sample-#{j + 1}"
          run.experiment = "experiment-01"
          run.protocol = "sequencing/sequencing_MIN114"
          run.kit = "SQK-LSK114"
          started_at = Time.utc - (j * 24 + 2).hours
          run.started_at = started_at
          run.ended_at = j > 0 || index != 0 ? started_at + 1.hour : nil
          run.state = run.ended_at ? "Completed" : "Running"
          run.phase = run.ended_at ? "Unknown" : "Sequencing"
          run.output = "/data/experiment-01/#{run.sample}"
          run.acquisitions = ["#{run.id}-calibration", "#{run.id}-sequencing"]
          p.runs[run.id] = run
          if j == 0 && index == 0
            p.current_run = run.id
            p.current_acquisition = run.acquisitions.last
          end
        end
        @store.positions[name] = p
      end
      @store.select_position("X1")
      @store.event("TUI", "INFO", "Demo mode: generated data, no hardware or network access")
      @store.event("Host", "WARN", "Demo notification: inspect X4 hardware status")
      @store.event("X1", "INFO", "Protocol started")
      update
    end

    def start
      spawn do
        while @scope.active?
          update
          @scope.pause(1.second)
        end
      end
    end

    def stop
      @scope.stop
    end

    def update
      @tick += 1
      update_channels if @store.tab == 4
      if @generation != @store.generation || @tab != @store.tab
        @generation = @store.generation
        @tab = @store.tab
        seed_detail if @store.acquisition_id
      elsif @store.acquisition_id && @store.run.try(&.ended_at).nil?
        m = @store.detail
        pass_bases = (m.pass_bases || 0_i64) + 240_000_i64
        m.pass_bases = pass_bases
        m.reads = (m.reads || 0_i64) + 30_i64
        m.updated_at = Time.utc
        m.pass.put(7200 + @tick, pass_bases)
        m.temperatures.put(7200 + @tick, 35.0 + Math.sin(@tick / 10.0) * 0.2)
      end
      @store.event("X1", "INFO", "Demo acquisition is sequencing normally") if @tick % 30 == 0
      @store.changed
    end

    private def seed_detail
      m = @store.detail
      calibration = @store.acquisition_id.to_s.ends_with?("calibration")
      factor = calibration ? 0.01 : 1.0
      pass_bases = (8_200_000_000_i64 * factor).to_i64
      m.pass_bases = pass_bases
      fail_bases = (400_000_000_i64 * factor).to_i64
      m.fail_bases = fail_bases
      estimated_bases = (9_300_000_000_i64 * factor).to_i64
      m.estimated_bases = estimated_bases
      m.reads = (1_100_000_i64 * factor).to_i64
      m.pass_calls = (1_050_000_i64 * factor).to_i64
      m.fail_calls = (75_000_i64 * factor).to_i64
      m.n50 = 12_400.0
      m.estimated_n50 = 13_100.0
      m.occupancy = 0.78
      m.processed = 0.96
      m.temperature = 35.1
      m.temperature_label = "Heatsink"
      m.channel_states = {"strand" => 78.0, "pore" => 12.0, "unavailable" => 7.0, "other" => 3.0}
      m.state_styles = {
        "strand"      => StateStyle.new("Sequencing", "Read in progress", "#52d687", "Sequencing", 1_u32),
        "pore"        => StateStyle.new("Pore available", "Ready", "#228854", "Pore available", 2_u32),
        "unavailable" => StateStyle.new("Unavailable", "", "#27508a", "Unavailable", 3_u32),
        "other"       => StateStyle.new("Other", "", "#8ba5bf", "Other", 4_u32),
      }
      m.basecalling_enabled = true
      m.basecall_model = "dna_r10.4.1_e8.2_400bps_sup"
      m.barcoding_kits = "SQK-NBD114"
      m.alignment_reference = "reference.fa"
      m.remaining_until = Time.utc + 4.hours unless @store.run.try(&.ended_at)
      m.remaining_estimated = true
      @store.position.try(&.state_styles=(m.state_styles))
      m.qscore_modal = 18.0
      m.qscore_histogram = (0...40).map do |i|
        HistogramBin.new(i.to_f64, (i + 1).to_f64, (Math.exp(-((i - 18.0) ** 2) / 42.0) * 8000).round.to_f64)
      end
      m.histogram_unit = "basecalled bp"
      m.histogram = (0...1000).map do |i|
        count = (Math.exp(-((i - 10.0) ** 2) / 50.0) * 120_000).round
        count = 500.0 if i == 900
        HistogramBin.new(i * 1000.0, (i + 1) * 1000.0, count)
      end
      120.times do |i|
        m.pass.put(i * 60, pass_bases * i / 119.0)
        m.fail.put(i * 60, fail_bases * i / 119.0)
        m.estimated.put(i * 60, estimated_bases * i / 119.0)
        m.temperatures.put(i * 60, 35.0 + Math.sin(i / 6.0) * 0.2)
        m.bias_voltages.put(i * 60, -180.0 + Math.sin(i / 15.0) * 5.0)
        m.qscore_medians.put(i * 60, 17.5 + Math.sin(i / 12.0) * 0.8)
        m.put_duty(DutyBucket.new(i * 60, (i + 1) * 60, {"strand" => 78.0 + Math.sin(i / 5.0) * 5.0,
                                                         "pore" => 12.0, "unavailable" => 7.0, "other" => 3.0}))
      end
      m.updated_at = Time.utc
      if p = @store.position
        %w[activity history temperature detail.summary detail.yield detail.n50 detail.read_lengths detail.duty_time detail.temperature_history detail.bias_voltage detail.qscore_histogram detail.qscore_time detail.remaining].each { |key| p.capabilities[key] = "Available [DEMO]" }
      end
    end

    private def update_channels
      return unless p = @store.position
      unless p.current_acquisition && p.has_flow_cell && p.connected?
        p.capabilities["channels"] = "No active acquisition [DEMO]"
        return
      end
      if p.pore_states.empty?
        seed_channels(p)
      end
      channel = @tick % p.channels.to_i + 1
      p.update_channel(channel, ChannelState.new(@tick.even? ? "strand" : "unblocking", 1_u32))
      p.pore_updated_at = Time.utc
      p.capabilities["channels"] = "Available [DEMO]"
    end

    private def seed_channels(p : Position)
      p.channels.to_i.times do |index|
        state = case index % 100
                when 0...58  then "strand"
                when 58...66 then "pore"
                when 66...88 then "no_pore"
                when 88...93 then "unblocking"
                when 93...95 then "adapter"
                when 95...98 then "unavailable"
                else              "unclassified"
                end
        p.update_channel(index + 1, ChannelState.new(state, (index % 4 + 1).to_u32))
      end
    end
  end
end
