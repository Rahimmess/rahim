# frozen_string_literal: true

require_relative 'support'

include Fixtures # rubocop:disable Style/MixinUsage

OWR = OpenWalls::Core

group 'WallType' do
  test 'thickness is the sum of the stack' do
    assert_close 365.5, OWR::WallType.preset('cavity-300').total_thickness, 1e-9
  end

  test 'layer spans are contiguous and start at face A' do
    spans = OWR::WallType.preset('cavity-300').layer_spans
    assert_close 0.0, spans.first[1], 1e-9
    spans.each_cons(2) { |(_, _, far), (_, near, _)| assert_close far, near, 1e-9 }
    assert_close 365.5, spans.last[2], 1e-9
  end

  test 'cavities and membranes are excluded from solid layers' do
    names = OWR::WallType.preset('stud-140').solid_layers.map(&:name)
    refute names.include?('Cavity')
    refute names.include?('Vapour barrier')
    assert names.include?('Plasterboard')
  end

  test 'the miter signature only depends on boundary positions' do
    a = OWR::WallType.new(id: 'a', name: 'A', layers: [
                            OWR::Layer.new(name: 'X', thickness: 100, material: 'Brick'),
                            OWR::Layer.new(name: 'Y', thickness: 50, kind: :finish, material: 'Render')
                          ])
    b = OWR::WallType.new(id: 'b', name: 'B', layers: [
                            OWR::Layer.new(name: 'P', thickness: 100, material: 'Block'),
                            OWR::Layer.new(name: 'Q', thickness: 50, kind: :finish, material: 'Plaster')
                          ])
    assert_equal a.miter_signature, b.miter_signature,
                 'same boundaries, different materials: these can still miter'
    refute a.miter_signature == OWR::WallType.preset('concrete-200').miter_signature,
           'different boundaries must not miter into each other'
  end

  test 'a layer with no thickness is rejected' do
    assert_raises(OWR::InvalidRecord) { OWR::Layer.new(name: 'X', thickness: 0) }
  end

  test 'an unknown layer kind is rejected' do
    assert_raises(OWR::InvalidRecord) { OWR::Layer.new(name: 'X', thickness: 10, kind: :vibes) }
  end

  test 'a type with no layers is rejected' do
    assert_raises(OWR::InvalidRecord) { OWR::WallType.new(id: 'z', name: 'Z', layers: []) }
  end

  test 'types round trip through a hash' do
    original = OWR::WallType.preset('stud-140')
    restored = OWR::WallType.from_h(original.to_h)
    assert_equal original.to_h, restored.to_h
  end
end

group 'OpeningRecord' do
  test 'a rectangle has a flat profile all the way across' do
    op = window(width: 1200, height: 1400, sill: 900)
    [0.0, 0.3, 0.5, 1.0].each { |u| assert_equal [900.0, 2300.0], op.profile(u) }
    assert_close 1200 * 1400, op.area, 1e-4
  end

  test 'a semicircular head rises to width/2 at the crown' do
    op = window(width: 1200, height: 1400, sill: 900, shape: :round)
    assert_close 2300.0, op.profile(0.0)[1], 1e-9
    assert_close 2900.0, op.profile(0.5)[1], 1e-9
    assert_close 2900.0, op.head_height, 1e-9
    assert_close (1200 * 1400) + (Math::PI * 600 * 600 / 2), op.area, 100.0
  end

  test 'a gable head is a triangle' do
    op = window(width: 1000, height: 1000, sill: 0, shape: :gable, rise: 500)
    assert_close 1000.0, op.profile(0.0)[1], 1e-9
    assert_close 1500.0, op.profile(0.5)[1], 1e-9
    assert_close (1000 * 1000) + (1000 * 500 / 2.0), op.area, 10.0
  end

  test 'a porthole pinches to nothing at both edges' do
    op = OWR::OpeningRecord.new(id: 'p', kind: :window, station: 1000, width: 800,
                                height: 800, sill: 1000, shape: :circle)
    assert_equal nil, op.profile(0.0)
    assert_equal nil, op.profile(1.0)
    lo, hi = op.profile(0.5)
    assert_close 1000.0, lo, 1e-9
    assert_close 1800.0, hi, 1e-9
    assert_close Math::PI * 400 * 400, op.area, 500.0
  end

  test 'curved heads get more facets than flat ones' do
    assert_empty window(shape: :rect).profile_parameters
    assert_equal [0.5], window(shape: :gable, rise: 300).profile_parameters
    assert window(width: 1200, shape: :round).profile_parameters.size > 8
  end

  test 'facets are spread evenly along the curve, not along the width' do
    params = window(width: 1200, shape: :round).profile_parameters
    first_gap = params[0]
    middle_gap = params[params.size / 2] - params[(params.size / 2) - 1]
    assert first_gap < middle_gap,
           'angle-uniform sampling must bunch facets near the springing'
  end

  test 'a zero-width opening is rejected' do
    assert_raises(OWR::InvalidRecord) do
      OWR::OpeningRecord.new(id: 'x', station: 100, width: 0, height: 1000)
    end
  end

  test 'openings round trip through a hash' do
    op = window(shape: :arch, rise: 250)
    assert_equal op.to_h, OWR::OpeningRecord.from_h(op.to_h).to_h
  end
