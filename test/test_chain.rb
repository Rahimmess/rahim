# frozen_string_literal: true

require_relative 'support'

include Fixtures # rubocop:disable Style/MixinUsage

OWC = OpenWalls::Core

# The identity these tests lean on: for centre justification, a mitered band
# around a polyline has area exactly thickness x centreline length, because
# the triangle gained outside each corner equals the one lost inside. So if
# the corner miters correctly, the summed volume of the chained walls is
# T x H x (total centreline length) -- no more, no less. A butt joint
# overshoots, an overlap undershoots, and both show up immediately.

def l_shape(type_a: nil, type_b: nil)
  [
    OWC::WallRecord.new(id: 'a', segments: [line(0, 0, 4000, 0)],
                        type: type_a || simple_type(300), height: 2700),
    OWC::WallRecord.new(id: 'b', segments: [line(4000, 0, 4000, 3000)],
                        type: type_b || simple_type(300), height: 2700)
  ]
end

def room(size = 5000.0, thickness = 250.0)
  corners = [v(0, 0), v(size, 0), v(size, size), v(0, size)]
  (0...4).map do |i|
    a = corners[i]
    b = corners[(i + 1) % 4]
    OWC::WallRecord.new(id: "r#{i}", segments: [OWC::Path::Line.new(a, b)],
                        type: simple_type(thickness), height: 2700)
  end
end

group 'Chain: grouping' do
  test 'two walls meeting end to start form one run' do
    runs = OWC::Chain.group(l_shape)
    assert_equal 1, runs.size
    assert_equal %w[a b], runs.first.records.map(&:id)
    refute runs.first.closed
  end

  test 'a ring of four walls is detected as closed' do
    runs = OWC::Chain.group(room)
    assert_equal 1, runs.size
    assert_equal 4, runs.first.records.size
    assert runs.first.closed
  end

  test 'walls with different layer stacks are not chained' do
    runs = OWC::Chain.group(l_shape(type_b: simple_type(150)))
    assert_equal 2, runs.size
  end

  test 'walls with different justification are not chained' do
    walls = l_shape
    other = OWC::WallRecord.new(id: 'b', segments: [line(4000, 0, 4000, 3000)],
                                type: simple_type(300), justification: :face_a)
    assert_equal 2, OWC::Chain.group([walls.first, other]).size
  end

  test 'a T junction is never chained through' do
    walls = l_shape + [
      OWC::WallRecord.new(id: 'c', segments: [line(4000, 0, 7000, 0)],
                          type: simple_type(300), height: 2700)
    ]
    runs = OWC::Chain.group(walls)
    assert runs.all? { |r| r.records.size == 1 },
           'three walls at one point have no single correct miter, so none should chain'
  end

  test 'walls that merely pass near each other are not chained' do
    walls = [
      OWC::WallRecord.new(id: 'p', segments: [line(0, 0, 4000, 0)], type: simple_type(300)),
      OWC::WallRecord.new(id: 'q', segments: [line(4050, 0, 4050, 3000)], type: simple_type(300))
    ]
    assert_equal 2, OWC::Chain.group(walls).size
  end
end

group 'Chain: mitered geometry' do
  test 'an L of two walls miters, and the volume proves it' do
    results = OWC.build_all(l_shape)
    results.each { |r| assert r.closed?, "open layers: #{r.open_layers.inspect}" }
    total = results.sum(&:volume)
    assert_close 300.0 * 2700.0 * 7000.0, total, 1e-9
  end

  test 'unchained walls butt instead, which costs the corner twice' do
    walls = l_shape(type_b: simple_type(300.0001)) # just enough to block the miter
    total = OWC.build_all(walls).sum(&:volume)
    assert total > 300.0 * 2700.0 * 7000.0,
           'a butt joint should overlap at the corner, not miter away'
  end

  test 'a closed room miters at all four corners including the seam' do
    results = OWC.build_all(room)
    results.each { |r| assert r.closed?, "open layers: #{r.open_layers.inspect}" }
    assert_close 250.0 * 2700.0 * (4 * 5000.0), results.sum(&:volume), 1e-9
  end

  test 'the room is a ring with a hollow middle' do
    results = OWC.build_all(room(5000.0, 250.0))
    mesh = results.each_with_object(OWC::Mesh.new) { |r, m| m.merge(r.mesh) }
    lo, hi = mesh.bounds
    assert_close(-125.0, lo[0], 1e-9)
    assert_close 5125.0, hi[0], 1e-9
  end

  test 'every wall in a chain keeps its own openings and heights' do
    walls = l_shape
    walls[0] = OWC::WallRecord.new(
      id: 'a', segments: [line(0, 0, 4000, 0)], type: simple_type(300),
      height_start: 2400, height_mid: 3800, height_end: 2400,
      openings: [window(id: 'wa', station: 2000, width: 1200, height: 1400, sill: 900)]
    )
    walls[1] = OWC::WallRecord.new(
      id: 'b', segments: [line(4000, 0, 4000, 3000)], type: simple_type(300), height: 2400
    )
    results = OWC.build_all(walls)
    results.each { |r| assert r.closed?, "open layers: #{r.open_layers.inspect}" }

    a = results.find { |r| r.record.id == 'a' }
    _lo, hi = a.mesh.bounds
    assert_close 3800.0, hi[2], 1e-9, 'the gable apex survives being inside a chain'

    gross_a = 300.0 * (4000.0 / 4.0) * (2400.0 + (2 * 3800.0) + 2400.0)
    assert_close gross_a - (1200.0 * 1400.0 * 300.0), a.volume, 1.0
  end

  test 'a chain of a straight wall into a curved one miters' do
    arc = OWC::Path::Arc.through(v(4000, 0), v(5414.2, 585.8), v(6000, 2000))
    walls = [
      OWC::WallRecord.new(id: 's', segments: [line(0, 0, 4000, 0)], type: simple_type(200), height: 2700),
      OWC::WallRecord.new(id: 'c', segments: [arc], type: simple_type(200), height: 2700)
    ]
    results = OWC.build_all(walls)
    results.each { |r| assert r.closed?, "open layers: #{r.open_layers.inspect}" }
    expected_length = 4000.0 + polyline_length(walls[1].centerline_points)
    assert_close 200.0 * 2700.0 * expected_length, results.sum(&:volume), 1e-6
  end

  test 'a single unchained wall still builds' do
    results = OWC.build_all([straight_wall(length: 3000)])
    assert_equal 1, results.size
    assert results.first.closed?
    assert_close 3000.0 * 200.0 * 2700.0, results.first.volume, 1e-9
  end

  test 'build_all on an empty model is not an error' do
    assert_empty OWC.build_all([])
  end
end
