module MinknowTui
  # Screen coordinates have their origin at the top left. Keep the unconnected
  # gaps instead of reflowing the sensor to fit the terminal.
  class PoreLayout
    record Point, row : Int32, column : Int32
    record Cell, channel : Int32, well : UInt32? = nil

    private enum Device
      Minion
      Flongle
      Promethion
    end

    class Map
      getter rows = 0
      getter columns = 0
      getter first : Cell? = nil
      getter last : Cell? = nil
      @cells = {} of Point => Cell
      @points = {} of Cell => Point

      def add(point : Point, cell : Cell)
        @cells[point] = cell
        @points[cell] = point
        @rows = Math.max(rows, point.row + 1)
        @columns = Math.max(columns, point.column + 1)
        @first = cell if !(previous = first) || earlier?(point, @points[previous])
        @last = cell if !(previous = last) || earlier?(@points[previous], point)
      end

      def at(row : Int32, column : Int32) : Cell?
        @cells[Point.new(row, column)]?
      end

      def point(cell : Cell) : Point?
        @points[cell]?
      end

      private def earlier?(a, b)
        {a.row, a.column} < {b.row, b.column}
      end
    end

    getter channels = Map.new
    getter wells = Map.new
    getter wells_per_channel : Int32

    private def initialize(@device : Device, @wells_per_channel)
    end

    # MinKNOW's native axes vary across devices. This inverts the projection
    # from the native sensor coordinates to the screen's top-left origin.
    def native_coordinates(point : Point) : Tuple(Int32, Int32)
      case @device
      in .minion?     then {32 - point.row, 8 + point.column}
      in .flongle?    then {point.column + 1, point.row + 1}
      in .promethion? then {point.column, 99 - point.row}
      end
    end

    # Cross-checked against MinKNOW 6.8.9's *_channel_map.csv and ONT's
    # EPI2ME Basic QC notebook. The notebook collapses the physical gaps.
    def self.reference(channel_count : Int) : self?
      case channel_count
      when  512 then minion
      when  126 then flongle
      when 3000 then promethion
      end
    end

    private def self.minion : self
      layout = new(Device::Minion, 4)
      {1, 449, 385, 321, 257, 193, 129, 65}.each_with_index do |base, band|
        4.times do |offset|
          row = band * 4 + offset
          16.times do |col|
            right = col >= 8
            channel = base + offset * 8 + (right ? 15 - col : col + 32)
            screen_col = col + (right ? 1 : 0)
            layout.channels.add(Point.new(row, screen_col), Cell.new(channel))
            order = col.even? ? {3, 4, 1, 2} : {2, 1, 4, 3}
            order.each_with_index do |well, i|
              layout.wells.add(Point.new(row, screen_col * 4 + i), Cell.new(channel, well.to_u32))
            end
          end
        end
      end
      layout
    end

    private def self.flongle : self
      layout = new(Device::Flongle, 1)
      channel = 0
      10.times do |row|
        13.times do |col|
          next if col == 12 && (row < 2 || row >= 8)
          channel += 1
          point = Point.new(row, col)
          layout.channels.add(point, Cell.new(channel))
          layout.wells.add(point, Cell.new(channel, 1_u32))
        end
      end
      layout
    end

    private def self.promethion : self
      layout = new(Device::Promethion, 4)
      3000.times do |i|
        col = i // 250 * 10 + i % 10
        col += 2 * (col // 30)
        row = i % 250 // 10
        layout.channels.add(Point.new(row, col), Cell.new(i + 1))
        4.times do |well|
          layout.wells.add(Point.new(row * 4 + 3 - well, col), Cell.new(i + 1, (well + 1).to_u32))
        end
      end
      layout
    end
  end
end
