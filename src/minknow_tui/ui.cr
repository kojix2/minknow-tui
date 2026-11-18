require "crysterm"
require "./model"
require "./theme"
require "./pore_map"
require "./signal_dialog"

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

    def initialize(window : CT::Window, title : String, items : Array(String), initial = 0, &selected : Int32 ->)
      super(parent: window, width: "90%", height: "75%", parse_tags: false)
      self.label = title
      @list = ChoiceList.new(parent: self, width: "100%", height: "100%", items: items, keys: true, vi_keys: true, parse_tags: false)
      list.current_index = initial unless items.empty?
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

  class TextDialog < CT::Widget::Dialog
    getter! body : CW::ScrollableText

    def initialize(window : CT::Window, title : String, text : String)
      super(parent: window, width: "90%", height: "85%", parse_tags: false)
      self.label = "#{title} — Esc to close"
      @body = CW::ScrollableText.new(parent: self, width: "100%", height: "100%", keys: true, vi_keys: true, parse_tags: false,
        content: text)
    end

    def open : Nil
      super
      body.focus
    end
  end

  class HelpDialog < TextDialog
    def initialize(window : CT::Window)
      super(window, "Help", "minknow-tui — read-only MinKNOW monitor\n\n" +
                            "Tab / Shift-Tab  Move focus\nj / k, arrows     Move selection / scroll\n" +
                            "1–6               Overview / Yield / Quality / Device / Pores / Activity\n" +
                            "v (Quality/Device) Change graph\n" +
                            "h (Quality)       Trim 1% each end / full read-length range\n" +
                            "d / u (Activity) Detailed/grouped states; percent/absolute\n" +
                            "Arrows / hjkl     Select channel in Pores (Home/End, PgUp/PgDn)\n" +
                            "t (Pores)         View current from the selected live channel\n" +
                            "p                 Select position (also in compact mode)\n" +
                            "r                 Follow the current run or select history\n" +
                            "a                 Select acquisition within the protocol\n" +
                            "i                 Inspect IDs, run settings and API status\n" +
                            "/                 Filter positions and runs\n" +
                            "Esc               Clear filter / close dialog\n" +
                            "?                 This help\nq / Ctrl-Q        Quit\n\n" +
                            "History is limited to runs available from the MinKNOW API.\n" +
                            "Statistics are for the selected acquisition, not the entire protocol.\n" +
                            "Estimated bases and basecalled bases are shown separately.\n" +
                            "Basecall counts can differ from the number of acquired reads.\n" +
                            "Pore occupancy and channel time fractions are not live pore counts.\n" +
                            "Scroll up in Events to pause following; End resumes following.\n" +
                            "Details include API availability and connection/authentication errors.\n" +
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
    @bias_chart : CW::GraphLineChart
    getter qscore_chart : CW::GraphLineChart
    @histogram : CW::GraphBar
    @qscore_histogram : CW::GraphBar
    @activity_text : CW::ScrollableText
    getter activity_chart : CW::GraphStackedBar
    getter quality_mode = 0
    getter device_mode = 0
    @activity_detailed = false
    @activity_percent = true
    @position_keys = [] of String?
    @run_keys = [] of String
    @event_keys = [] of String
    @refreshing = false
    @last_chart_signature = ""
    @last_activity_signature : UInt64? = nil
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
      @yield_text = CW::ScrollableText.new(parent: yield_page, height: 4, layout_hint: :top, keys: true, parse_tags: false)
      @yield_chart = CW::GraphLineChart.new(parent: yield_page, title: "Yield (bases)", type: graph_type, layout_hint: :center)
      @yield_chart.axis_x.title = "Acquisition seconds"
      @yield_chart.axis_y.title = "bp"
      @yield_chart.axis_x.label_format = "%.0f"
      @yield_chart.axis_y.label_format = "%.2g"
      @tabs.add_tab "Yield", yield_page

      quality_page = CW::Box.new(layout: CT::Layout::Dock.new)
      @quality_text = CW::ScrollableText.new(parent: quality_page, height: 4, layout_hint: :top, keys: true, parse_tags: false)
      @histogram = CW::GraphBar.new(parent: quality_page, layout_hint: :center, bar_width: 4, bar_spacing: 1, colors: [Theme::GREEN])
      @qscore_histogram = CW::GraphBar.new(parent: quality_page, layout_hint: :center, bar_width: 3, bar_spacing: 1, colors: [Theme::TURQUOISE])
      @qscore_chart = CW::GraphLineChart.new(parent: quality_page, title: "Q score over time", type: graph_type, layout_hint: :center)
      @qscore_chart.axis_x.title = "Acquisition seconds"
      @qscore_chart.axis_y.title = "Q"
      @qscore_chart.axis_x.label_format = "%.0f"
      @tabs.add_tab "Quality", quality_page

      device_page = CW::Box.new(layout: CT::Layout::Dock.new)
      @device_text = CW::ScrollableText.new(parent: device_page, height: 4, layout_hint: :top, keys: true, vi_keys: true, parse_tags: false)
      @temperature_chart = CW::GraphLineChart.new(parent: device_page, title: "Temperature history", type: graph_type, layout_hint: :center)
      @temperature_chart.axis_x.title = "Acquisition seconds"
      @temperature_chart.axis_y.title = "°C"
      @temperature_chart.axis_x.label_format = "%.0f"
      @bias_chart = CW::GraphLineChart.new(parent: device_page, title: "Bias voltage history", type: graph_type, layout_hint: :center)
      @bias_chart.axis_x.title = "Acquisition seconds"
      @bias_chart.axis_y.title = "mV"
      @bias_chart.axis_x.label_format = "%.0f"
      @tabs.add_tab "Device", device_page
      @pores = PoreMap.new(width: "100%", height: "100%")
      @tabs.add_tab "Pores", @pores
      activity_page = CW::Box.new(layout: CT::Layout::Dock.new)
      @activity_text = CW::ScrollableText.new(parent: activity_page, height: 4, layout_hint: :top, keys: true, parse_tags: false)
      @activity_chart = CW::GraphStackedBar.new(parent: activity_page, layout_hint: :center, bar_width: 1, bar_spacing: 0)
      @tabs.add_tab "Activity", activity_page
      update_graph_visibility
      @body.add_widget @sidebar
      @body.add_widget @tabs
      @body.sizes = [44, 89]
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
      show_tab(@store.tab) if compact? && !was_compact
    end

    def refresh
      return if @window.destroyed?
      @refreshing = true
      if @quality_mode != 0 && !qscore_enabled?
        @quality_mode = 0
      end
      update_graph_visibility
      @header.content = header
      @footer.content = footer
      update_lists
      update_detail
      @pores.refresh(@store.position) if @store.tab == 4
      if dialog = @dialog.as?(SignalDialog)
        @store.reconcile_trace
        dialog.refresh
      end
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

    private def header : String
      status = @store.connection
      status += " · SIMULATED" if @store.position.try(&.simulated?) && !status.includes?("[DEMO]")
      status = fit_cell(status, @window.awidth // 3)
      width = Math.max(1, @window.awidth - display_width(status) - 3)
      context = if position = @store.position
                  selection_context(position, width)
                else
                  "minknow-tui  ·  Host  ·  #{@store.endpoint}"
                end
      left = fit_cell(context, width)
      " #{left}#{" " * (width - display_width(left) + 1)}#{status}"
    end

    private def selection_context(position : Position, width : Int32) : String
      live = position.connected? ? "LIVE" : "LAST KNOWN"
      if @store.tab == 4
        return "#{live} #{position.name}  ·  Current channels  ·  #{position.status}" if position.current_acquisition
        return "#{position.name}  ·  Current channels  ·  #{position.status}"
      end
      return "#{position.name}  ·  #{position.status}" unless run = @store.run
      current = run.id == position.current_run && (!@store.acquisition_id || @store.acquisition_id == position.current_acquisition)
      prefix = "#{current ? live : "HISTORY"} #{position.name}  ·  #{run.start_label}  ·  "
      suffix = ""
      if run.acquisitions.size > 1 && (index = run.acquisitions.index(@store.acquisition_id))
        suffix = "  ·  Acq #{index + 1}/#{run.acquisitions.size}"
      end
      prefix + fit_cell(run.label, Math.max(1, width - display_width(prefix + suffix))) + suffix
    end

    private def footer : String
      case @dialog
      when SignalDialog    then return " Esc back to Pores"
      when Picker          then return " ↑↓ choose  Enter select  Esc cancel"
      when TextDialog      then return " ↑↓ scroll  Esc close"
      when CW::InputDialog then return " Enter apply  Esc cancel"
      end
      unless @store.filter.empty?
        hints = (graph_hints + ["i details", "? help", "q quit"]).join("  ")
        filter = fit_cell(@store.filter, Math.max(1, @window.awidth - display_width(hints) - 21))
        return " Filter: #{filter}  Esc clear  #{hints}"
      end
      keys = ["p positions"]
      keys << "r runs" if @store.position
      keys << "a acq" if @store.run && @store.tab != 4
      keys << "i details"
      keys.concat(graph_hints)
      keys << "/ filter" unless compact?
      keys << "? help" << "q quit"
      " #{keys.join("  ")}"
    end

    private def graph_hints : Array(String)
      if @store.tab == 4 && (p = @store.position)
        return p.trace_available? ? ["←↑↓→ channel", "t trace"] : ["←↑↓→ channel"]
      end
      return [] of String unless @store.acquisition_id
      case @store.tab
      when 2
        keys = [] of String
        keys << "h range" if @quality_mode == 0
        keys << "v graph" if qscore_enabled?
        keys
      when 3 then ["v graph"]
      when 5 then ["d detail", "u unit"]
      else        [] of String
      end
    end

    private def qscore_enabled? : Bool
      !!@store.acquisition_id && @store.detail.basecalling_enabled == true
    end

    private def matching_runs : Array(Run)
      runs = @store.position.try(&.history) || [] of Run
      runs.select { |run| "#{run.label} #{run.id} #{run.experiment}".downcase.includes?(@store.filter.downcase) }
    end

    private def update_lists
      values = @store.positions.values.sort_by!(&.name).select { |position| "#{position.name} #{position.status} #{position.error}".downcase.includes?(@store.filter.downcase) }
      @position_keys = [nil.as(String?)] + values.map { |position| position.name.as(String?) }
      rows = [["Position", "State"], ["Host", "Overview"]] + values.map { |position| [MinknowTui.text(position.name), position.status] }
      @positions_view.rows = rows unless @positions_view.rows == rows
      @positions_view.current_index = (@position_keys.index(@store.position_id) || 0) + 1
      runs = matching_runs
      @run_keys = runs.map(&.id)
      # Reserve the state column before fitting names. API state strings (for
      # example Finished With Error) otherwise push it outside the sidebar.
      width = Math.max(8, @runs_view.awidth - @runs_view.ihorizontal - 1)
      state_width = Math.min(Math.max(5, runs.max_of? { |run| display_width(run.state) } || 5), Math.max(5, width - 6))
      name_width = Math.max(1, width - state_width - 2)
      dates = runs.map { |run| run.started_at.try(&.to_local.to_s("%Y-%m-%d")) }.uniq!
      shared_date = dates.first? if dates.size == 1
      rows = [["State", fit_cell("Run / sample", name_width)]] + runs.map do |run|
        label = "#{run.start_label(show_date: shared_date.nil?)} #{run.label}"
        [fit_cell(run.state, state_width), fit_cell(label, name_width)]
      end
      @runs_view.rows = rows unless @runs_view.rows == rows
      @runs_view.current_index = (@run_keys.index(@store.run_id) || 0) + 1 unless runs.empty?
      @runs_view.label = "Runs: #{MinknowTui.text(@store.position_id || "Host")}#{shared_date ? " · #{shared_date}" : ""}"
    end

    private def display_width(value : String) : Int32
      Tput::Unicode.str_width(value, @window.full_unicode?)
    end

    private def fit_cell(value : String, width : Int32) : String
      return value if display_width(value) <= width
      bytes = Tput::Unicode.leading_byte_len(value, Math.max(0, width - 1), @window.full_unicode?)
      value.byte_slice(0, bytes) + "…"
    end

    private def update_detail
      unless position = @store.position
        @overview.content = "\n  Host overview\n\n  #{@store.host_description}\n  Manager: #{@store.endpoint}\n  Core: #{@store.version}\n  Distribution: #{@store.distribution}\n  Positions: #{@store.positions.size}\n  Connection: #{@store.connection}\n\n  Disk space (last known):\n  #{@store.disk}\n\n  Select a position with p or the Positions pane.\n  History is limited to runs available from the MinKNOW API."
        {@yield_text, @quality_text, @device_text, @activity_text}.each(&.content=("Press p to select a position."))
        clear_charts
        return
      end
      metrics = @store.detail
      update_overview(position, metrics)
      update_device(position, metrics)
      unless @store.acquisition_id
        {@yield_text, @quality_text, @activity_text}.each(&.content=("No acquisition available for this selection."))
        clear_charts
        return
      end
      update_statistics(position, metrics)
      update_activity(position, metrics)
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

    private def present(value : String) : String
      value.empty? ? "—" : MinknowTui.text(value)
    end

    private def run_timing(run : Run, position : Position, metrics : Metrics) : String
      return "Run elapsed: #{run.elapsed(nil)}" if run.ended_at || run.id != position.current_run
      now = position.connected? ? Time.utc : position.updated_at
      timing = "Run elapsed: #{run.elapsed(now)}"
      return timing unless now && (until_time = metrics.remaining_until)
      seconds = Math.max(0, (until_time - now).total_seconds.to_i64)
      value = "%02d:%02d:%02d" % {seconds // 3600, seconds // 60 % 60, seconds % 60}
      "#{timing}    Remaining: #{value}#{metrics.remaining_estimated? ? " (estimate)" : ""}"
    end

    private def update_overview(position : Position, metrics : Metrics)
      @overview.content = String.build do |io|
        if run = @store.run
          io << "  " << run.state
          io << " / " << run.phase unless run.phase == "Unknown"
          io << "    Experiment: " << run.experiment unless run.experiment.empty?
          io << "\n  " << run_timing(run, position, metrics)
          io << "\n\n  Acquired reads: " << MinknowTui.number(metrics.reads)
          io << "\n  Estimated yield: " << MinknowTui.number(metrics.estimated_bases, "b")
          if metrics.basecalling_enabled == false
            io << "\n  Basecalling disabled"
          else
            io << "\n  Pass yield: " << MinknowTui.number(metrics.pass_bases, "b") << "    Fail: " << MinknowTui.number(metrics.fail_bases, "b")
            io << "\n  N50 basecalled: " << MinknowTui.number(metrics.n50, "b")
          end
          io << "\n  N50 estimated: " << MinknowTui.number(metrics.estimated_n50, "b")
          io << "\n\n  " << temperature_text(position, metrics) if metrics.temperature || position.live.temperature
          issue = capability(position, "summary", received: !metrics.updated_at.nil?)
          io << "\n  " << issue unless issue.empty?
        else
          io << "  No run available."
        end
        io << "\n  Position API: " << position_api(position) unless position.connected?
        io << "\n  " << position.error unless position.error.empty?
      end
    end

    private def position_api(position : Position) : String
      position.connected? ? "Available" : (position.capabilities["flow_cell"]? || position.capabilities["activity"]? || "Connecting")
    end

    private def inspect_details
      p = @store.position
      pores = @store.tab == 4
      text = String.build do |io|
        if p
          io << "Position: " << p.name << "  " << p.device_type
          io << " [SIMULATED]" if p.simulated?
          io << "\nDevice: " << p.device << "  " << p.status
          io << "\nCurrent flow cell: " << present(p.flow_cell) << "  " << p.product << " (" << p.channels << " channels)"
          io << "\nSoftware: " << p.software << "  " << p.error
          io << "\nPosition API: " << position_api(p) << "\n"
          run = pores ? p.runs[p.current_run]? : @store.run
          run_details(io, run) if run
          io << "\nAcquisition: " << ((pores ? p.current_acquisition : @store.acquisition_id) || "none") << "\n"
          acquisition_details(io, @store.detail) if !pores && @store.acquisition_id
        end
        io << "\nManager: " << @store.endpoint << "  " << @store.connection << "\nCore: " << @store.version
        io << "\nDistribution: " << @store.distribution << "\n"
        if p
          io << "Position endpoint: " << @store.endpoint.sub(/:\d+$/, "") << ":" << (p.port || "unavailable") << "\n"
          p.capabilities.each { |key, value| io << key << ": " << value << "\n" }
        end
        @store.capabilities.each { |key, value| io << key << ": " << value << "\n" }
      end
      track TextDialog.new(@window, pores ? "Current device details" : "Details", text.strip)
    end

    private def run_details(io : IO, run : Run)
      io << "\nSample: " << present(run.sample) << "\nExperiment: " << present(run.experiment)
      io << "\nStarted: " << (run.started_at.try(&.to_local.to_s) || "—")
      io << "\nRun: " << run.id << "\nProtocol: " << present(run.protocol)
      io << "\nKit: " << present(run.kit) << "\nOutput: " << present(run.output) << "\n"
    end

    private def acquisition_details(io : IO, m : Metrics)
      io << "Basecall model: " << present(m.basecall_model) << "\nBarcoding kits: " << present(m.barcoding_kits)
      io << "\nAlignment reference: " << present(m.alignment_reference) << "\nAlignment BED: " << present(m.alignment_bed)
      io << "\nPore occupancy: " << percentage(m.occupancy)
      io << "\nSummary received: " << (m.updated_at.try(&.to_local.to_s("%H:%M:%S %Z")) || "not received") << "\n"
      unless m.channel_states.empty?
        io << "\nChannel time fractions\n"
        m.channel_states.each { |name, value| io << name << ": " << ("%.1f%%" % value) << "\n" }
      end
    end

    private def update_statistics(position : Position, metrics : Metrics)
      histogram_reads = metrics.histogram.empty? ? "—" : MinknowTui.number(metrics.histogram.sum(&.count))
      @yield_text.content = "Pass: #{MinknowTui.number(metrics.pass_bases, "b")}  Fail: #{MinknowTui.number(metrics.fail_bases, "b")}  Estimated: #{MinknowTui.number(metrics.estimated_bases, "b")}\n" +
                            "Acquired reads: #{MinknowTui.number(metrics.reads)}    Basecalls pass / fail: #{MinknowTui.number(metrics.pass_calls)} / #{MinknowTui.number(metrics.fail_calls)}\n" +
                            "Basecaller processed / skipped: #{metrics.basecalling_enabled == false ? "Disabled" : percentage(metrics.processed)}\n#{capability(position, "yield", received: !metrics.estimated.points.empty?)}"
      @quality_text.content = case @quality_mode
                              when 0
                                title = qscore_enabled? ? "Read length (1/3)" : "Read length"
                                "#{title}  ·  #{metrics.histogram_unit}  ·  #{histogram_reads} reads\n" +
                                  "N50 basecalled: #{MinknowTui.number(metrics.n50, "b")}  Estimated: #{MinknowTui.number(metrics.estimated_n50, "b")}\n" +
                                  "Y: read counts  ·  #{full_histogram? ? "Full range" : "Trim 1% each end"}#{metrics.basecalling_enabled == false ? "  ·  Basecalling off" : ""}\n#{capability(position, "read_lengths", received: !metrics.histogram.empty?)}"
                              when 1
                                "Q score histogram (2/3)  ·  read counts\nModal Q: #{MinknowTui.number(metrics.qscore_modal)}\n#{capability(position, "qscore_histogram", received: !metrics.qscore_histogram.empty?)}"
                              else
                                "Q score over time (3/3)  ·  approximate median per 60 min\n" +
                                  "Latest median Q: #{MinknowTui.number(metrics.qscore_medians.points.last?.try(&.[1]))}\n#{capability(position, "qscore_time", received: !metrics.qscore_medians.points.empty?)}"
                              end
    end

    private def update_device(position : Position, metrics : Metrics)
      key, series = @device_mode == 0 ? {"temperature_history", metrics.temperatures} : {"bias_voltage", metrics.bias_voltages}
      @device_text.content = "Current device: #{position.device}  #{position.device_type}  #{position.status}\n" +
                             "Current flow cell: #{present(position.flow_cell)}  #{position.product} (#{position.channels} channels)\n" +
                             "#{temperature_text(position, metrics)}  #{position.error}\n#{capability(position, key, received: !series.points.empty?)}"
    end

    private def update_activity(position : Position, metrics : Metrics)
      return unless @store.tab == 5
      buckets = metrics.activity_buckets(@activity_detailed, @activity_percent)
      if buckets.empty?
        @activity_text.content = "Pore activity: no data yet\n#{capability(position, "duty_time")}"
        @activity_chart.values = [] of Array(Float64)
        @last_activity_signature = nil
        return
      end
      signature = {metrics.duty_buckets, metrics.state_styles, metrics.sample_rate, @activity_detailed, @activity_percent, @window.awidth}.hash
      if signature != @last_activity_signature
        @last_activity_signature = signature
        names = activity_names(buckets, metrics)
        @activity_chart.segment_labels = names.map { |name| @activity_detailed ? metrics.state_styles[name]?.try(&.label) || name : name }
        @activity_chart.colors = names.map { |name| activity_color(name, metrics) }
        @activity_chart.maximum = @activity_percent ? 100.0 : nil
        @activity_chart.values = buckets.map { |bucket| names.map { |name| bucket.states[name]? || 0.0 } }
        @activity_chart.labels = nil
      end
      unit = @activity_percent ? "State time equivalent (%)" : metrics.sample_rate ? "Channel-seconds" : "State samples"
      visible = buckets.last(Math.max(1, @activity_chart.awidth))
      @activity_text.content = "Pore activity: #{@activity_detailed ? "Detailed" : "Grouped"} | #{unit}\n" +
                               "Elapsed: #{visible.first.start // 60}–#{visible.last.finish // 60} min; #{buckets.last.finish >= 48 * 60 ? 5 : 1} min buckets\n" +
                               "Pore occupancy: #{percentage(metrics.occupancy)}\n#{capability(position, "duty_time", received: true)}"
    end

    private def activity_names(buckets : Array(DutyBucket), metrics : Metrics) : Array(String)
      buckets.flat_map(&.states.keys).uniq!.sort_by! do |name|
        if @activity_detailed
          {metrics.state_styles[name]?.try(&.order) || UInt32::MAX, name}
        else
          order = metrics.state_styles.values.select { |style| style.group == name }.min_of?(&.order) || UInt32::MAX
          {order, name}
        end
      end
    end

    private def activity_color(name : String, metrics : Metrics) : String
      style = if @activity_detailed
                metrics.state_styles[name]?
              else
                metrics.state_styles.values.find { |item| item.group == name }
              end
      color = @activity_detailed ? style.try(&.terminal_colour) : style.try(&.group_terminal_colour)
      color || PoreMap.appearance(name)[1]
    end

    private def update_graph_visibility
      selected = !@store.acquisition_id.nil?
      @yield_chart.visible = selected
      @activity_chart.visible = selected
      @histogram.visible = selected && @quality_mode == 0
      @qscore_histogram.visible = selected && @quality_mode == 1
      @qscore_chart.visible = selected && @quality_mode == 2
      @temperature_chart.visible = selected && @device_mode == 0
      @bias_chart.visible = selected && @device_mode == 1
    end

    private def capability(p : Position, key : String, received = false) : String
      return "No acquisition selected." unless @store.acquisition_id
      value = p.capabilities["detail.#{key}"]?
      return received ? "" : "Waiting for API data" unless value
      value.starts_with?("Available") ? "" : value
    end

    private def clear_charts
      @yield_chart.clear_series
      @temperature_chart.clear_series
      @bias_chart.clear_series
      @qscore_chart.clear_series
      @histogram.values = [] of Float64
      @qscore_histogram.values = [] of Float64
      @activity_chart.values = [] of Array(Float64)
      @last_activity_signature = nil
      @last_chart_signature = ""
    end

    private def update_charts(m : Metrics)
      # Avoid rebuilding graph chrome on every clock tick.
      signature = {m.pass.points, m.fail.points, m.estimated.points, m.temperatures.points, m.bias_voltages.points,
                   m.qscore_medians.points, m.histogram, m.qscore_histogram, full_histogram?, @window.awidth}.hash.to_s
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
      @bias_chart.clear_series
      @bias_chart.add_line("Bias voltage", m.bias_voltages.points, Theme::TURQUOISE) unless m.bias_voltages.points.empty?
      @bias_chart.refresh
      @qscore_chart.clear_series
      # Keep flat/singleton data away from the bottom edge of the raster.
      @qscore_chart.axis_y.minimum = m.qscore_medians.points.min_of?(&.[1]).try { |value| value - 0.5 }
      @qscore_chart.axis_y.maximum = m.qscore_medians.points.max_of?(&.[1]).try { |value| value + 0.5 }
      @qscore_chart.axis_x.maximum = m.qscore_medians.points.size == 1 ? m.qscore_medians.points.first[0] + 60 : nil
      unless m.qscore_medians.points.empty?
        if m.qscore_medians.points.size == 1
          @qscore_chart.add_scatter("Median Q", m.qscore_medians.points, Theme::TURQUOISE)
        else
          @qscore_chart.add_line("Median Q", m.qscore_medians.points, Theme::TURQUOISE)
        end
      end
      @qscore_chart.refresh
      capacity = Math.max(1, (@window.awidth - (compact? ? 4 : 48)) // 5)
      bars = m.histogram_bars(capacity, full_histogram?)
      @histogram.values = bars.map(&.count)
      @histogram.labels = bars.map(&.label)
      qbars = m.qscore_bars(capacity)
      @qscore_histogram.values = qbars.map(&.count)
      @qscore_histogram.labels = qbars.map(&.label)
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
      previous_focus = @window.focused
      @dialog = dialog
      dialog.on(CT::Event::Finished) do
        @dialog = nil
        dialog.destroy
        previous_focus.try { |widget| widget.focus if widget.visible_in_tree? }
        refresh
      end
      dialog.open
    end

    def pick_position
      values = @store.positions.values.sort_by!(&.name).select { |position| "#{position.name} #{position.status} #{position.error}".downcase.includes?(@store.filter.downcase) }
      keys = [nil.as(String?)] + values.map { |position| position.name.as(String?) }
      labels = ["Host overview"] + values.map { |position| "#{MinknowTui.text(position.name)}  #{position.status}" }
      picker = Picker.new(@window, "Positions", labels, keys.index(@store.position_id) || 0) do |i|
        id = keys[i]
        @store.select_position(id) if id.nil? || @store.positions.has_key?(id)
      end
      track picker
    end

    def pick_run
      unless position = @store.position
        return track TextDialog.new(@window, "Runs", "Press p to select a position first.")
      end
      values = matching_runs.reject { |run| run.id == position.current_run }
      current = position.runs[position.current_run]?
      labels = [current ? "Follow current run  ·  #{current.start_label}  #{current.label}" : "Follow current run  ·  waiting for next run"]
      names = values.map { |run| "#{run.start_label}  #{run.label}  #{run.state}" }
      counts = names.tally
      values.each_with_index do |run, i|
        row = names[i]
        row += "  #{run.id}" if counts[row] > 1
        labels << "#{run.id == @store.run_id ? "› " : "  "}#{row}"
      end
      picker = Picker.new(@window, "Runs — #{position.name}", labels) do |i|
        next unless position == @store.position
        if i == 0
          @store.follow_current_run
        elsif position.runs.has_key?(values[i - 1].id)
          @store.select_run(values[i - 1].id)
        end
        show_tab(0) if @store.tab == 4
      end
      track picker
    end

    def pick_acquisition
      return if @store.tab == 4
      run = @store.run
      if !run || run.acquisitions.empty?
        return track TextDialog.new(@window, "Acquisitions", "No acquisitions available for this selection.")
      end
      values = run.acquisitions.dup
      labels = values.map_with_index { |id, i| "#{i + 1}/#{values.size}  #{id}#{id == @store.position.try(&.current_acquisition) ? "  (live)" : ""}" }
      position = @store.position
      picker = Picker.new(@window, "Acquisitions — #{run.label}", labels, values.index(@store.acquisition_id) || 0) do |i|
        id = values[i]
        @store.select_acquisition(id) if @store.position == position && @store.run_id == run.id && @store.run.try(&.acquisitions.includes?(id))
      end
      track picker
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
      when '1'..'6'
        show_tab(event.char.to_i - '1'.to_i)
      when 'p' then pick_position
      when 'r' then pick_run
      when 'a' then pick_acquisition
      when 'i' then inspect_details
      when '?' then track HelpDialog.new(@window)
      when '/' then filter_dialog
      else
        return unless view_key(event.char) || control_key(event.key)
      end
      event.accept
      @store.changed
      refresh
    end

    private def view_key(char : Char?) : Bool
      if char == 't'
        return false unless trace = @store.open_trace(@pores.selected_channel)
        dialog = SignalDialog.new(@window, trace, @store.connection.includes?("[DEMO]"))
        dialog.on(CT::Event::Finished) { @store.close_trace }
        track dialog
        return true
      end
      graph_key(char)
    end

    private def graph_key(char : Char?) : Bool
      return false unless @store.acquisition_id
      case {@store.tab, char}
      when {2, 'h'}
        return false unless @quality_mode == 0
        @full_histogram = !@full_histogram
      when {2, 'v'}
        return false unless qscore_enabled?
        @quality_mode = (@quality_mode + 1) % 3
      when {3, 'v'}
        @device_mode = (@device_mode + 1) % 2
      when {5, 'd'}
        @activity_detailed = !@activity_detailed
      when {5, 'u'}
        @activity_percent = !@activity_percent
      else
        return false
      end
      true
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
