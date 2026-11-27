require "../../src/minknow_tui/api"

module PoreLayoutData
  alias Device = MinknowApi::Device

  def self.response(count, *, screen = false, zero_based = true)
    layout = MinknowTui::PoreLayout.reference(count) || raise "No fixture layout for #{count} channels"
    Device::GetChannelsLayoutResponse.new.tap do |reply|
      reply.channel_records = (1..count).reverse_each.map do |channel|
        Device::ChannelRecord.new.tap do |record|
          record.id = (channel - (zero_based ? 1 : 0)).to_u32
          record.name = channel.to_s
          record.mux_records = (1..layout.well_count).reverse_each.map do |well|
            point = layout.wells.point(MinknowTui::PoreLayout::Cell.new(channel, well.to_u32)) || raise "Missing fixture well"
            x, y = if screen
                     {point.column, point.row}
                   else
                     case count
                     when 512 then {32 - point.row, point.column + 8}
                     when 126 then {point.column + 1, point.row + 1}
                     else          {point.column, 99 - point.row}
                     end
                   end
            Device::ChannelRecord::MuxRecord.new.tap do |mux|
              mux.id = (well - (zero_based ? 1 : 0)).to_u32
              mux.phys_x = x.to_u32
              mux.phys_y = y.to_u32
            end
          end.to_a
        end
      end.to_a
    end
  end
end
