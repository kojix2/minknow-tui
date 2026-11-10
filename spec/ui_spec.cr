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
        interface.pores.info.content.should contain("demo-X1-protocol-0-sequencing")
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
        window.dump.to_s.should contain("minknow-tui")
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
        window.dump.to_s.should contain("Auto 99.5%")
        window.press('a')
        window.repaint
        interface.dialog.should_not be_nil
        window.press(Tput::Key::Enter)
        interface.dialog.should be_nil
        store.acquisition_id.should eq("demo-X1-protocol-0-calibration")
        window.press('p')
        window.repaint
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
