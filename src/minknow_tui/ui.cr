require "crysterm"
require "./model"
require "./theme"
require "./pore_map"

module MinknowTui
  alias CT = Crysterm
  alias CW = Crysterm::Widgets

  class Picker < CT::Widget::Dialog
    class ChoiceList < CW::List
      # Crysterm's default cancellation also activates the highlighted item.
      def cancel_current : Nil
        parent.as(Picker).reject
      end
    end

    getter! list : CW::List

    def initialize(window : CT::Window, title : String, items : Array(String), &selected : Int32 ->)
      super(parent: window, width: "90%", height: "75%", parse_tags: false)
      self.label = title
      @list = ChoiceList.new(parent: self, width: "100%", height: "100%", items: items, keys: true, vi_keys: true, parse_tags: false)
      list.on(CT::Event::ItemActivated) do |event|
        selected.call(event.index)
        accept
      end
    end

    def open : Nil
      super
      list.focus
    end
  end

  class HelpDialog < CT::Widget::Dialog
    getter! body : CW::ScrollableText

    def initialize(window : CT::Window)
      super(parent: window, width: "90%", height: "85%", parse_tags: false)
      self.label = "Help — Esc / Enter to close"
      @body = CW::ScrollableText.new(parent: self, width: "100%", height: "100%", keys: true, vi_keys: true, parse_tags: false,
        content: "minknow-tui — read-only MinKNOW monitor\n\n" +
                 "Tab / Shift-Tab  Move focus\nj / k, arrows     Move selection / scroll\n" +
                 "1–5               Overview / Yield / Quality / Device / Pores\n" +
                 "h (Quality)       Auto 99.5% / full read-length range\n" +
                 "Arrows / hjkl     Select channel in Pores (Home/End, PgUp/PgDn)\n" +
                 "p                 Select position (also in compact mode)\n" +
                 "r                 Select protocol run / history\n" +
                 "a                 Select acquisition within the protocol\n" +
                 "/                 Filter positions and runs\n" +
                 "Esc               Clear filter / close dialog\n" +
                 "?                 This help\nq / Ctrl-Q        Quit\n\n" +
                 "History is limited to runs available from the MinKNOW API.\n" +
                 "Statistics are for the selected acquisition, not the entire protocol.\n" +
                 "Estimated bases and basecalled bases are shown separately.\n" +
                 "Basecall counts can differ from the number of acquired reads.\n" +
                 "Pore occupancy and channel time fractions are not live pore counts.\n" +
                 "Scroll up in Events to pause following; End resumes following.\n" +
                 "Device lists unavailable APIs and connection/authentication errors.\n" +
                 "Idle streams need not send messages; their silence is normal.")
    end
  end

  class UI
    getter window : CT::Window
    getter positions_view : CW::ListTable
    getter runs_view : CW::ListTable
    getter tabs : CW::TabWidget
    getter events_view : CW::Log
    getter? compact = false
    getter dialog : CT::Widget::Dialog? = nil
    getter overview : CW::ScrollableText
    getter pores : PoreMap
    getter? full_histogram = false
    @header : CW::Box
    @footer : CW::Box
    @outer : CW::Splitter
    @body : CW::Splitter
    @sidebar : CW::Splitter
    @yield_text : CW::ScrollableText
    @quality_text : CW::ScrollableText
    @device_text : CW::ScrollableText
    @yield_chart : CW::GraphLineChart
    @temperature_chart : CW::GraphLineChart
    @histogram : CW::GraphBar
    @states : CW::ScrollableText
    @position_keys = [] of String?
    @run_keys = [] of String
    @event_keys = [] of String
    @refreshing = false
    @last_chart_signature = ""
    @last_view : Tuple(UInt64, Int32)?

    def initialize(@store : Store, window : CT::Window? = nil)
      @window = window || CT::Window.new(title: "minknow-tui", default_quit_keys: false,
        terminfo: ENV["TERM"]? == "dumb" ? Unibilium.from_terminal("xterm-256color") : true)
      @window.stylesheet = Theme::STYLESHEET
      frame = CW::Box.new(parent: @window, width: "100%", height: "100%", layout: CT::Layout::Dock.new)
      @header = CW::Box.new(parent: frame, height: 1, layout_hint: :top, parse_tags: false,
        style: CT::Style.new(fg: Theme::GREEN, bg: Theme::SURFACE, bold: true))
      @footer = CW::Box.new(parent: frame, height: 1, layout_hint: :bottom, parse_tags: false,
        style: CT::Style.new(fg: Theme::MUTED, bg: Theme::SURFACE))
      @outer = CW::Splitter.new(parent: frame, orientation: :vertical, layout_hint: :center)
      @body = CW::Splitter.new(orientation: :horizontal)
      @sidebar = CW::Splitter.new(orientation: :vertical)
      @positions_view = CW::ListTable.new(width: "100%", height: "100%", keys: true, vi_keys: true, parse_tags: false, align: :left, cell_borders: false)
      @positions_view.label = "Positions"
      @runs_view = CW::ListTable.new(width: "100%", height: "100%", keys: true, vi_keys: true, parse_tags: false, align: :left, cell_borders: false)
      @runs_view.label = "Runs — API history"
      @sidebar.add_widget @positions_view
      @sidebar.add_widget @runs_view
      @sidebar.sizes = [16, 12]
      @tabs = CW::TabWidget.new(width: "100%", height: "100%", parse_tags: false)
      @overview = CW::ScrollableText.new(keys: true, vi_keys: true, parse_tags: false)
      @tabs.add_tab "Overview", @overview

      # Keep iTerm2 plots in the cell buffer so image layers cannot outlive a view.
      graph_type = CW::Media::Type::Glyph if @window.tput.emulator.iterm2? && CT::Config.media_backend.auto?
      yield_page = CW::Box.new(layout: CT::Layout::Dock.new)
      @yield_text = CW::ScrollableText.new(parent: yield_page, height: 7, layout_hint: :top, keys: true, parse_tags: false)
      @yield_chart = CW::GraphLineChart.new(parent: yield_page, title: "Yield (bases)", type: graph_type, layout_hint: :center)
      @yield_chart.axis_x.title = "Acquisition seconds"
      @yield_chart.axis_y.title = "Bases"
      @yield_chart.axis_x.label_format = "%.0f"
      @yield_chart.axis_y.label_format = "%.2g"
      @tabs.add_tab "Yield", yield_page

      quality_page = CW::Box.new(layout: CT::Layout::Dock.new)
      @quality_text = CW::ScrollableText.new(parent: quality_page, height: 6, layout_hint: :top, keys: true, parse_tags: false)
      @states = CW::ScrollableText.new(parent: quality_page, height: 5, layout_hint: :bottom, keys: true, vi_keys: true, parse_tags: false)
      @histogram = CW::GraphBar.new(parent: quality_page, layout_hint: :center, bar_width: 4, bar_spacing: 1, colors: [Theme::GREEN])
      @tabs.add_tab "Quality", quality_page

      device_page = CW::Box.new(layout: CT::Layout::Dock.new)
      @device_text = CW::ScrollableText.new(parent: device_page, height: 12, layout_hint: :top, keys: true, vi_keys: true, parse_tags: false)
      @temperature_chart = CW::GraphLineChart.new(parent: device_page, title: "Temperature history", type: graph_type, layout_hint: :center)
      @temperature_chart.axis_x.title = "Acquisition seconds"
      @temperature_chart.axis_y.title = "°C"
      @temperature_chart.axis_x.label_format = "%.0f"
      @tabs.add_tab "Device", device_page
      @pores = PoreMap.new(width: "100%", height: "100%")
      @tabs.add_tab "Pores", @pores
      @body.add_widget @sidebar
      @body.add_widget @tabs
      @body.sizes = [30, 89]
      @body.set_stretch_factor(1, 1)
      @events_view = CW::Log.new(max_lines: 2000, keys: true, vi_keys: true, parse_tags: false)
      @events_view.label = "Events — Host + selected position"
      @outer.add_widget @body
      @outer.add_widget @events_view
      @outer.sizes = [26, 7]
      @outer.set_stretch_factor(0, 1)

      @positions_view.on(CT::Event::ItemSelected) do |event|
        unless @refreshing
          index = event.index - 1
          @store.select_position(@position_keys[index]?) if index >= 0
          refresh
        end
      end
      @runs_view.on(CT::Event::ItemSelected) do |event|
        unless @refreshing
          index = event.index - 1
          @store.select_run(@run_keys[index]?) if index >= 0
          refresh
        end
      end
      @tabs.on(CT::Event::CurrentChanged) do |event|
        @store.tab = event.index
        @store.changed
        refresh unless @refreshing || @window.destroyed?
      end
      @window.on(CT::Event::Resize) { adapt; refresh }
      @window.on(CT::Event::KeyPress) { |event| key(event) }
      adapt
      refresh
      @positions_view.focus unless compact?
    end

    def adapt
      was_compact = @compact
      @compact = @window.awidth < 100 || @window.aheight < 30
      compact? ? @sidebar.hide : @sidebar.show
      @events_view.height = compact? ? 5 : 7
      @outer.sizes = [Math.max(@window.aheight - (compact? ? 8 : 10), 1), compact? ? 5 : 7]
      @device_text.height = compact? ? 8 : 12
      @yield_text.height = compact? ? 6 : 7
      @states.height = compact? ? 3 : 5
      show_tab(@store.tab) if compact? && !was_compact
    end

    def refresh
      return if @window.destroyed?
      @refreshing = true
      @header.content = " minknow-tui | #{@store.endpoint} | Core #{@store.version} | #{@store.connection}"
      hints = compact? ? " Tab focus  1–5 tabs  p positions  r runs  a acq  / filter  ? help  q quit" : " Tab focus  j/k move  1–5 tabs  p positions  r runs  a acq  / filter  ? help  q quit"
      @footer.content = "#{hints}#{@store.filter.empty? ? "" : " | /#{@store.filter}"}"
      update_lists
      update_detail
      @pores.refresh(@store.position) if @store.tab == 4
      update_events
      view = {@store.generation, @store.tab}
      if @last_view && @last_view != view
        # Terminal-owned graph images are outside Crysterm's cell diff.
        @window.clear_device
        @window.invalidate_region(0, @window.awidth, 0, @window.aheight)
      end
      @last_view = view
      @window.update
    ensure
      @refreshing = false
    end

    private def update_lists
      values = @store.positions.values.sort_by!(&.name).select { |position| "#{position.name} #{position.status} #{position.error}".downcase.includes?(@store.filter.downcase) }
      @position_keys = [nil.as(String?)] + values.map { |position| position.name.as(String?) }
      rows = [["Position", "State"], ["Host", "Overview"]] + values.map { |position| [MinknowTui.text(position.name), position.status] }
      @positions_view.rows = rows unless @positions_view.rows == rows
      @positions_view.current_index = (@position_keys.index(@store.position_id) || 0) + 1
      runs = @store.position.try(&.history) || [] of Run
      runs = runs.select { |run| "#{run.label} #{run.id} #{run.experiment}".downcase.includes?(@store.filter.downcase) }
      @run_keys = runs.map(&.id)
      rows = [["Run / sample", "State"]] + runs.map { |run| ["#{run.id == @store.position.try(&.current_run) ? "* " : run.started_at.try(&.to_local.to_s("%m/%d "))}#{run.label}", run.state] }
      @runs_view.rows = rows unless @runs_view.rows == rows
      @runs_view.current_index = (@run_keys.index(@store.run_id) || 0) + 1 unless runs.empty?
      @runs_view.label = "Runs: #{MinknowTui.text(@store.position_id || "Host")} — API history"
    end

    private def acquisition_label : String
      "Acquisition: #{@store.acquisition_id || "none"} (a to change)"
    end

    private def update_detail
      unless position = @store.position
        @overview.content = "\n  Host overview\n\n  #{@store.host_description}\n  Manager: #{@store.endpoint}\n  Core: #{@store.version}\n  Distribution: #{@store.distribution}\n  Positions: #{@store.positions.size}\n  Connection: #{@store.connection}\n\n  Disk space (last known):\n  #{@store.disk}\n\n  Select a position with p or the Positions pane.\n  History is limited to runs available from the MinKNOW API."
        @yield_text.content = "Select a position and protocol run."
        @quality_text.content = "Select a position and protocol run."
        @device_text.content = @store.capabilities.map { |k, v| "#{k}: #{v}" }.join("\n")
        clear_charts
        return
      end
      metrics = @store.detail
      update_overview(position, metrics)
      update_statistics(position, metrics)
      update_device(position, metrics)
      update_charts(metrics)
    end

    private def temperature_text(position : Position, metrics : Metrics) : String
      temperature = metrics.temperature || position.live.temperature
      label = metrics.temperature ? metrics.temperature_label : "Current #{position.live.temperature_label}"
      "#{label}: #{temperature ? "%.1f °C" % temperature : "—"}"
    end

    private def percentage(value : Float64?) : String
      value.try { |number| "%.1f%%" % (number * 100) } || "—"
    end

    private def update_overview(position : Position, metrics : Metrics)
      run = @store.run
      @overview.content = "\n  #{MinknowTui.text(position.name)}  #{position.status}#{position.simulated? ? " [SIMULATED]" : ""}\n" +
                          "  Software: #{position.software}  #{position.error}\n  Sample: #{run.try(&.sample) || "—"}\n  Experiment: #{run.try(&.experiment) || "—"}\n" +
                          "  Run: #{run.try(&.id) || "—"}\n  Protocol: #{run.try(&.protocol) || "—"}\n  State: #{run.try(&.state) || "No active run"} / #{run.try(&.phase) || "—"}\n" +
                          "  Elapsed: #{run.try(&.elapsed) || "—"}\n  #{acquisition_label}\n\n" +
                          "  Pass yield: #{MinknowTui.number(metrics.pass_bases, "b")}    Fail: #{MinknowTui.number(metrics.fail_bases, "b")}\n" +
                          "  Estimated yield: #{MinknowTui.number(metrics.estimated_bases, "b")}\n  Acquired reads: #{MinknowTui.number(metrics.reads)}\n" +
                          "  N50 basecalled: #{MinknowTui.number(metrics.n50, "b")}    Estimated: #{MinknowTui.number(metrics.estimated_n50, "b")}\n" +
                          "  #{temperature_text(position, metrics)}\n" +
                          "  Flow cell: #{position.flow_cell}  #{position.product}\n  Output: #{run.try(&.output) || "—"}\n\n" + data_status(position, metrics)
    end

    private def data_status(position : Position, metrics : Metrics) : String
      stamp = metrics.updated_at.try(&.to_local.to_s("%H:%M:%S %Z")) || "not received"
      api = position.capabilities["flow_cell"]? || position.capabilities["activity"]? || "Connecting"
      "  Summary received: #{stamp}\n  Position API: #{api}\n  API history may be cleared when MinKNOW restarts."
    end

    private def update_statistics(position : Position, metrics : Metrics)
      histogram_reads = metrics.histogram.empty? ? "—" : MinknowTui.number(metrics.histogram.sum(&.count))
      @yield_text.content = "#{acquisition_label}\nPass: #{MinknowTui.number(metrics.pass_bases, "b")}  Fail: #{MinknowTui.number(metrics.fail_bases, "b")}  Estimated: #{MinknowTui.number(metrics.estimated_bases, "b")}\n" +
                            "Acquired reads: #{MinknowTui.number(metrics.reads)}\nBasecalls pass / fail: #{MinknowTui.number(metrics.pass_calls)} / #{MinknowTui.number(metrics.fail_calls)}\n" +
                            "Basecaller processed / skipped: #{metrics.basecalling_enabled == false ? "Disabled" : percentage(metrics.processed)}\n#{capability(position, "yield")}"
      @quality_text.content = "#{acquisition_label}\nN50 basecalled: #{MinknowTui.number(metrics.n50, "b")}  Estimated: #{MinknowTui.number(metrics.estimated_n50, "b")}\n" +
                              "Pore occupancy: #{percentage(metrics.occupancy)}\nRead length: #{metrics.histogram_unit}; #{histogram_reads} reads\n" +
                              "Y: read counts | #{full_histogram? ? "Full range" : "Auto 99.5%; ≥ tail"} | h: range\n#{capability(position, "read_lengths")}"
      @states.content = "Channel time fractions (not pore counts):\n" + metrics.channel_states.map { |k, v| "#{MinknowTui.text(k)}: #{"%.1f%%" % v}" }.join("  ") + "\n#{capability(position, "duty_time")}"
    end

    private def update_device(position : Position, metrics : Metrics)
      @device_text.content = "#{MinknowTui.text(position.name)} — #{position.device_type} #{position.simulated? ? "[SIMULATED]" : ""}\n" +
                             "Device: #{position.device}  Flow cell: #{position.flow_cell} #{position.product} (#{position.channels} channels)\n" +
                             "Endpoint: #{@store.endpoint.sub(/:\d+$/, "")}:#{position.port || "unavailable"}\nSoftware: #{position.software}  #{position.error}\n" +
                             "#{temperature_text(position, metrics)}\n#{acquisition_label}\n" +
                             position.capabilities.map { |k, v| "#{k}: #{v}" }.join("\n")
    end

    private def capability(p : Position, key : String) : String
      p.capabilities["detail.#{key}"]?.try { |value| "#{key}: #{value}" } || "Waiting for API data; see Device for availability."
    end

    private def clear_charts
      @yield_chart.clear_series
      @temperature_chart.clear_series
      @histogram.values = [] of Float64
      @states.content = ""
      @last_chart_signature = ""
    end

    private def update_charts(m : Metrics)
      # Avoid rebuilding graph chrome on every clock tick.
      signature = {m.pass.points, m.fail.points, m.estimated.points, m.temperatures.points, m.histogram, full_histogram?, @window.awidth}.hash.to_s
      return if signature == @last_chart_signature
      @last_chart_signature = signature
      @yield_chart.clear_series
      @yield_chart.add_line("Pass", m.pass.points, Theme::GREEN) unless m.pass.points.empty?
      @yield_chart.add_line("Fail", m.fail.points, Theme::ERROR) unless m.fail.points.empty?
      @yield_chart.add_line("Estimated", m.estimated.points, Theme::TURQUOISE) unless m.estimated.points.empty?
      @yield_chart.refresh
      @temperature_chart.clear_series
      @temperature_chart.add_line(m.temperature_label, m.temperatures.points, Theme::WARNING) unless m.temperatures.points.empty?
      @temperature_chart.refresh
      capacity = Math.max(1, (@window.awidth - (compact? ? 4 : 34)) // 5)
      bars = m.histogram_bars(capacity, full_histogram?)
      @histogram.values = bars.map(&.count)
      @histogram.labels = bars.map(&.label)
    end

    private def update_events
      events = @store.visible_events
      keys = events.map(&.key)
      if keys.size >= @event_keys.size && keys.first(@event_keys.size) == @event_keys
        events.skip(@event_keys.size).each { |event| @events_view.add format_event(event) }
      elsif keys != @event_keys
        @events_view.content = events.map { |event| format_event(event) }.join("\n")
      end
      @event_keys = keys
    end

    private def format_event(event : Event) : String
      "#{event.time.to_local.to_s("%H:%M:%S")} [#{event.level}] #{event.source}: #{event.message}"
    end

    private def track(dialog : CT::Widget::Dialog)
      @dialog = dialog
      dialog.on(CT::Event::Finished) do
        @dialog = nil
        dialog.destroy
        show_tab(@store.tab)
        refresh
      end
      dialog.open
    end

    def pick_position
      values = @store.positions.values.sort_by!(&.name).select { |position| "#{position.name} #{position.status}".downcase.includes?(@store.filter.downcase) }
      keys = [nil.as(String?)] + values.map { |position| position.name.as(String?) }
      track Picker.new(@window, "Positions", ["Host overview"] + values.map { |position| "#{MinknowTui.text(position.name)}  #{position.status}" }) { |i| @store.select_position(keys[i]?) }
    end

    def pick_run
      values = (@store.position.try(&.history) || [] of Run).select { |run| "#{run.label} #{run.id}".downcase.includes?(@store.filter.downcase) }
      track Picker.new(@window, "Runs — available API history", values.map { |run| "#{run.started_at.try(&.to_local.to_s("%m/%d %H:%M"))} #{run.label}  #{run.state}  #{run.id}" }) { |i| @store.select_run(values[i]?.try(&.id)) }
    end

    def pick_acquisition
      values = @store.run.try(&.acquisitions) || [] of String
      track Picker.new(@window, "Acquisitions — statistics are not combined", values) { |i| @store.select_acquisition(values[i]?) }
    end

    private def control_key(key : Tput::Key?) : Bool
      case key
      when Tput::Key::CtrlQ, Tput::Key::CtrlC then @window.quit
      when Tput::Key::Tab                     then @window.focus_next
      when Tput::Key::ShiftTab                then @window.focus_previous
      when Tput::Key::Escape
        @store.filter = ""
        refresh
      else
        return false
      end
      true
    end

    private def key(event : CT::Event::KeyPress)
      return if @dialog
      case event.char
      when 'q'
        @window.quit
      when '1'..'5'
        show_tab(event.char.to_i - '1'.to_i)
      when 'h'
        return unless @store.tab == 2
        @full_histogram = !@full_histogram
      when 'p' then pick_position
      when 'r' then pick_run
      when 'a' then pick_acquisition
      when '?' then track HelpDialog.new(@window)
      when '/' then filter_dialog
      else
        return unless control_key(event.key)
      end
      event.accept
      @store.changed
      refresh
    end

    private def show_tab(index : Int32)
      # Move focus before hiding a page: Crysterm's focus rewind can otherwise
      # reselect the old tab while a page switch is still in progress.
      @tabs.tab_bar.focus
      @tabs.current_index = index
      @store.tab = @tabs.current_index
      @store.tab == 4 ? @pores.focus : @tabs.tab_bar.focus
    end

    private def filter_dialog
      dialog = CW::InputDialog.new(parent: @window, width: "90%", height: 8, parse_tags: false)
      @dialog = dialog
      dialog.open("Filter positions and runs:", @store.filter) do |value|
        @store.filter = value if value
        @dialog = nil
        dialog.destroy
        refresh
      end
    end
  end
end
