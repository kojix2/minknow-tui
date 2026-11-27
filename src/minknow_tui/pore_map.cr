require "crysterm"
require "./model"
require "./theme"

module MinknowTui
  class PoreMap < Crysterm::Widgets::Box
    alias Cell = PoreLayout::Cell
    LABEL_WIDTH = 5

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
    @map : PoreLayout::Map?
    @signature : UInt64? = nil
    @columns = 64
    @cell_width = 1
    @show_wells = false
    @selected_well : UInt32? = nil
    @rendered_cell : Cell? = nil

    def initialize(**options)
      super(**options, layout: Crysterm::Layout::Dock.new)
      @info = Crysterm::Widgets::ScrollableText.new(parent: self, height: 2, layout_hint: :top, parse_tags: false)
      @legend = Crysterm::Widgets::ScrollableText.new(parent: self, height: 4, layout_hint: :bottom,
        keys: true, vi_keys: true, parse_tags: true, wrap_content: true)
      @grid = Grid.new(parent: self, layout_hint: :center, keys: true, parse_tags: true,
        wrap_content: false, horizontal_scrollbar_policy: :as_needed)
      grid.on(Crysterm::Event::Resize) { refresh(@position); reveal_selection }
      grid.on(Crysterm::Event::Mouse) do |event|
        if event.mouse.action.down?
          x = event.local_x + grid.child_base_x - LABEL_WIDTH
          y = event.local_y + grid.child_base
          if x >= 0
            if map = @map
              map.at(y, x // @cell_width).try { |cell| select_cell(cell) }
            elsif x % 9 < 8
              column = (x // 9) * 8 + x % 9
              channel = y * @columns + column + 1
              if column < @columns && channel <= (@position.try(&.channels) || 0)
                select_cell(Cell.new(channel))
              end
            end
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
        reset_cursor
      end
      @position = position
      unless p = position
        info.content = "Select a position to see its live channel states."
        grid.content = ""
        legend.content = ""
        @map = nil
        @signature = nil
        return
      end
      @selected_channel = @selected_channel.clamp(1, Math.max(1, p.channels.to_i))
      geometry_changed = configure_map(p)
      selected = selected_cell(p)
      update_info(p, selected)
      signature = {p.name, p.channels, p.pore_states, p.state_styles, selected, @columns, @cell_width, @map}.hash
      return if signature == @signature
      @signature = signature
      if map = @map
        render_physical(p, map, selected)
      else
        render_grid(p)
      end
      update_legend(p)
      reveal_selection if geometry_changed || selected != @rendered_cell
      @rendered_cell = selected
    end

    private def reset_cursor
      @selected_well = nil
      grid.scroll_to(0)
      grid.scroll_to_x(0)
    end

    private def configure_map(p : Position) : Bool
      previous_columns, previous_width, previous_map = @columns, @cell_width, @map
      @columns = awidth >= 76 ? 64 : awidth >= 40 ? 32 : 16
      map = p.pore_layout.try { |layout| @show_wells ? layout.wells : layout.channels }
      @map = map
      reset_cursor if previous_map != map
      @cell_width = map && !@show_wells ? ((awidth - LABEL_WIDTH) // map.columns).clamp(1, 4) : 1
      {previous_columns, previous_width, previous_map} != {@columns, @cell_width, @map}
    end

    private def update_info(p : Position, selected : Cell)
      state = p.pore_states[selected_channel]?
      status = p.capabilities["channels"]? || "Waiting for channel stream"
      stamp = p.pore_updated_at.try(&.to_local.to_s("%H:%M:%S")) || "not received"
      mode = @map ? (@show_wells ? "Physical wells" : "Physical channels") : "Channel order"
      cursor = selected.well ? " | map well #{selected.well}" : ""
      info.content = "Channel #{selected_channel}/#{p.channels}: #{state.try(&.name) || "not received"} | well #{state.try(&.well) || "—"}\n" +
                     "#{mode}#{cursor}  ·  #{status}  ·  Last data: #{stamp}"
    end

    private def update_legend(p : Position)
      counts = Hash(String, Int32).new(0)
      p.pore_states.each_value { |value| counts[value.name] += 1 }
      hint = if @map && @show_wells
               "· no state for well. v: channel map."
             elsif @map
               ". not received: #{p.channels.to_i - p.pore_states.size}. v: well map."
             else
               ". not received: #{p.channels.to_i - p.pore_states.size}. Grid is channel order."
             end
      legend.content = "Channel counts; #{hint}\n" +
                       counts.to_a.sort_by { |(_, count)| -count }.map do |(name, count)|
                         style = p.state_styles[name]?
                         label = MinknowTui.text(style.try(&.label) || name).gsub(/[{}]/, "")
                         "#{state_badge(p, name)} #{label}: #{count}"
                       end.join("  ")
    end

    private def state_badge(p : Position, name : String?, width = 1) : String
      glyph, default_color = self.class.appearance(name)
      padded = glyph.to_s.center(width)
      return "{#{default_color}-fg}#{padded}{/#{default_color}-fg}" unless name
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
      "{#{background}-bg}{#{foreground}-fg}#{padded}{/#{foreground}-fg}{/#{background}-bg}"
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

    private def render_physical(p : Position, map : PoreLayout::Map, selected : Cell)
      badges = {} of String? => String
      grid.content = String.build do |text|
        map.rows.times do |row|
          text << '\n' unless row == 0
          text << "%4d " % (row + 1)
          map.columns.times do |column|
            unless cell = map.at(row, column)
              text << (" " * @cell_width)
              next
            end
            state = p.pore_states[cell.channel]?
            text << "{underline}" if cell == selected
            if cell.well && state.try(&.well) != cell.well
              text << "{#{Theme::MUTED}-fg}·{/#{Theme::MUTED}-fg}"
            else
              name = state.try(&.name)
              text << badges.fetch(name) { badges[name] = state_badge(p, name, @cell_width) }
            end
            text << "{/underline}" if cell == selected
          end
        end
      end
    end

    private def selected_cell(p : Position) : Cell
      if @show_wells && (map = @map)
        preferred = @selected_well || p.pore_states[selected_channel]?.try(&.well)
        cell = Cell.new(selected_channel, preferred)
        return cell if map.point(cell)
        return Cell.new(selected_channel, 1_u32)
      end
      Cell.new(selected_channel)
    end

    def navigate(event : Crysterm::Event::KeyPress)
      if event.char == 'v' && @map
        @show_wells = !@show_wells
        refresh(@position)
        event.accept
      elsif (map = @map) && (p = @position)
        navigate_physical(event, map, selected_cell(p))
      else
        navigate_numbered(event)
      end
    end

    private def navigate_physical(event, map, selected)
      return unless point = map.point(selected)
      cell = case
             when event.key == Tput::Key::Left, event.char == 'h'  then scan(map, point, 0, -1)
             when event.key == Tput::Key::Right, event.char == 'l' then scan(map, point, 0, 1)
             when event.key == Tput::Key::Up, event.char == 'k'    then scan(map, point, -1, 0)
             when event.key == Tput::Key::Down, event.char == 'j'  then scan(map, point, 1, 0)
             when event.key == Tput::Key::PageUp                   then page(map, point, -1)
             when event.key == Tput::Key::PageDown                 then page(map, point, 1)
             when event.key == Tput::Key::Home                     then map.first
             when event.key == Tput::Key::End                      then map.last
             else                                                       return
             end
      select_cell(cell) if cell
      event.accept
    end

    private def scan(map, point, dy, dx)
      y, x = point.row + dy, point.column + dx
      while 0 <= y < map.rows && 0 <= x < map.columns
        if cell = map.at(y, x)
          return cell
        end
        y += dy
        x += dx
      end
    end

    private def page(map, point, direction)
      target = (point.row + direction * Math.max(1, grid.visible_content_rows)).clamp(0, map.rows - 1)
      while target != point.row
        if cell = map.at(target, point.column)
          return cell
        end
        target -= direction
      end
    end

    private def navigate_numbered(event)
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
      select_cell(Cell.new(selected_channel + delta))
      event.accept
    end

    private def select_cell(cell : Cell)
      return unless p = @position
      @selected_channel = cell.channel.clamp(1, Math.max(1, p.channels.to_i))
      @selected_well = cell.well
      refresh(p)
      reveal_selection
    end

    private def reveal_selection
      return unless p = @position
      if map = @map
        if point = map.point(selected_cell(p))
          grid.ensure_visible(point.row)
          grid.ensure_visible_x(LABEL_WIDTH + point.column * @cell_width + (@cell_width - 1) // 2)
        end
      else
        grid.ensure_visible((selected_channel - 1) // @columns)
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
