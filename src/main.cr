require "./minknow_tui/model"
require "./minknow_tui/options"
require "./minknow_tui/api"
require "./minknow_tui/demo"
require "./minknow_tui/ui"

begin
  options = MinknowTui::Options.new
  exit 0 if options.exit_requested
  store = MinknowTui::Store.new
  backend = options.demo ? MinknowTui::Demo.new(store) : MinknowTui::Api.new(store, options)
  ui = MinknowTui::UI.new(store)
  backend.start
  timer = ui.window.every(0.25.seconds) { ui.refresh }
  Signal::INT.trap { ui.window.quit }
  Signal::TERM.trap { ui.window.quit }
  begin
    ui.window.exec
  ensure
    timer.stop
    backend.stop
    ui.window.destroy unless ui.window.destroyed?
  end
rescue ex : ArgumentError | OptionParser::Exception
  STDERR.puts "minknow-tui: #{ex.message}"
  exit 2
end
