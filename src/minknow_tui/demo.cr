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
        p.device_type = "MinION"
        p.simulated = true
        p.port = 8000 + index
        p.channels = 512_u32
        p.connected = index != 3
        p.live.temperature = 35.1
        p.live.temperature_label = "Heatsink"
        3.times do |j|
          run = Run.new("demo-#{name}-protocol-#{j}")
          run.sample = j == 0 ? "sample-A" : "sample-#{j + 1}"
          run.experiment = "experiment-01"
          run.protocol = "sequencing/sequencing_MIN114"
          run.started_at = Time.utc - (j * 24 + 2).hours
          run.ended_at = j > 0 || index != 0 ? run.started_at.not_nil! + 1.hour : nil
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
      if @generation != @store.generation || @tab != @store.tab
        @generation = @store.generation
        @tab = @store.tab
        seed_detail if @store.acquisition_id
      elsif @store.acquisition_id && @store.run.try(&.ended_at).nil?
        m = @store.detail
        m.pass_bases = (m.pass_bases || 0_i64) + 240_000_i64
        m.reads = (m.reads || 0_i64) + 30_i64
        m.updated_at = Time.utc
        m.pass.put(7200 + @tick, m.pass_bases.not_nil!)
        m.temperatures.put(7200 + @tick, 35.0 + Math.sin(@tick / 10.0) * 0.2)
      end
      @store.event("X1", "INFO", "Demo acquisition is sequencing normally") if @tick % 30 == 0
      @store.changed
    end

    private def seed_detail
      m = @store.detail
      calibration = @store.acquisition_id.to_s.ends_with?("calibration")
      factor = calibration ? 0.01 : 1.0
      m.pass_bases = (8_200_000_000_i64 * factor).to_i64
      m.fail_bases = (400_000_000_i64 * factor).to_i64
      m.estimated_bases = (9_300_000_000_i64 * factor).to_i64
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
      m.histogram_unit = "Basecalled bases"
      m.histogram = (0...24).map { |i| {"#{i * 2}k", (Math.exp(-((i - 5.0) ** 2) / 32.0) * 120_000).round} }
      120.times do |i|
        m.pass.put(i * 60, m.pass_bases.not_nil! * i / 119.0)
        m.fail.put(i * 60, m.fail_bases.not_nil! * i / 119.0)
        m.estimated.put(i * 60, m.estimated_bases.not_nil! * i / 119.0)
        m.temperatures.put(i * 60, 35.0 + Math.sin(i / 6.0) * 0.2)
      end
      m.updated_at = Time.utc
      if p = @store.position
        %w(activity history temperature detail.summary detail.yield detail.n50 detail.read_lengths detail.duty_time detail.temperature_history).each { |key| p.capabilities[key] = "Available [DEMO]" }
      end
    end
  end
end
