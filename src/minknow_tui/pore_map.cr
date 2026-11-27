require "crysterm"
require "./model"
require "./theme"

module MinknowTui
  class PoreMap < Crysterm::Widgets::Box
    alias Cell = PoreLayout::Cell
    alias Point = PoreLayout::Point
    LABEL_WIDTH = 5

    # Shared by painting, clicks and scroll-to-selection. A numbered row's
    # group separators are screen columns, not logical cells.
    record Geometry, map : PoreLayout::Map? = nil, channel_count : Int32 = 0,
      columns : Int32 = 64, cell_width : Int32 = 1 do
      GROUP_SIZE = 8

      def rows : Int32
        map.try(&.rows) || (channel_count + columns - 1) // columns
      end

      def columns_at(row : Int32) : Int32
        map ? columns : Math.min(columns, channel_count - row * columns)
      end

      def row_label(row : Int32) : Int32
        map ? row + 1 : row * columns + 1
      end

      def separator_before?(column : Int32) : Bool
        !map && column > 0 && column % GROUP_SIZE == 0
      end

      def cell_at(row : Int32, column : Int32) : Cell?
        if physical = map
          physical.at(row, column)
        elsif 0 <= row < rows && 0 <= column < columns_at(row)
          Cell.new(row_label(row) + column)
        end
      end

      def from_content(x : Int32, row : Int32) : Cell?
        x -= LABEL_WIDTH
        return if x < 0
        return cell_at(row, x // cell_width) if map
        group, within = x.divmod(GROUP_SIZE + 1)
        cell_at(row, group * GROUP_SIZE + within) if within < GROUP_SIZE
      end

      def point(cell : Cell) : Point?
        if physical = map
          physical.point(cell)
        else
          row, column = (cell.channel - 1).divmod(columns)
          Point.new(row, column)
        end
      end

      def cell_center(column : Int32) : Int32
        LABEL_WIDTH + column * cell_width + (cell_width - 1) // 2
      end
    end

    enum Move
      Left
      Right
      Up
      Down
      PageUp
      PageDown
      First
      Last
    end

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
    @geometry = Geometry.new
    @signature : UInt64? = nil
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
        next unless event.mouse.action.down?
        cell = @geometry.from_content(event.local_x + grid.child_base_x, event.local_y + grid.child_base)
        select_cell(cell) if cell
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
        @geometry = Geometry.new
        @signature = nil
        return
      end
      @selected_channel = @selected_channel.clamp(1, Math.max(1, p.channels.to_i))
      geometry_changed = configure_map(p)
      selected = selected_cell(p)
      update_info(p, selected)
      signature = {p.name, p.pore_states, p.state_styles, selected, @geometry}.hash
      return if signature == @signature
      @signature = signature
      render_grid(p, selected)
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
      previous = @geometry
      map = p.pore_layout.try { |layout| @show_wells ? layout.wells : layout.channels }
      reset_cursor if previous.map != map
      @geometry = if map
                    width = @show_wells ? 1 : ((awidth - LABEL_WIDTH) // map.columns).clamp(1, 4)
                    Geometry.new(map, p.channels.to_i, map.columns, width)
                  else
                    columns = awidth >= 76 ? 64 : awidth >= 40 ? 32 : 16
                    Geometry.new(channel_count: p.channels.to_i, columns: columns)
                  end
      previous != @geometry
    end

    private def update_info(p : Position, selected : Cell)
      state = p.pore_states[selected_channel]?
      status = p.capabilities["channels"]? || "Waiting for channel stream"
      stamp = p.pore_updated_at.try(&.to_local.to_s("%H:%M:%S")) || "not received"
      mode = @geometry.map ? (@show_wells ? "Physical wells" : "Physical channels") : "Channel order"
      cursor = selected.well ? " | map well #{selected.well}" : ""
      info.content = "Channel #{selected_channel}/#{p.channels}: #{state.try(&.name) || "not received"} | well #{state.try(&.well) || "—"}\n" +
                     "#{mode}#{cursor}  ·  #{status}  ·  Last data: #{stamp}"
    end

    private def update_legend(p : Position)
      counts = Hash(String, Int32).new(0)
      p.pore_states.each_value { |value| counts[value.name] += 1 }
      hint = if @geometry.map && @show_wells
               "· no state for well. v: channel map."
             elsif @geometry.map
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
      glyph, default_color = Theme.channel_appearance(name)
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

    private def render_grid(p : Position, selected : Cell)
      badges = {} of String? => String
      width = @geometry.cell_width
      blank = " " * width
      grid.content = String.build do |text|
        @geometry.rows.times do |row|
          text << '\n' unless row == 0
          text << "%4d " % @geometry.row_label(row)
          @geometry.columns_at(row).times do |column|
            text << ' ' if @geometry.separator_before?(column)
            unless cell = @geometry.cell_at(row, column)
              text << blank
              next
            end
            state = p.pore_states[cell.channel]?
            text << "{underline}" if cell == selected
            if cell.well && state.try(&.well) != cell.well
              text << "{#{Theme::MUTED}-fg}·{/#{Theme::MUTED}-fg}"
            else
              name = state.try(&.name)
              text << badges.fetch(name) { badges[name] = state_badge(p, name, width) }
            end
            text << "{/underline}" if cell == selected
          end
        end
      end
    end

    private def selected_cell(p : Position) : Cell
      if @show_wells && (map = @geometry.map)
        preferred = @selected_well || p.pore_states[selected_channel]?.try(&.well)
        cell = Cell.new(selected_channel, preferred)
        return cell if map.point(cell)
        return Cell.new(selected_channel, 1_u32)
      end
      Cell.new(selected_channel)
    end

    def navigate(event : Crysterm::Event::KeyPress)
      if event.char == 'v' && @geometry.map
        @show_wells = !@show_wells
        refresh(@position)
      elsif (move = movement(event)) && (p = @position)
        target = if map = @geometry.map
                   physical_target(move, map, selected_cell(p))
                 else
                   numbered_target(move)
                 end
        select_cell(target) if target
      else
        return
      end
      event.accept
    end

    private def movement(event : Crysterm::Event::KeyPress) : Move?
      case
      when event.key == Tput::Key::Left, event.char == 'h'  then Move::Left
      when event.key == Tput::Key::Right, event.char == 'l' then Move::Right
      when event.key == Tput::Key::Up, event.char == 'k'    then Move::Up
      when event.key == Tput::Key::Down, event.char == 'j'  then Move::Down
      when event.key == Tput::Key::PageUp                   then Move::PageUp
      when event.key == Tput::Key::PageDown                 then Move::PageDown
      when event.key == Tput::Key::Home                     then Move::First
      when event.key == Tput::Key::End                      then Move::Last
      end
    end

    private def physical_target(move : Move, map : PoreLayout::Map, selected : Cell) : Cell?
      return unless point = map.point(selected)
      case move
      in .left?      then scan(map, point, 0, -1)
      in .right?     then scan(map, point, 0, 1)
      in .up?        then scan(map, point, -1, 0)
      in .down?      then scan(map, point, 1, 0)
      in .page_up?   then page(map, point, -1)
      in .page_down? then page(map, point, 1)
      in .first?     then map.first
      in .last?      then map.last
      end
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

    private def numbered_target(move : Move) : Cell
      columns = @geometry.columns
      step = case move
             in .left?      then -1
             in .right?     then 1
             in .up?        then -columns
             in .down?      then columns
             in .page_up?   then -columns * Math.max(1, grid.aheight)
             in .page_down? then columns * Math.max(1, grid.aheight)
             in .first?     then return Cell.new(1)
             in .last?      then return Cell.new(@geometry.channel_count)
             end
      Cell.new(selected_channel + step)
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
      if point = @geometry.point(selected_cell(p))
        grid.ensure_visible(point.row)
        grid.ensure_visible_x(@geometry.cell_center(point.column)) if @geometry.map
      end
    end
  end
end
