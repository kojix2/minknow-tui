require "spec"
require "../src/minknow_tui/demo"
require "../src/minknow_tui/ui"

Crysterm::Config.set "screen.headless", Crysterm::Headless::Always

private def with_ui(width, height, iterm2 = false, &)
  store = MinknowTui::Store.new
  demo = MinknowTui::Demo.new(store)
  window = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false, terminfo: Unibilium.from_terminal("xterm-256color"), force_unicode: true)
  window.tput.emulator.iterm2 = true if iterm2
  interface = MinknowTui::UI.new(store, window)
  window.repaint
  begin
    yield store, demo, interface, window
  ensure
    demo.stop
    window.destroy
  end
end

describe "minknow-tui headless UI" do
  it "fits Positions to a few devices and gives the remaining sidebar to run history" do
    with_ui(120, 36) do |store, _, interface, window|
      positions = interface.positions_view
      window.dump(positions.aleft, positions.aleft + positions.awidth, positions.atop, positions.atop + positions.aheight).to_s.should contain("X4")
      store.positions.reject! { |name, _| name != "X1" }
      interface.refresh
      window.repaint
      interface.positions_view.aheight.should eq(5)
      interface.runs_view.aheight.should be > interface.positions_view.aheight
      window.dump.to_s.should contain("X1")
      sidebar = interface.positions_view.parent.as(Crysterm::Widget::Splitter)
      sidebar.dividers.first.position = 7
      interface.refresh
      window.repaint
      interface.positions_view.aheight.should eq(7)
      window.unpin_width
      window.unpin_height
      window.emit(Crysterm::Event::DeviceResize, Crysterm::Size.new(140, 44))
      interface.refresh
      window.repaint
      interface.positions_view.aheight.should eq(7)
      20.times do |i|
        name = "extra-#{i}"
        store.positions[name] = MinknowTui::Position.new(name)
      end
      interface.refresh
      window.repaint
      interface.positions_view.aheight.should eq(8)
      interface.positions_view.focus
      window.press(Tput::Key::End)
      store.position_id.should eq("extra-9")
    end
  end

  [{120, 36}, {80, 24}].each do |size|
    it "keeps the overview concise and exposes full settings in Details at #{size}" do
      with_ui(size[0], size[1]) do |store, _, interface, window|
        run = store.run || fail "Expected a demo run"
        acquisition = store.acquisition_id || fail "Expected a demo acquisition"
        store.detail.barcoding_kits = "EXP-NBD114"
        store.detail.basecall_model = "dna_r10.4.1_e8.2_400bps_sup"
        store.detail.alignment_reference = "/data/reference.fa"
        store.detail.alignment_bed = "/data/targets.bed"
        interface.refresh
        window.repaint
        visible = window.dump.to_s
        visible.should contain("Sample: sample-A")
        visible.should contain("Started:")
        visible.should contain("Pass yield:")
        content = interface.overview.content
        [run.kit, "dna_r10.4.1_e8.2_400bps_sup", "Current flow cell: ABC12340", "Pore occupancy:"].each do |value|
          content.should contain(value)
        end
        content.should_not contain(run.id)
        content.should_not contain("Alignment BED:")
        interface.overview.focus
        window.press(Tput::Key::End)
        window.repaint
        window.dump.to_s.should contain("Current flow cell: ABC12340")
        window.press('i')
        details = interface.dialog.as(MinknowTui::TextDialog).body.content
        [run.id, run.protocol, run.output, acquisition, "EXP-NBD114", "/data/reference.fa", "/data/targets.bed"].each do |value|
          details.should contain(value)
        end
      end
    end
  end

  it "shows device types and short model names in Positions and its picker" do
    with_ui(120, 36) do |store, _, interface, window|
      {"Minion" => "MinION", "Promethion 2 Solo" => "P2 Solo", "P2 Solo" => "P2 Solo",
       "Minion Mk1c" => "Mk1C", "Gridion" => "GridION"}.each do |type, label|
        store.positions["X1"].device_type = type
        interface.refresh
        window.repaint
        view = interface.positions_view
        text = window.dump(view.aleft, view.aleft + view.awidth, view.atop, view.atop + view.aheight).to_s
        text.should contain(label)
        text.should contain("Sequencing")
        text.should contain("Hardware Error")
        window.press('p')
        interface.dialog.as(MinknowTui::Picker).list.items.join.should contain("X1  #{label}")
        window.press(Tput::Key::Escape)
      end
    end
  end

  [{120, 36}, {80, 24}].each do |size|
    it "previews run history without changing selection until Enter at #{size}" do
      with_ui(size[0], size[1]) do |store, _, interface, window|
        position = store.positions["X1"]
        live, old, older = position.history
        old.output = "/data/" + "sequencing-output/" * 24 + old.sample
        old.started_at = Time.local(2026, 11, 18, 21, 8)
        old.ended_at = old.started_at.try { |start| start + 10.minutes }
        unless interface.compact?
          interface.refresh
          window.repaint
          view = interface.runs_view
          text = window.dump(view.aleft, view.aleft + view.awidth, view.atop, view.atop + view.aheight).to_s
          ["Completed", "11/18 21:08", "00:10:00", "experiment-01", "SQK-LSK114", "2 acq"].each { |value| text.should contain(value) }
          interface.runs_view.focus
          window.press(Tput::Key::Down)
          store.run_id.should eq(old.id)
          window.press(Tput::Key::Down)
          store.run_id.should eq(older.id)
          window.press(Tput::Key::Up)
          store.run_id.should eq(old.id)
          store.follow_current_run
          interface.refresh
        end
        window.press('r')
        picker = interface.dialog.as(MinknowTui::Picker)
        window.repaint
        window.press(Tput::Key::Down)
        preview = picker.preview || fail "Expected a history preview"
        [old.id, old.output, old.kit, old.experiment, "00:10:00", "Acquisitions: 2"].each { |value| preview.content.should contain(value) }
        store.run_id.should eq(live.id)
        window.press(Tput::Key::Tab)
        window.focused.should eq(preview)
        window.press(Tput::Key::End)
        preview.child_base.should be > 0
        window.press(Tput::Key::Escape)
        store.run_id.should eq(live.id)
        window.press('r')
        window.repaint
        window.press(Tput::Key::Down)
        window.press(Tput::Key::Tab)
        window.press(Tput::Key::Enter)
        store.run_id.should eq(old.id)
      end
    end
  end

  it "opens the selected live pore trace and restores the pore grid on Escape" do
    with_ui(80, 24) do |store, demo, interface, window|
      window.press('5')
      window.press(Tput::Key::Right)
      window.press('t')
      trace = store.trace || fail "Expected a trace for the selected channel"
      trace.channel.should eq(2)
      dialog = interface.dialog.as(MinknowTui::SignalDialog)
      dialog.info.content.should contain("Waiting")
      demo.update
      interface.refresh
      window.repaint
      dialog.chart.series.first.points.size.should eq(MinknowTui::SignalTrace::LIMIT)
      window.dump.to_s.should contain("Time within trace (ms)")
      window.press(Tput::Key::Escape)
      trace.scope.active?.should be_false
      store.trace.should be_nil
      interface.pores.selected_channel.should eq(2)
      window.focused.should eq(interface.pores.grid)
      store.select_position("X2")
      interface.refresh
      window.press('t')
      interface.dialog.should be_nil
    end
  end

  it "keeps run states visible beside long sample names in the sidebar" do
    with_ui(120, 36) do |store, _, interface, window|
      view = interface.runs_view
      window.dump(view.aleft, view.aleft + view.awidth, view.atop, view.atop + view.aheight).to_s.should contain(store.run.try(&.label) || "sample")
      runs = store.positions["X1"].history
      runs.each(&.sample=("長いサンプル名" * 10))
      runs[0].state = "Running"
      runs[1].state = "Finished With Error"
      interface.refresh
      window.repaint
      text = window.dump(view.aleft, view.aleft + view.awidth, view.atop, view.atop + view.aheight).to_s
      text.should contain("Running")
      text.should contain("Finished With Error")
      text.should contain("…")
      window.unpin_width
      window.unpin_height
      window.emit(Crysterm::Event::DeviceResize, Crysterm::Size.new(140, 44))
      interface.refresh
      window.repaint
      window.dump(view.aleft, view.aleft + view.awidth, view.atop, view.atop + view.aheight).to_s.should contain("Finished With Error")
    end
  end

  it "draws a lone Q-score sample as a marker without inventing more samples" do
    with_ui(120, 36) do |store, _, interface, window|
      store.detail.qscore_medians.replace([{0.0, 10.31}])
      window.press('3')
      window.press('v')
      window.press('v')
      interface.refresh
      window.repaint
      chart = interface.qscore_chart
      chart.series.first.kind.scatter?.should be_true
      chart.series.first.points.should eq([{0.0, 10.31}])
      plot = chart.plot
      plotted = (plot.atop...plot.atop + plot.aheight).any? do |y|
        (plot.aleft...plot.aleft + plot.awidth).any? do |x|
          cell = window.cell_rows[y][x]
          rgb = Crysterm::Attr.unpack_color(Crysterm::Attr.fg(cell.attr))
          red, green, blue = (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255
          cell.char != ' ' && green > blue && green > red + 20
        end
      end
      plotted.should be_true
      window.dump.to_s.should contain("Latest median Q: 10.31")
      store.detail.qscore_medians.put(3600, 11.0)
      interface.refresh
      chart.series.first.kind.line?.should be_true
    end
  end

  it "shows the position API as available through activity and preserves authentication errors after disconnection" do
    with_ui(120, 36) do |store, _, interface, window|
      position = store.positions["X1"]
      position.capabilities["flow_cell"] = "Unsupported"
      position.capabilities["activity"] = "Available"
      position.connected = true
      interface.refresh
      window.press('i')
      details = interface.dialog.as(MinknowTui::TextDialog).body.content
      details.should contain("Position API: Available")
      details.should contain("flow_cell: Unsupported")
      window.press(Tput::Key::Escape)

      position.connected = false
      position.capabilities["flow_cell"] = "Authentication required"
      position.capabilities["activity"] = "Authentication required"
      interface.refresh
      interface.overview.content.should contain("Position API: Authentication required")
    end
  end

  it "cancels pickers without changing selection, including empty pickers" do
    with_ui(120, 36) do |store, _, interface, window|
      selected = {store.position_id, store.run_id, store.acquisition_id, store.generation}
      ['p', 'r', 'a'].each do |key|
        window.press(key)
        interface.dialog.should_not be_nil
        window.press(Tput::Key::Down) if key == 'r'
        window.press(Tput::Key::Escape)
        interface.dialog.should be_nil
        {store.position_id, store.run_id, store.acquisition_id, store.generation}.should eq(selected)
      end
      store.select_position(nil)
      interface.refresh
      ['r', 'a'].each do |key|
        window.press(key)
        window.press(Tput::Key::Escape)
        interface.dialog.should be_nil
        store.position_id.should be_nil
      end
    end
  end

  it "moves list selection with vi keys, changes focus, and filters using text input" do
    with_ui(120, 36) do |store, _, interface, window|
      interface.positions_view.focus
      window.press('j')
      store.position_id.should eq("X2")
      before = window.focused
      window.press(Tput::Key::Tab)
      window.focused.should_not be(before)
      window.press('/')
      window.type("X4")
      window.press(Tput::Key::Enter)
      store.filter.should eq("X4")
      interface.positions_view.rows.size.should eq(3)
      window.press(Tput::Key::Escape)
      store.filter.should eq("")
    end
  end

  it "keeps the event viewport stable while scrolled up and resumes at End" do
    with_ui(120, 36) do |store, _, interface, window|
      80.times { |i| store.event("X1", "INFO", "Message #{i}") }
      interface.refresh
      window.repaint
      interface.events_view.focus
      window.press(Tput::Key::Home)
      window.repaint
      before = interface.events_view.child_base
      store.event("X1", "INFO", "New message")
      interface.refresh
      window.repaint
      interface.events_view.child_base.should eq(before)
      window.press(Tput::Key::End)
      interface.events_view.child_base.should be > before
    end
  end

  it "folds the sidebars on resize and moves focus out of hidden panes" do
    with_ui(120, 36) do |_, _, interface, window|
      interface.runs_view.focus
      window.unpin_width
      window.unpin_height
      window.emit(Crysterm::Event::DeviceResize, Crysterm::Size.new(80, 24))
      interface.refresh
      window.repaint
      interface.compact?.should be_true
      window.focused.should_not be(interface.runs_view)
      window.dump.to_s.should contain("q quit")
    end
  end

  [{120, 36}, {80, 24}].each do |size|
    it "distinguishes same-sample history, live pores and following at #{size}" do
      with_ui(size[0], size[1]) do |store, demo, interface, window|
        position = store.positions["X1"]
        live, old, older = position.history
        live.sample = old.sample = "tui-playback"
        live.started_at = Time.local(2026, 11, 18, 21, 34)
        start = Time.local(2026, 11, 18, 21, 8)
        old.started_at = start
        old.ended_at = start + 10.minutes
        old.state = "Finished With Error"
        older.started_at = start - 1.hour
        interface.refresh
        window.repaint
        unless interface.compact?
          sidebar = interface.runs_view
          text = window.dump(sidebar.aleft, sidebar.aleft + sidebar.awidth, sidebar.atop, sidebar.atop + sidebar.aheight).to_s
          text.should contain("11/18 21:08")
          text.should contain("tui-playback")
        end
        window.press('r')
        window.press(Tput::Key::Down)
        window.press(Tput::Key::Enter)
        store.run_id.should eq(old.id)
        store.detail.reads = 622_i64
        interface.refresh
        window.repaint
        window.dump.to_s.should contain("HISTORY X1  ·  11/18 21:08")
        interface.overview.content.should contain("622")
        interface.overview.content.should contain("Run elapsed: 00:10:00")
        old.ended_at = nil
        interface.refresh
        interface.overview.content.should contain("Run elapsed: —")
        interface.overview.content.should_not contain(old.id)
        window.press('i')
        details = interface.dialog.as(MinknowTui::TextDialog).body
        details.content.should contain(old.id)
        details.content.should contain(old.acquisitions.last)
        window.press(Tput::Key::End)
        window.repaint
        details.child_base.should be > 0
        window.press(Tput::Key::Escape)
        ['2', '3', '4', '6'].each do |key|
          window.press(key)
          window.repaint
          window.dump.to_s.should contain("HISTORY X1  ·  11/18 21:08")
        end
        window.press('5')
        demo.update
        interface.refresh
        window.repaint
        window.dump.to_s.should contain("LIVE X1  ·  Current channels")
        window.press('i')
        details = interface.dialog.as(MinknowTui::TextDialog).body
        details.content.should contain(live.acquisitions.last)
        details.content.should_not contain(old.id)
        window.press(Tput::Key::Escape)
        window.press('1')
        store.run_id.should eq(old.id)
        window.press('5')
        window.press('r')
        window.press(Tput::Key::Enter)
        interface.tabs.current_index.should eq(0)
        store.run_id.should eq(live.id)
        store.acquisition_id.should eq(position.current_acquisition)
        window.repaint
        window.dump.to_s.should contain("LIVE X1  ·  11/18 21:34")
      end
    end

    it "renders pore backgrounds with contrasting letters and isolated selection at #{size}" do
      with_ui(size[0], size[1]) do |store, _, interface, window|
        position = store.positions["X1"]
        position.channels = 12_u32
        position.pore_states.clear
        position.state_styles.clear
        samples = [
          {"strand", 'S', "123456", 0x123456, 0xffffff},
          {"pore", 'P', "#f5f5f5", 0xf5f5f5, 0x000000},
          {"custom", '?', "808080", 0x808080, 0x000000},
          {"unblocking", 'U', "bad{tag}", 0xa53f97, 0xffffff},
          {"no_pore", '-', "", 0x90c6e7, 0x000000},
          {"saturated", '!', "", 0x68767e, 0xffffff},
          {"adapter", 'A', "", 0xede797, 0x000000},
          {"unavailable", '!', "", 0x54b8b1, 0x000000},
          {"multiple", 'M', "", 0xf57e20, 0x000000},
        ]
        samples.each_with_index do |(name, _, colour, _, _), index|
          position.update_channel(index + 1, MinknowTui::ChannelState.new(name))
          position.state_styles[name] = MinknowTui::StateStyle.new(name, colour, "", 0_u32)
        end
        window.press('5')
        interface.refresh
        window.repaint
        grid = interface.pores.grid
        samples.each_with_index do |(_, glyph, _, background, foreground), index|
          cell = window.cell_rows[grid.atop][grid.aleft + 5 + index + index // 8]
          cell.char.should eq(glyph)
          Crysterm::Attr.unpack_color(Crysterm::Attr.bg(cell.attr)).should eq(background)
          Crysterm::Attr.unpack_color(Crysterm::Attr.fg(cell.attr)).should eq(foreground)
          (Crysterm::Attr.flags(cell.attr) & Crysterm::Attr::UNDERLINE != 0).should eq(index == 0)
        end
        # The group separator and missing channels must not inherit a state background.
        row = window.cell_rows[grid.atop]
        row[grid.aleft + 13].char.should eq(' ')
        row[grid.aleft + 15].char.should eq('.')
        Crysterm::Attr.bg(row[grid.aleft + 13].attr).should eq(Crysterm::Attr.bg(row[grid.aleft + 15].attr))
        window.press(Tput::Key::Right)
        window.repaint
        (Crysterm::Attr.flags(row[grid.aleft + 5].attr) & Crysterm::Attr::UNDERLINE).should eq(0)
        (Crysterm::Attr.flags(row[grid.aleft + 6].attr) & Crysterm::Attr::UNDERLINE).should_not eq(0)

        # Metadata can arrive after channel states; both grid and legend must repaint.
        position.state_styles["strand"] = MinknowTui::StateStyle.new("Sequencing", "ffffff", "", 0_u32)
        interface.refresh
        window.repaint
        cell = window.cell_rows[grid.atop][grid.aleft + 5]
        Crysterm::Attr.unpack_color(Crysterm::Attr.bg(cell.attr)).should eq(0xffffff)
        Crysterm::Attr.unpack_color(Crysterm::Attr.fg(cell.attr)).should eq(0x000000)
        legend = interface.pores.legend
        cell = window.cell_rows[legend.atop + 1][legend.aleft]
        cell.char.should eq('S')
        Crysterm::Attr.unpack_color(Crysterm::Attr.bg(cell.attr)).should eq(0xffffff)
        Crysterm::Attr.unpack_color(Crysterm::Attr.fg(cell.attr)).should eq(0x000000)
      end
    end

    it "navigates live channels and a 3000-channel device at #{size}" do
      with_ui(size[0], size[1]) do |store, demo, interface, window|
        window.press('5')
        demo.update
        interface.refresh
        window.repaint
        window.dump.to_s.should contain("LIVE X1")
        window.dump.to_s.should contain("Channel 1/512")
        window.press(Tput::Key::Right)
        interface.pores.selected_channel.should eq(2)
        window.press('h')
        interface.pores.selected_channel.should eq(1)
        window.press(Tput::Key::End)
        interface.pores.selected_channel.should eq(512)
        store.select_run("demo-X1-protocol-1")
        demo.update
        interface.refresh
        window.repaint
        window.press('i')
        interface.dialog.as(MinknowTui::TextDialog).body.content.should contain("demo-X1-protocol-0-sequencing")
        window.press(Tput::Key::Escape)
        store.select_position("X2")
        demo.update
        interface.refresh
        window.repaint
        window.press(Tput::Key::End)
        interface.pores.selected_channel.should eq(3000)
        interface.pores.grid.child_base.should be > 0
        window.press(Tput::Key::Home)
        interface.pores.selected_channel.should eq(1)
        window.press('3')
        interface.tabs.current_index.should eq(2)
        interface.refresh
        window.repaint
        interface.pores.visible?.should be_false
        window.dump.to_s.should_not contain("LIVE X2")
        window.dump.to_s.should contain("Read length")
        window.press('i')
        interface.dialog.as(MinknowTui::TextDialog).body.content.should contain("Kit: SQK-LSK114")
        window.press(Tput::Key::Escape)
      end
    end

    it "switches iTerm2 tabs immediately without image layers at #{size}" do
      backend = Crysterm::Config.media_backend
      Crysterm::Config.set "media.backend", Crysterm::Widget::Media::Backend::Auto
      with_ui(size[0], size[1], iterm2: true) do |store, demo, interface, window|
        output = window.output.as(IO::Memory)
        [1, 2, 3, 0, 3, 1, 0].each do |tab|
          output.clear
          interface.tabs.current_index = tab
          store.tab.should eq(tab)
          output.to_s.should contain("\e[2J")
          demo.update
          interface.refresh
          window.repaint
          emitted = output.to_s
          emitted.should_not contain("\e]1337;File=")
          emitted.should_not contain("\eP")
          emitted.should_not contain("\e_G")
          emitted.should match(/[\x{2801}-\x{28ff}]/) if tab == 1 || tab == 3
        end
      end
    ensure
      Crysterm::Config.set "media.backend", backend if backend
    end

    it "clears terminal graphics when switching between Host and a position at #{size}" do
      with_ui(size[0], size[1]) do |store, demo, interface, window|
        output = window.output.as(IO::Memory)
        ['1', '2', '3', '4'].each do |tab|
          window.press(tab)
          [nil, "X1"].each do |position|
            output.clear
            store.select_position(position)
            demo.update
            interface.refresh
            window.repaint
            output.to_s.should contain("\e[2J")
            interface.overview.content.includes?("Host overview").should eq(position.nil?)
            window.dump.to_s.should contain("TUI: Demo mode:")

            output.clear
            interface.refresh
            window.repaint
            output.to_s.should_not contain("\e[2J")
          end
        end
      end
    end

    it "renders and navigates positions, runs, acquisitions and statistics at #{size}" do
      with_ui(size[0], size[1]) do |store, demo, interface, window|
        interface.compact?.should eq(size[0] < 100)
        window.dump.to_s.should contain("LIVE X1")
        window.dump.to_s.should contain("Pass yield:")
        window.press('3')
        demo.update
        interface.refresh
        window.repaint
        store.tab.should eq(2)
        window.dump.to_s.should contain("Read length")
        window.press('h')
        window.repaint
        window.dump.to_s.should contain("Full range")
        window.press('h')
        window.repaint
        window.dump.to_s.should contain("Trim 1% each end")
        window.press('v')
        interface.quality_mode.should eq(1)
        store.tab.should eq(2)
        window.repaint
        window.dump.to_s.should contain("Q score histogram")
        window.press('v')
        window.repaint
        window.dump.to_s.should contain("Q score over time")
        window.press('4')
        window.press('v')
        window.repaint
        window.dump.to_s.should contain("Bias voltage")
        window.press('6')
        window.repaint
        window.dump.to_s.should contain("Pore activity")
        window.dump.to_s.should contain("Elapsed: 0–120 min")
        interface.activity_chart.values.should_not be_empty
        interface.activity_chart.values.last.sum.should be_close(100.0, 0.001)
        window.press('d')
        window.repaint
        window.dump.to_s.should contain("Detailed")
        window.press('u')
        window.repaint
        window.dump.to_s.should contain("State samples")
        window.press('a')
        window.repaint
        interface.dialog.should_not be_nil
        window.press(Tput::Key::Up)
        window.press(Tput::Key::Enter)
        interface.dialog.should be_nil
        store.acquisition_id.should eq("demo-X1-protocol-0-calibration")
        window.press('p')
        window.repaint
        window.press(Tput::Key::Home)
        window.press(Tput::Key::Enter)
        store.position_id.should be_nil
        interface.refresh
        window.repaint
        interface.overview.content.should contain("Host overview")
        window.press('?')
        interface.dialog.should_not be_nil
        window.press(Tput::Key::Escape)
        interface.dialog.should be_nil
      end
    end
  end

  it "returns to read length when basecalling is off and shows only applicable graph keys" do
    with_ui(80, 24) do |store, _, interface, window|
      window.dump.to_s.should_not contain("v graph")
      window.press('3')
      window.press('v')
      interface.quality_mode.should eq(1)
      store.detail.basecalling_enabled = false
      interface.refresh
      window.press('v')
      window.repaint
      interface.quality_mode.should eq(0)
      text = window.dump.to_s
      text.should contain("Basecalling off")
      text.should contain("h range")
      text.should_not contain("v graph")
      text.should_not contain("1/3")
      window.press('4')
      window.repaint
      window.dump.to_s.should contain("v graph")
    end
  end

  it "filters without changing selected identity and handles an empty manager" do
    with_ui(120, 36) do |store, _, interface, window|
      store.filter = "X4"
      interface.refresh
      interface.positions_view.rows.size.should eq(3)
      store.position_id.should eq("X1")
      store.select_position(nil)
      store.positions.clear
      interface.refresh
      window.repaint
      interface.overview.content.should contain("Positions: 0")
    end
  end
end
