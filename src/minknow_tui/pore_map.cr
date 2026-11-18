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
        keys: true, vi_keys: true, parse_tags: true, wrap_content: true)
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
      signature = {p.name, p.channels, p.pore_states, p.state_styles, selected_channel, @columns}.hash
      return if signature == @signature
      @signature = signature
      render_grid(p)
      update_legend(p)
    end

    private def update_legend(p : Position)
      counts = Hash(String, Int32).new(0)
      p.pore_states.each_value { |value| counts[value.name] += 1 }
      legend.content = "Channel counts; . not received: #{p.channels.to_i - p.pore_states.size}. Grid is channel order.\n" +
                       counts.to_a.sort_by { |(_, count)| -count }.map do |(name, count)|
                         style = p.state_styles[name]?
                         label = MinknowTui.text(style.try(&.label) || name).gsub(/[{}]/, "")
                         "#{state_badge(p, name)} #{label}: #{count}"
                       end.join("  ")
    end

    private def state_badge(p : Position, name : String?) : String
      glyph, default_color = self.class.appearance(name)
      return "{#{default_color}-fg}#{glyph}{/#{default_color}-fg}" unless name
      background = p.state_styles[name]?.try(&.terminal_colour) || default_color
      # Colors.readable_on uses approximate brightness; compare black/white
      # contrast ratios using linearized sRGB luminance here.
      rgb = Crysterm::Colors.convert_cached(background)
      components = Crysterm::Colors.rgb_channels(rgb).map do |channel|
        value = channel / 255.0
        value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
      end
      luminance = components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
      foreground = (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? "#000000" : "#ffffff"
      "{#{background}-bg}{#{foreground}-fg}#{glyph}{/#{foreground}-fg}{/#{background}-bg}"
    end

    private def render_grid(p : Position)
      badges = {} of String? => String
      grid.content = String.build do |text|
        p.channels.to_i.times do |index|
          if index % @columns == 0
            text << '\n' unless index == 0
            text << "%4d " % (index + 1)
          elsif index % 8 == 0
            text << ' '
          end
          name = p.pore_states[index + 1]?.try(&.name)
          text << "{underline}" if index + 1 == selected_channel
          text << badges.fetch(name) { badges[name] = state_badge(p, name) }
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

    # Fallbacks from MinKNOW 25.09 sequencing_channel_states.toml.
    # Acquisition metadata takes precedence over these defaults.
    FALLBACK_APPEARANCES = {
      nil                    => {'.', Theme::MUTED},
      "strand"               => {'S', "#00ff00"},
      "pore"                 => {'P', "#00cc00"},
      "adapter"              => {'A', "#ede797"},
      "no_pore"              => {'-', "#90c6e7"},
      "unblocking"           => {'U', "#a53f97"},
      "unavailable"          => {'!', "#54b8b1"},
      "saturated"            => {'!', "#68767e"},
      "multiple"             => {'M', "#f57e20"},
      "unknown_negative"     => {'?', "#b5aea7"},
      "unknown_positive"     => {'?', "#0084a9"},
      "zero"                 => {'0', "#4da9c3"},
      "disabled"             => {'x', "#ccd5d8"},
      "locked"               => {'x', "#ccd5d8"},
      "pending_mux_change"   => {'~', Theme::MUTED},
      "pending_manual_reset" => {'~', Theme::MUTED},
    }

    def self.appearance(name : String?) : Tuple(Char, String)
      FALLBACK_APPEARANCES[name]? || {'?', Theme::MUTED}
    end
  end
end
