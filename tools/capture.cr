# Reproducible screen review without MinKNOW or a real terminal.
require "file_utils"
require "../src/minknow_tui/demo"
require "../src/minknow_tui/ui"

Crysterm::Config.set "screen.headless", Crysterm::Headless::Always
destination = ARGV.first? || "/tmp/minknow-tui-captures"
FileUtils.mkdir_p(destination)
[{120, 36}, {80, 24}].each do |size|
  store = MinknowTui::Store.new
  demo = MinknowTui::Demo.new(store)
  window = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: size[0], height: size[1], default_quit_keys: false,
    terminfo: Unibilium.from_terminal("xterm-256color"), force_unicode: true)
  ui = MinknowTui::UI.new(store, window)
  4.times do |tab|
    window.press(('1'.ord + tab).chr)
    demo.update
    ui.refresh
    window.repaint
    base = File.join(destination, "#{size[0]}x#{size[1]}-#{tab + 1}")
    window.dump(path: "#{base}.dump")
    window.capture(path: "#{base}.png")
  end
  demo.stop
  window.destroy
end
puts destination
