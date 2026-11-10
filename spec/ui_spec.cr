require "spec"
require "../src/minknow_tui/demo"
require "../src/minknow_tui/ui"

Crysterm::Config.set "screen.headless", Crysterm::Headless::Always

private def with_ui(width, height, &)
  store = MinknowTui::Store.new
  demo = MinknowTui::Demo.new(store)
  window = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false, terminfo: Unibilium.from_terminal("xterm-256color"), force_unicode: true)
  ui = MinknowTui::UI.new(store, window)
  window.repaint
  begin
    yield store, demo, ui, window
  ensure
    demo.stop
    window.destroy
  end
end

describe "minknow-tui headless UI" do
  it "moves list selection with vi keys, changes focus, and filters using text input" do
    with_ui(120, 36) do |store, demo, ui, window|
      ui.positions_view.focus
      window.press('j')
      store.position_id.should eq("X2")
      before = window.focused
      window.press(Tput::Key::Tab)
      window.focused.should_not be(before)
      window.press('/')
      window.type("X4")
      window.press(Tput::Key::Enter)
      store.filter.should eq("X4")
      ui.positions_view.rows.size.should eq(3)
      window.press(Tput::Key::Escape)
      store.filter.should eq("")
    end
  end

  it "keeps the event viewport stable while scrolled up and resumes at End" do
    with_ui(120, 36) do |store, demo, ui, window|
      80.times { |i| store.event("X1", "INFO", "Message #{i}") }
      ui.refresh
      window.repaint
      ui.events_view.focus
      window.press(Tput::Key::Home)
      window.repaint
      before = ui.events_view.child_base
      store.event("X1", "INFO", "New message")
      ui.refresh
      window.repaint
      ui.events_view.child_base.should eq(before)
      window.press(Tput::Key::End)
      ui.events_view.child_base.should be > before
    end
  end

  it "folds the sidebars on resize and moves focus out of hidden panes" do
    with_ui(120, 36) do |store, demo, ui, window|
      ui.runs_view.focus
      window.unpin_width
      window.unpin_height
      window.emit(Crysterm::Event::DeviceResize, Crysterm::Size.new(80, 24))
      ui.refresh
      window.repaint
      ui.compact?.should be_true
      window.focused.should_not be(ui.runs_view)
      window.dump.to_s.should contain("q quit")
    end
  end

  [{120, 36}, {80, 24}].each do |size|
    it "renders and navigates positions, runs, acquisitions and statistics at #{size}" do
      with_ui(size[0], size[1]) do |store, demo, ui, window|
        ui.compact?.should eq(size[0] < 100)
        window.dump.to_s.should contain("minknow-tui")
        window.press('3')
        demo.update
        ui.refresh
        window.repaint
        store.tab.should eq(2)
        window.dump.to_s.should contain("Read length")
        window.press('a')
        window.repaint
        ui.dialog.should_not be_nil
        window.press(Tput::Key::Enter)
        ui.dialog.should be_nil
        store.acquisition_id.should eq("demo-X1-protocol-0-calibration")
        window.press('p')
        window.repaint
        window.press(Tput::Key::Enter)
        store.position_id.should be_nil
        ui.refresh
        window.repaint
        ui.overview.content.should contain("Host overview")
        window.press('?')
        ui.dialog.should_not be_nil
        window.press(Tput::Key::Escape)
        ui.dialog.should be_nil
      end
    end
  end

  it "filters without changing selected identity and handles an empty manager" do
    with_ui(120, 36) do |store, demo, ui, window|
      store.filter = "X4"
      ui.refresh
      ui.positions_view.rows.size.should eq(3)
      store.position_id.should eq("X1")
      store.select_position(nil)
      store.positions.clear
      ui.refresh
      window.repaint
      ui.overview.content.should contain("Positions: 0")
    end
  end
end
