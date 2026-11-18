# Live MinKNOW smoke check and screen captures; never starts/stops a run.
require "file_utils"
require "json"
require "../src/minknow_tui/api"
require "../src/minknow_tui/ui"

private def await_data(label : String, &ready : -> Bool)
  deadline = Time.monotonic + 120.seconds
  until ready.call
    raise "Timed out waiting for #{label}" if Time.monotonic > deadline
    sleep 0.25.seconds
  end
end

destination = ARGV.first? || ".playback/captures"
FileUtils.mkdir_p(destination)
store = MinknowTui::Store.new
options = MinknowTui::Options.new(["--host", "localhost", "--port", "9501"])
backend = MinknowTui::Api.new(store, options)
Crysterm::Config.set "screen.headless", Crysterm::Headless::Always
window = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
  width: 140, height: 44, default_quit_keys: false,
  terminfo: Unibilium.from_terminal("xterm-256color"), force_unicode: true)
ui = MinknowTui::UI.new(store, window)
backend.start
begin
  await_data("simulated MS00000") { store.positions["MS00000"]?.try(&.simulated?) == true }
  store.select_position("MS00000")
  await_data("run statistics") { (store.detail.reads || 0) > 0 }
  await_data("kit metadata") { store.run.try(&.kit.empty?) == false }
  6.times do |tab|
    window.press(('1'.ord + tab).chr)
    case tab
    when 1 then await_data("yield") { !store.detail.estimated.points.empty? }
    when 2 then await_data("read length histogram") { !store.detail.histogram.empty? }
    when 3 then await_data("temperature and bias") { !store.detail.temperatures.points.empty? && !store.detail.bias_voltages.points.empty? }
    when 4 then await_data("live channels") { !store.positions["MS00000"].pore_states.empty? }
    when 5 then await_data("pore activity") { !store.detail.duty_buckets.empty? }
    end
    keys = case tab
           when 1 then ["yield"]
           when 2 then ["read_lengths"]
           when 3 then ["temperature_history", "bias_voltage"]
           when 5 then ["duty_time"]
           else        [] of String
           end
    keys.each do |key|
      await_data("#{key} live availability") { store.position.try(&.capabilities["detail.#{key}"]?) == "Available" }
    end
    ui.refresh
    window.repaint
    if tab == 0 && !ui.compact?
      view = ui.runs_view
      state = store.run.try(&.state) || "Running"
      text = window.dump(view.aleft, view.aleft + view.awidth, view.atop, view.atop + view.aheight).to_s
      raise "Selected run state is missing from sidebar: #{state}" unless text.includes?(state)
    end
    window.dump(path: File.join(destination, "#{tab + 1}.dump"))
    window.capture(path: File.join(destination, "#{tab + 1}.png"), default_bg: 0x20242a)
    if tab == 2 && store.detail.basecalling_enabled == true
      await_data("basecalls and Q scores") { (store.detail.pass_calls || 0) > 0 && !store.detail.qscore_histogram.empty? && !store.detail.qscore_medians.points.empty? }
      ["qscore_histogram", "qscore_time"].each do |key|
        await_data("#{key} live availability") { store.position.try(&.capabilities["detail.#{key}"]?) == "Available" }
      end
      2.times do |mode|
        window.press('v')
        ui.refresh
        window.repaint
        window.dump(path: File.join(destination, "quality-#{mode + 1}.dump"))
        window.capture(path: File.join(destination, "quality-#{mode + 1}.png"), default_bg: 0x20242a)
      end
    end
  end
  report = {position: store.position_id, protocol: store.run_id, acquisition: store.acquisition_id,
            reads: store.detail.reads, estimated_bases: store.detail.estimated_bases,
            basecalling: store.detail.basecalling_enabled,
            kit: store.run.try(&.kit), basecalls_pass: store.detail.pass_calls,
            qscore_points: store.detail.qscore_medians.points,
            live_channels: store.positions["MS00000"].pore_states.size,
            capabilities: store.positions["MS00000"].capabilities}
  File.write(File.join(destination, "summary.json"), report.to_pretty_json)
  puts report.to_pretty_json
ensure
  backend.stop
  window.destroy
end
