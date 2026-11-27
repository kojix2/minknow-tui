require "spec"
require "./support/pore_layout_data"

describe MinknowTui::PoreLayout do
  it "places all 512 channels in the public MinION map, preserving the central gap" do
    layout = MinknowTui::PoreLayout.reference(512) || fail "Missing MinION layout"
    map = layout.channels
    {map.rows, map.columns}.should eq({32, 17})
    {layout.wells.rows, layout.wells.columns}.should eq({32, 68})
    seen = Set(Int32).new
    [1, 449, 385, 321, 257, 193, 129, 65].each_with_index do |low, band|
      4.times do |offset|
        row = band * 4 + offset
        start = low + offset * 8
        expected = (start + 32..start + 39).to_a +
                   [nil] + (start..start + 7).to_a.reverse
        actual = (0...17).map { |col| map.at(row, col).try(&.channel) }
        actual.should eq(expected)
        actual.compact.each { |channel| seen.add(channel) }
      end
    end
    seen.size.should eq(512)
    (0...8).map { |col| layout.wells.at(0, col).try(&.well) }.should eq([3, 4, 1, 2, 2, 1, 4, 3])
    (32...36).each { |col| layout.wells.at(0, col).should be_nil }
    layout.wells.at(0, 67).should eq(MinknowTui::PoreLayout::Cell.new(1, 3_u32))
    layout.native_coordinates(MinknowTui::PoreLayout::Point.new(0, 67)).should eq({32, 75})
    layout.native_coordinates(MinknowTui::PoreLayout::Point.new(28, 65)).should eq({4, 73})
  end

  it "keeps Flongle's missing wells and gaps between PromethION blocks" do
    layout = MinknowTui::PoreLayout.reference(126) || fail "Missing Flongle layout"
    flongle = layout.channels
    {flongle.rows, flongle.columns}.should eq({10, 13})
    (0...10).select { |row| flongle.at(row, 12).nil? }.should eq([0, 1, 8, 9])
    flongle.at(2, 12).try(&.channel).should eq(37)
    flongle.last.try(&.channel).should eq(126)
    layout.native_coordinates(MinknowTui::PoreLayout::Point.new(2, 12)).should eq({13, 3})
    promethion = MinknowTui::PoreLayout.reference(3000) || fail "Missing PromethION layout"
    {promethion.channels.rows, promethion.channels.columns}.should eq({25, 126})
    {promethion.wells.rows, promethion.wells.columns}.should eq({100, 126})
    promethion.channels.at(0, 29).try(&.channel).should eq(510)
    promethion.channels.at(0, 30).should be_nil
    promethion.channels.at(0, 31).should be_nil
    promethion.channels.at(0, 32).try(&.channel).should eq(751)
    promethion.wells.at(99, 125).should eq(MinknowTui::PoreLayout::Cell.new(3000, 1_u32))
    promethion.native_coordinates(MinknowTui::PoreLayout::Point.new(99, 125)).should eq({125, 0})
  end
end

describe MinknowTui::Decode do
  it "validates both native and display axes and looks up IDs independently of record order" do
    [512, 126, 3000].each do |count|
      layout = MinknowTui::Decode.pore_layout(PoreLayoutData.response(count), count.to_u32)
      layout.should_not be_nil
    end
    normalized = PoreLayoutData.response(512, screen: true, zero_based: false)
    MinknowTui::Decode.pore_layout(normalized, 512_u32).should_not be_nil
  end

  it "rejects incomplete, contradictory or duplicate coordinates instead of guessing" do
    response = PoreLayoutData.response(512)
    response.channel_records.first.mux_records.first.phys_x = UInt32::MAX
    MinknowTui::Decode.pore_layout(response, 512_u32).should be_nil
    response = PoreLayoutData.response(512)
    response.channel_records.first.id = response.channel_records.last.id
    MinknowTui::Decode.pore_layout(response, 512_u32).should be_nil
    response.channel_records.pop
    MinknowTui::Decode.pore_layout(response, 512_u32).should be_nil
  end

  it "does not mix native and display frames in one response" do
    native = PoreLayoutData.response(512)
    screen = PoreLayoutData.response(512, screen: true)
    native.channel_records[0] = screen.channel_records[0]
    MinknowTui::Decode.pore_layout(native, 512_u32).should be_nil
  end
end
