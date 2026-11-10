require "crysterm"
require "./model"
require "./theme"

module MinknowTui
  # Channel-number order, rather than a device-specific physical pore layout.
  class PoreMap < Crysterm::Widgets::Box
    class Grid < Crysterm::Widgets::ScrollableText
      def handle_key_press(event)
        parent.as(PoreMap).navigate(event)
      end
    end

    getter! grid : Grid
    getter! info : Crysterm::Widgets::ScrollableText
    getter! legend : Crysterm::Widgets::ScrollableText
    getter selected_channel = 1
    @position : Position?
    @signature : UInt64? = nil
    @columns = 64

    def initialize(**options)
      super(**options, layout: Crysterm::Layout::Dock.new)
      @info = Crysterm::Widgets::ScrollableText.new(parent: self, height: 4, layout_hint: :top, parse_tags: false)
      @legend = Crysterm::Widgets::ScrollableText.new(parent: self, height: 4, layout_hint: :bottom,
        keys: true, vi_keys: true, parse_tags: false, wrap_content: true)
      @grid = Grid.new(parent: self, layout_hint: :center, keys: true, parse_tags: true)
      grid.on(Crysterm::Event::Resize) { reveal_selection }
      grid.on(Crysterm::Event::Mouse) do |event|
        if event.mouse.action.down?
          x = event.local_x - 5
          if x >= 0 && x % 9 < 8
            channel = (event.local_y + grid.child_base) * @columns + (x // 9) * 8 + x % 9 + 1
            select_channel(channel) if channel <= (@position.try(&.channels) || 0)
          end
        end
      end
    end

    def focus
      grid.focus
    end

    def refresh(position : Position?)
      if @position != position
        @selected_channel = 1
        grid.scroll_to(0)
      end
      @position = position
      unless p = position
        info.content = "Select a position to see its live channel states."
        grid.content = ""
        legend.content = ""
        @signature = nil
        return
      end
      @selected_channel = @selected_channel.clamp(1, Math.max(1, p.channels.to_i))
      @columns = awidth >= 76 ? 64 : awidth >= 40 ? 32 : 16
      state = p.pore_states[selected_channel]?
      status = p.capabilities["channels"]? || "Waiting for channel stream"
      stamp = p.pore_updated_at.try(&.to_local.to_s("%H:%M:%S")) || "not received"
      info.content = "LIVE #{MinknowTui.text(p.name)} | #{p.status} | current device (not history)\n" +
                     "Acquisition: #{MinknowTui.text(p.current_acquisition || "none / waiting")}\n" +
                     "Channel #{selected_channel}/#{p.channels}: #{state.try(&.name) || "not received"} | well #{state.try(&.well) || "—"}\n" +
                     "#{status}; last data #{stamp} | arrows / hjkl move"
      signature = {p.name, p.channels, p.pore_states, selected_channel, @columns}.hash
      return if signature == @signature
      @signature = signature
      render_grid(p)
      counts = Hash(String, Int32).new(0)
      p.pore_states.each_value { |value| counts[value.name] += 1 }
      legend.content = "Channel counts; . not received: #{p.channels.to_i - p.pore_states.size}. Grid is channel order.\n" +
                       counts.to_a.sort_by { |(_, count)| -count }.map { |(name, count)| "#{self.class.appearance(name)[0]} #{name}: #{count}" }.join("  ")
    end

    private def render_grid(p : Position)
      grid.content = String.build do |text|
        p.channels.to_i.times do |index|
          if index % @columns == 0
            text << '\n' unless index == 0
            text << "%4d " % (index + 1)
          elsif index % 8 == 0
            text << ' '
          end
          glyph, color = self.class.appearance(p.pore_states[index + 1]?.try(&.name))
          text << "{underline}" if index + 1 == selected_channel
          text << "{#{color}-fg}" << glyph << "{/#{color}-fg}"
          text << "{/underline}" if index + 1 == selected_channel
        end
      end
    end

    def navigate(event : Crysterm::Event::KeyPress)
      delta = case
              when event.key == Tput::Key::Left, event.char == 'h'  then -1
              when event.key == Tput::Key::Right, event.char == 'l' then 1
              when event.key == Tput::Key::Up, event.char == 'k'    then -@columns
              when event.key == Tput::Key::Down, event.char == 'j'  then @columns
              when event.key == Tput::Key::PageUp                   then -@columns * Math.max(1, grid.aheight)
              when event.key == Tput::Key::PageDown                 then @columns * Math.max(1, grid.aheight)
              when event.key == Tput::Key::Home                     then -selected_channel
              when event.key == Tput::Key::End                      then @position.try(&.channels.to_i) || 0
              else                                                       return
              end
      select_channel(selected_channel + delta)
      event.accept
    end

    private def select_channel(channel : Int32)
      return unless p = @position
      @selected_channel = channel.clamp(1, Math.max(1, p.channels.to_i))
      refresh(p)
      reveal_selection
    end

    private def reveal_selection
      return unless @position
      row = (selected_channel - 1) // @columns
      if row < grid.child_base
        grid.scroll_to(row)
      elsif row >= grid.child_base + grid.aheight
        grid.scroll_to(row - Math.max(1, grid.aheight) + 1)
      end
    end

    def self.appearance(name : String?) : Tuple(Char, String)
      case name
      when nil                                          then {'.', Theme::MUTED}
      when "strand"                                     then {'S', Theme::GREEN}
      when "pore"                                       then {'P', Theme::TURQUOISE}
      when "adapter"                                    then {'A', Theme::GREEN}
      when "no_pore"                                    then {'-', Theme::MUTED}
      when "unblocking"                                 then {'U', Theme::WARNING}
      when "unavailable", "saturated"                   then {'!', Theme::ERROR}
      when "multiple"                                   then {'M', Theme::WARNING}
      when "disabled", "locked"                         then {'x', Theme::MUTED}
      when "pending_mux_change", "pending_manual_reset" then {'~', Theme::MUTED}
      else                                                   {'?', Theme::MUTED}
      end
    end
  end
end
