# frozen_string_literal: true

require_relative 'support'

include Fixtures # rubocop:disable Style/MixinUsage

OWT = OpenWalls::Core

group 'Takeoff' do
  test 'material volumes are read off the geometry, so deductions cannot drift' do
    rec = straight_wall(length: 4000, height: 2700, type: cavity_type, openings: [window])
    rows = OWT::Takeoff.materials_sheet([OWT.build(rec)])
    brick = rows.find { |r| r['Material'] == 'Brick' }
    block = rows.find { |r| r['Material'] == 'Block' }

    gross_brick = 4000.0 * 100.0 * 2700.0
    net_brick = gross_brick - (1200.0 * 1400.0 * 100.0)
    assert_close OWT::Units.mm3_to_m3(net_brick), brick['Net volume (m3)'], 1e-6
    assert_close OWT::Units.mm3_to_m3((4000.0 * 150.0 * 2700.0) - (1200.0 * 1400.0 * 150.0)),
                 block['Net volume (m3)'], 1e-6
  end

  test 'a fanlight above a door is not reported as a clash' do
    rec = straight_wall(length: 5000, height: 3000, openings: [
                          door(id: 'd', station: 2000, width: 1000, height: 2100),
                          window(id: 'f', station: 2000, width: 1000, height: 400, sill: 2200)
                        ])
    assert_empty rec.overlaps
    assert_empty rec.warnings
  end

  test 'materials are pooled across walls' do
    walls = [
      straight_wall(id: 'w1', length: 4000, height: 2700),
      straight_wall(id: 'w2', length: 6000, height: 2700)
    ]
    rows = OWT::Takeoff.materials_sheet(OWT.build_all(walls))
    concrete = rows.find { |r| r['Material'] == 'Concrete' }
    assert_close OWT::Units.mm3_to_m3(10_000.0 * 200.0 * 2700.0), concrete['Net volume (m3)'], 1e-6
    assert_equal 2, concrete['Walls']
  end

  test 'the wall sheet reports length, thickness and net volume' do
    row = OWT::Takeoff.walls_sheet([OWT.build(straight_wall(length: 5000))]).first
    assert_close 5.0, row['Length (m)'], 1e-6
    assert_close 200.0, row['Thickness (mm)'], 1e-6
    assert_close 2.7, row['Net volume (m3)'], 1e-3
  end

  test 'the opening schedule groups identical openings and counts them' do
    openings = [
      window(id: 'w1', station: 1000, width: 1200, height: 1400, sill: 900),
      window(id: 'w2', station: 3000, width: 1200, height: 1400, sill: 900),
      window(id: 'w3', station: 5000, width: 600, height: 600, sill: 1600),
      door(id: 'd1', station: 7000, width: 900, height: 2100)
    ]
    rows = OWT::Takeoff.opening_types_sheet([OWT.build(straight_wall(length: 9000, openings: openings))])
    assert_equal 3, rows.size, 'two identical windows must collapse to one schedule row'
    biggest = rows.first
    assert_equal 2, biggest['Count']
    assert_close 2 * OWT::Units.mm2_to_m2(1200.0 * 1400.0), biggest['Total area (m2)'], 1e-4
  end

  test 'openings that could not be built are flagged in the schedule' do
    rec = straight_wall(length: 5000, openings: [window(id: 'off', station: 4900, width: 1200)])
    row = OWT::Takeoff.openings_sheet([OWT.build(rec)]).first
    assert_equal 'no - off wall', row['Built']
  end

  test 'finish areas are already net of openings' do
    type = OWT::WallType.new(id: 'f', name: 'Finished', layers: [
                               OWT::Layer.new(name: 'Block', kind: :masonry, thickness: 100, material: 'Block'),
                               OWT::Layer.new(name: 'Plaster', kind: :finish, thickness: 13, material: 'Plaster')
                             ])
    rec = straight_wall(length: 5000, height: 2700, type: type, openings: [window])
    rows = OWT::Takeoff.finish_areas_sheet([OWT.build(rec)])
    plaster = rows.select { |r| r['Material'] == 'Plaster' }
    assert_equal 2, plaster.size
    net = OWT::Units.mm2_to_m2((5000.0 * 2700.0) - (1200.0 * 1400.0))
    plaster.each { |r| assert_close net, r['Area (m2)'], 1e-3 }
  end

  test 'every sheet is produced, even when empty' do
    sheets = OWT::Takeoff.sheets([OWT.build(straight_wall)])
    assert_equal ['Walls', 'Materials', 'Layers', 'Framing', 'Cutting list',
                  'Openings', 'Opening types', 'Finish areas'], sheets.keys
  end

  test 'framing summary and cutting list use the planned members' do
    frame = OWT::Layer.new(name: 'Stud zone', kind: :structure, thickness: 140,
                           material: 'Softwood C16', framing: 'uk-38x140-600')
    type = OWT::WallType.new(id: 'framed', name: 'Framed', layers: [frame])
    result = OWT.build(straight_wall(length: 3600, height: 2400, type: type))
    summary = OWT::Takeoff.framing_sheet([result]).first
    cutlist = OWT::Takeoff.cutting_list_sheet([result])

    assert_equal 'UK 38x140 @ 600 mm', summary['Standard']
    assert_equal 7, summary['Studs']
    assert_equal 7, summary['Pieces'] - summary['Noggings'] - summary['Plates']
    assert cutlist.any? { |row| row['Role'] == 'stud' && row['Count'] == 7 }
    assert cutlist.all? { |row| row['Material'] == 'Softwood C16' }
  end
end

group 'CSV output' do
  test 'headers come from the first row and order is stable' do
    csv = OWT::Takeoff.to_csv([{ 'A' => 1, 'B' => 2 }, { 'A' => 3, 'B' => 4 }])
    assert_equal ['A,B', '1,2', '3,4', ''], csv.split("\r\n", -1)
  end

  test 'commas, quotes and newlines are escaped per RFC 4180' do
    csv = OWT::Takeoff.to_csv([{ 'X' => 'a,b', 'Y' => 'say "hi"', 'Z' => "two\nlines" }])
    assert csv.include?('"a,b"')
    assert csv.include?('"say ""hi"""')
    assert csv.include?("\"two\nlines\"")
  end

  test 'nil cells become empty, not the string nil' do
    assert_equal ['A', '', ''], OWT::Takeoff.to_csv([{ 'A' => nil }]).split("\r\n", -1)
  end

  test 'an empty sheet produces an empty file, not a crash' do
    assert_equal '', OWT::Takeoff.to_csv([])
  end

  test 'the bundle writes one named file per sheet' do
    bundle = OWT::Takeoff.to_csv_bundle([OWT.build(straight_wall(openings: [window]))])
    assert_includes bundle.keys, 'walls.csv'
    assert_includes bundle.keys, 'opening-types.csv'
    assert bundle['walls.csv'].include?('Net volume (m3)')
  end
end
