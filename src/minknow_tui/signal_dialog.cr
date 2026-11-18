require "crysterm"
require "./model"
require "./theme"

module MinknowTui
  class SignalDialog < Crysterm::Widget::Dialog
    getter! chart : Crysterm::Widgets::GraphLineChart
    getter! info : Crysterm::Widgets::Box
    @last_sample : UInt64?
    @last_rate : UInt32?

    def initialize(window : Crysterm::Window, @trace : SignalTrace, @demo : Bool)
      super(parent: window, width: "90%", height: "85%", layout: Crysterm::Layout::Dock.new, parse_tags: false)
      self.label = "#{MinknowTui.text(@trace.position.name)} · Channel #{@trace.channel} · Current"
      @info = Crysterm::Widgets::Box.new(parent: self, height: 1, layout_hint: :top, parse_tags: false)
      @chart = Crysterm::Widgets::GraphLineChart.new(parent: self, layout_hint: :center,
        type: Crysterm::Widgets::Media::Type::Glyph, show_legend: false)
      chart.axis_y.title = "pA"
      chart.axis_x.label_format = "%.0f"
      refresh
    end

    def refresh
      status = @trace.scope.capabilities["signal"]? || "Waiting for signal"
      status = "Acquisition no longer available" unless @trace.scope.active?
      data = @trace.samples
      chart.visible = status == "Available" && !data.empty?
      unless chart.visible?
        info.content = status == "Available" ? "Waiting for finite current samples" : status
        return
      end
      rate = @trace.position.live.sample_rate
      info.content = [@demo ? "Demo current (pA)" : "Current (pA)", rate.try { |value| "#{value} Hz" }].compact.join("  ·  ")
      return if {@last_sample, @last_rate} == {@trace.next_sample, rate}
      @last_sample, @last_rate = @trace.next_sample, rate
      scale = rate && rate > 0 ? 1000.0 / rate : 1.0
      chart.axis_x.title = rate ? "Time within trace (ms)" : "Sample within trace"
      points = data.map_with_index { |value, i| {i * scale, value.to_f64} }.to_a
      # Keep a steady or single-sample signal visible in the plot interior.
      chart.axis_y.minimum = data.min.to_f64 - 1
      chart.axis_y.maximum = data.max.to_f64 + 1
      chart.clear_series
      if points.size == 1
        chart.add_scatter("Current", points, Theme::GREEN)
      else
        chart.add_line("Current", points, Theme::GREEN)
      end
    end
  end
end