end

group 'WallRecord' do
  test 'a flat wall has the same height everywhere' do
    rec = straight_wall(height: 2700)
    [0.0, 0.5, 1.0].each { |t| assert_close 2700.0, rec.height_at(t), 1e-9 }
    assert rec.flat_top?
  end

  test 'a sloping top interpolates linearly' do
    rec = OWR::WallRecord.new(id: 'h', segments: [line(0, 0, 1000, 0)], type: simple_type,
                              height_start: 2000, height_end: 3000)
    assert_close 2500.0, rec.height_at(0.5), 1e-9
    refute rec.flat_top?
    refute rec.gable?
  end

  test 'a mid height makes two straight pitches' do
    rec = OWR::WallRecord.new(id: 'h2', segments: [line(0, 0, 1000, 0)], type: simple_type,
                              height_start: 2000, height_mid: 4000, height_end: 3000)
    assert_close 3000.0, rec.height_at(0.25), 1e-9
    assert_close 4000.0, rec.height_at(0.5), 1e-9
    assert_close 3500.0, rec.height_at(0.75), 1e-9
    assert rec.gable?
  end

  test 'justification sets where face A sits relative to the path' do
    seg = [line(0, 0, 1000, 0)]
    type = simple_type(300)
    assert_close 0.0, OWR::WallRecord.new(id: '1', segments: seg, type: type, justification: :face_a).face_a_offset, 1e-9
    assert_close 150.0, OWR::WallRecord.new(id: '2', segments: seg, type: type, justification: :center).face_a_offset, 1e-9
    assert_close 300.0, OWR::WallRecord.new(id: '3', segments: seg, type: type, justification: :face_b).face_a_offset, 1e-9
  end

  test 'length follows the path, arcs included' do
    arc = OWR::Path::Arc.through(v(1000, 0), v(0, 1000), v(-1000, 0))
    rec = OWR::WallRecord.new(id: 'len', segments: [line(-1000, 0, 1000, 0), arc], type: simple_type)
    assert_close 2000.0 + (Math::PI * 1000.0), rec.length, 1e-6
  end

  test 'overlapping openings are reported' do
    rec = straight_wall(length: 5000, openings: [
                          window(id: 'a', station: 1000, width: 1200),
                          window(id: 'b', station: 1800, width: 1200)
                        ])
    refute rec.overlaps.empty?
    assert rec.warnings.any? { |w| w.include?('overlaps') }
  end

  test 'a clean wall has no warnings' do
    rec = straight_wall(length: 8000, height: 2700,
                        openings: [door(station: 1200), window(station: 4000)])
    assert_empty rec.warnings
  end

  test 'records round trip through JSON, arcs and all' do
    rec = OWR::WallRecord.new(
      id: 'rt2',
      segments: [line(0, 0, 2000, 0), OWR::Path::Arc.through(v(2000, 0), v(3000, 1000), v(2000, 2000))],
      type: OWR::WallType.preset('cavity-300'),
      openings: [window(shape: :round), door],
      height_start: 2400, height_mid: 3800, height_end: 2400,
      justification: :face_b, base_z: 150.0
    )
    restored = OWR::WallRecord.from_json(rec.to_json)
    assert_equal rec.to_h, restored.to_h
    assert_close rec.length, restored.length, 1e-9
  end

  test 'a record from a newer schema is refused rather than misread' do
    hash = straight_wall.to_h
    hash['schema'] = 99
    assert_raises(OWR::UnsupportedSchema) { OWR::WallRecord.from_h(hash) }
  end

  test 'a wall with no segments is rejected' do
    assert_raises(OWR::InvalidRecord) do
      OWR::WallRecord.new(id: 'empty', segments: [], type: simple_type)
    end
  end
end
