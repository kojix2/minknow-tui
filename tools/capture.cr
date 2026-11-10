# Reproducible screen review without MinKNOW or a real terminal.
require "file_utils"
require "../src/minknow_tui/demo"
require "../src/minknow_tui/ui"

Crysterm::Config.set "screen.headless", Crysterm::Headless::Always

private def snapshot(window, ui, demo, path)
  demo.update
  ui.refresh
  window.repaint
  window.dump(path: "#{path}.dump")
  window.capture(path: "#{path}.png", default_bg: 0x20242a)
end

destination = ARGV.first? || "/tmp/minknow-tui-captures"
FileUtils.mkdir_p(destination)
[{120, 36}, {80, 24}].each do |size|
  store = MinknowTui::Store.new
  demo = MinknowTui::Demo.new(store)
  window = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: size[0], height: size[1], default_quit_keys: false,
    terminfo: Unibilium.from_terminal("xterm-256color"), force_unicode: true)
  ui = MinknowTui::UI.new(store, window)
  5.times do |tab|
    window.press(('1'.ord + tab).chr)
    snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-#{tab + 1}"))
  end
  window.press('3')
  window.press('h')
  snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-histogram-full"))
  window.press('h')
  snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-histogram-auto"))
  window.press('5')
  window.press(Tput::Key::End)
  snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-last-channel"))
  window.press('1')
  window.press('p')
  snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-positions"))
  window.press(Tput::Key::Enter)
  snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-host"))
  window.press('2')
  window.press('p')
  window.press(Tput::Key::Down)
  window.press(Tput::Key::Enter)
  snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-host-to-position"))
  window.press('?')
  snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-help"))
  window.press(Tput::Key::Escape)
  window.press('/')
  window.type("X4")
  window.press(Tput::Key::Enter)
  snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-filtered"))
  window.press(Tput::Key::Escape)
  4.times do |tab|
    window.press(('4'.ord - tab).chr)
    snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-return-#{4 - tab}"))
  end
  80.times { |index| store.event("Host", "INFO", "Visual review event #{index}") }
  ui.refresh
  window.repaint
  ui.events_view.focus
  window.press(Tput::Key::Home)
  snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-events-scrolled"))
  store.event("Host", "INFO", "New event while following is paused")
  snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-events-paused"))
  window.press(Tput::Key::End)
  snapshot(window, ui, demo, File.join(destination, "#{size[0]}x#{size[1]}-events-following"))
  demo.stop
  window.destroy
end
puts destination
