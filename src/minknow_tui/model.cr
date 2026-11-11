require "set"

module MinknowTui
  VERSION = {{ `shards version "#{__DIR__}/../.."`.chomp.stringify }}

  # No terminal control sequences or Crysterm tags from remote/user data.
  def self.text(value) : String
    value.to_s.gsub(/[\x00-\x08\x0b-\x1f\x7f]/, "")
  end

  def self.number(value : Number?, unit = "") : String
    return "—" unless value
    n = value.to_f64
    scale, suffix = if n.abs >= 1e9
                      {1e9, "G"}
                    elsif n.abs >= 1e6
                      {1e6, "M"}
                    elsif n.abs >= 1e3
                      {1e3, "k"}
                    else
                      {1.0, ""}
                    end
    "#{"%.2f" % (n / scale)} #{suffix}#{unit}".strip
  end

  class Series
    LIMIT = 1440
    getter points = [] of Tuple(Float64, Float64)

    def replace(values : Array(Tuple(Float64, Float64)))
      @points.clear
      values.each { |time, value| put(time, value) }
    end

    # Replace replayed/overlapping timestamps. Compact old samples, retaining
    # the first and last points and a bounded number of representatives.
    def put(time : Number, value : Number)
      t, v = time.to_f64, value.to_f64
      return unless t.finite? && v.finite?
      if index = @points.index { |point| point[0] == t }
        @points[index] = {t, v}
      else
        @points << {t, v}
        @points.sort_by!(&.[0])
      end
      if @points.size > LIMIT
        newest = @points.last
        @points = @points.each_with_index.compact_map { |point, i| point if i.even? }.to_a
        @points << newest unless @points.last == newest
      end
    end
  end

  record HistogramBin, lower : Float64, upper : Float64, count : Float64 do
    def label : String
      value = MinknowTui.number(lower).gsub(".00", "").delete(' ')
      upper.finite? ? value : "≥#{value}"
    end
  end

  record StateStyle, label : String, description : String, colour : String, group : String, order : UInt32, group_colour : String = "" do
    def terminal_colour : String?
      self.class.normalize_colour(colour)
    end

    def group_terminal_colour : String?
      self.class.normalize_colour(group_colour)
    end

    def self.normalize_colour(value : String) : String?
      hex = value.lchop('#')
      "##{hex}" if hex.matches?(/\A[0-9a-fA-F]{6}\z/)
    end
  end
  record DutyBucket, start : Int32, finish : Int32, states : Hash(String, Float64)

  record ChannelState, name : String, well : UInt32 = 0_u32,
    acquisition_index : UInt64 = 0_u64, analysis_index : UInt64 = 0_u64

  class Metrics
    property basecalling_enabled : Bool? = nil
    property reads : Int64? = nil
    property pass_calls : Int64? = nil
    property fail_calls : Int64? = nil
    property pass_bases : Int64? = nil
    property fail_bases : Int64? = nil
    property estimated_bases : Int64? = nil
    property n50 : Float64? = nil
    property estimated_n50 : Float64? = nil
    property occupancy : Float64? = nil
    property processed : Float64? = nil
    property temperature : Float64? = nil
    property temperature_label = "Temperature"
    property histogram = [] of HistogramBin
    property qscore_histogram = [] of HistogramBin
    property histogram_unit = "bases"
    property channel_states = {} of String => Float64
    property sample_rate : UInt32? = nil
    property state_styles = {} of String => StateStyle
    getter duty_buckets = [] of DutyBucket
    getter pass = Series.new
    getter fail = Series.new
    getter estimated = Series.new
    getter temperatures = Series.new
    getter bias_voltages = Series.new
    getter qscore_medians = Series.new
    property qscore_modal : Float64? = nil
    property basecall_model = ""
    property alignment_reference = ""
    property alignment_bed = ""
    property barcoding_kits = ""
    property remaining_until : Time? = nil
    property? remaining_estimated = false
    property updated_at : Time? = nil

    def put_duty(bucket : DutyBucket)
      return if bucket.finish <= bucket.start
      if index = @duty_buckets.index { |old| old.start == bucket.start }
        @duty_buckets[index] = bucket
      else
        @duty_buckets << bucket
        @duty_buckets.sort_by!(&.start)
      end
      while @duty_buckets.size > Series::LIMIT
        @duty_buckets.shift
      end
    end

    def activity_buckets(detailed = false, percent = true) : Array(DutyBucket)
      return [] of DutyBucket if duty_buckets.empty?
      step = duty_buckets.last.finish >= 48 * 60 ? 300 : 60
      grouped = {} of Int32 => Hash(String, Float64)
      duty_buckets.each do |bucket|
        start = bucket.start // step * step
        values = grouped[start] ||= Hash(String, Float64).new(0.0)
        bucket.states.each do |name, value|
          key = detailed ? name : (state_styles[name]?.try(&.group) || name)
          values[key] += value
        end
      end
      grouped.keys.sort!.map do |start|
        values = grouped[start]
        if percent
          total = values.values.sum
          values = values.transform_values { |value| total > 0 ? value * 100 / total : 0.0 }
        elsif (rate = sample_rate) && rate > 0
          values = values.transform_values { |value| value / rate }
        end
        DutyBucket.new(start, start + step, values)
      end
    end

    def histogram_bars(capacity : Int32, full_range = false) : Array(HistogramBin)
      return [] of HistogramBin if histogram.empty?
      total = histogram.sum(&.count)
      return [] of HistogramBin if total <= 0
      lower = full_range ? 0.0 : total * 0.01
      upper = full_range ? total : total * 0.99
      cumulative = 0.0
      adjusted = histogram.map do |bin|
        before = cumulative
        cumulative += bin.count
        retained = Math.max(0.0, Math.min(cumulative, upper) - Math.max(before, lower))
        HistogramBin.new(bin.lower, bin.upper, retained)
      end
      first = adjusted.index { |bin| bin.count > 0 }
      last = adjusted.rindex { |bin| bin.count > 0 }
      return [] of HistogramBin unless first && last
      source = adjusted[first..last]
      width = Math.max(1, (source.size + capacity - 1) // Math.max(1, capacity))
      source.each_slice(width).map do |group|
        HistogramBin.new(group.first.lower, group.last.upper, group.sum(&.count))
      end.to_a
    end

    def qscore_bars(capacity : Int32) : Array(HistogramBin)
      width = Math.max(1, (qscore_histogram.size + capacity - 1) // Math.max(1, capacity))
      qscore_histogram.each_slice(width).map do |group|
        HistogramBin.new(group.first.lower, group.last.upper, group.sum(&.count))
      end.to_a
    end
  end

  class Run
    getter id : String
    property sample = ""
    property experiment = ""
    property protocol = ""
    property kit = ""
    property state = "Unknown"
    property phase = "Unknown"
    property output = ""
    property started_at : Time? = nil
    property ended_at : Time? = nil
    property acquisitions = [] of String

    def initialize(@id)
    end

    def label : String
      sample.empty? ? id : sample
    end

    def elapsed : String
      return "—" unless start = started_at
      seconds = Math.max(0, ((ended_at || Time.utc) - start).total_seconds.to_i64)
      "%02d:%02d:%02d" % {seconds // 3600, seconds // 60 % 60, seconds % 60}
    end
  end

  class Position
    getter name : String
    property port : Int32? = nil
    property software = "Unknown"
    property protocol_state = "Unknown"
    property error = ""
    property device = ""
    property device_type = ""
    property flow_cell = ""
    property product = ""
    property state_styles = {} of String => StateStyle
    property has_flow_cell : Bool? = nil
    property channels = 0_u32
    property? simulated = false
    property? connected = false
    property current_run : String? = nil
    property current_acquisition : String? = nil
    property live = Metrics.new
    property updated_at : Time? = nil
    getter runs = {} of String => Run
    getter capabilities = {} of String => String
    getter pore_states = {} of Int32 => ChannelState
    property pore_updated_at : Time? = nil

    def update_channel(channel : Int32, value : ChannelState)
      return unless channel > 0 && channel <= channels
      if old = pore_states[channel]?
        return if {value.acquisition_index, value.analysis_index} < {old.acquisition_index, old.analysis_index}
      end
      pore_states[channel] = value
    end

    def initialize(@name)
    end

    def status : String
      return software unless software == "Running"
      return "Disconnected (last known)" if updated_at && !connected?
      return "No flow cell" if has_flow_cell == false
      return "Sequencing" if current_acquisition
      return "Protocol active" if current_run
      protocol_state
    end

    def history : Array(Run)
      runs.values.sort_by! { |run| {run.id == current_run ? 1 : 0, run.started_at.try(&.to_unix) || 0_i64} }.reverse!
    end
  end

  record Event, key : String, time : Time, source : String, level : String, message : String

  class Store
    property endpoint = ""
    property version = "Unknown"
    property distribution = "Unknown"
    property host_description = ""
    property connection = "Connecting"
    property disk = "Not available"
    property disk_updated_at : Time? = nil
    getter positions = {} of String => Position
    getter capabilities = {} of String => String
    getter events = [] of Event
    @event_keys = Set(String).new
    property position_id : String? = nil
    property run_id : String? = nil
    property acquisition_id : String? = nil
    property? follow_current = true
    getter tab = 0
    property filter = ""
    property detail = Metrics.new
    property generation = 0_u64
    property revision = 0_u64

    def changed
      @revision &+= 1
    end

    def position : Position?
      positions[position_id]?
    end

    def run : Run?
      position.try { |position| position.runs[run_id]? }
    end

    def tab=(value : Int32)
      return if @tab == value
      @tab = value
      clear_detail_capabilities
      changed
    end

    private def clear_detail_capabilities
      position.try do |selected|
        selected.capabilities.keys.each do |key|
          selected.capabilities.delete(key) if key.starts_with?("detail.") && selected.capabilities[key] != "Unsupported"
        end
      end
    end

    def select_position(id : String?)
      return if id == position_id
      @position_id = id
      @follow_current = true
      @run_id = nil
      @acquisition_id = nil
      sync_selection
      reset_detail
    end

    def select_run(id : String?)
      @follow_current = id == position.try(&.current_run)
      @run_id = id
      @acquisition_id = nil
      sync_selection
      reset_detail
    end

    def select_acquisition(id : String?)
      return if @acquisition_id == id
      @acquisition_id = id
      reset_detail
    end

    def sync_selection
      old = {run_id, acquisition_id}
      if p = position
        @follow_current = true if run_id && !p.runs.has_key?(run_id)
        if follow_current?
          @run_id = p.current_run || p.history.first?.try(&.id)
        end
        if r = run
          unless r.acquisitions.includes?(acquisition_id)
            current = p.current_acquisition
            @acquisition_id = current && r.acquisitions.includes?(current) ? current : r.acquisitions.last?
          end
        else
          @acquisition_id = nil
        end
      end
      reset_detail if old != {run_id, acquisition_id}
      changed
    end

    def reset_detail
      @detail = Metrics.new
      @generation &+= 1
      clear_detail_capabilities
      changed
    end

    def current?(generation : UInt64) : Bool
      @generation == generation
    end

    def event(source : String, level : String, message : String, time = Time.utc, key : String? = nil)
      k = key || "#{source}:#{time.to_unix_ms}:#{level}:#{message}"
      return if @event_keys.includes?(k)
      @events << Event.new(k, time, MinknowTui.text(source), level, MinknowTui.text(message))
      @event_keys << k
      while @events.size > 2000
        @event_keys.delete(@events.shift.key)
      end
      changed
    end

    def visible_events : Array(Event)
      events.select { |event| event.source == "Host" || event.source == "TUI" || event.source == position_id }
    end
  end

  # Cancellation does not kill fibers mid-mutation. Every producer checks this
  # scope after an RPC returns, before applying its response.
  class Scope
    getter? active = true
    getter capabilities = {} of String => String
    @cancellations = {} of UInt64 => Proc(Nil)
    @next_id = 0_u64

    def register(&cancel : -> Nil) : UInt64
      @next_id &+= 1
      if active?
        @cancellations[@next_id] = cancel
      else
        cancel.call
      end
      @next_id
    end

    def unregister(id : UInt64)
      @cancellations.delete(id)
    end

    def stop
      @active = false
      callbacks = @cancellations.values
      @cancellations.clear
      callbacks.each { |cancel| cancel.call rescue nil }
    end

    def pause(span : Time::Span)
      # Short cancellable waits keep shutdown and selection changes responsive.
      until_time = Time.instant + span
      while active? && Time.instant < until_time
        sleep 0.05.seconds
      end
    end
  end
end
