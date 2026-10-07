# frozen_string_literal: true

require_relative 'support'

include Fixtures # rubocop:disable Style/MixinUsage

OWB = OpenWalls::Core

# Every test in this file asserts two things about the generated solid:
#
#   * it is WATERTIGHT -- every boundary edge is cancelled by opposite edges
#     on the same line. This is the
#     single strongest check available on a mesh generator, and it is what
#     catches an opening that failed to stitch, a reveal wound the wrong way
#     round, or a band that got dropped at a gable apex.
#   * its VOLUME matches a closed-form answer worked out by hand.
#
# Together those two make it very hard for the mesher to be wrong and still
# pass. Note the identity used throughout: for centre justification, a mitered
# band around a polyline has area exactly thickness x centreline length,
# because the triangle gained on the outside of each corner equals the one
# lost on the inside.

group 'WallBuilder: plain walls' do
  test 'a straight wall is a closed solid of the expected volume' do
    res = OWB.build(straight_wall(length: 5000, thickness: 200, height: 2700))
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    assert_close 5000.0 * 200.0 * 2700.0, res.volume, 1e-9
  end

  test 'both faces come out at the full elevational area' do
    res = OWB.build(straight_wall(length: 5000, height: 2700))
    mesh = res.layers.first[:mesh]
    assert_close 5000.0 * 2700.0, mesh.area(:face_a), 1e-9
    assert_close 5000.0 * 2700.0, mesh.area(:face_b), 1e-9
  end

  test 'justification moves the wall, not its size' do
    seg = [line(0, 0, 4000, 0)]
    volumes = {}
    spans = {}
    %i[face_a center face_b].each do |just|
      rec = OWB::WallRecord.new(id: "j-#{just}", segments: seg, type: simple_type(300),
                                justification: just, height: 2500)
      res = OWB.build(rec)
      assert res.closed?
      volumes[just] = res.volume
      lo, hi = res.layers.first[:mesh].bounds
      spans[just] = [lo[1].round(6), hi[1].round(6)]
    end
    assert_close volumes[:center], volumes[:face_a], 1e-12
    assert_close volumes[:center], volumes[:face_b], 1e-12
    # Face A -- the first layer in the stack, by convention the exterior --
    # is always the boundary further to the left of travel direction. So
    # justifying to face A puts the path on that face and the body to the
    # right; justifying to face B does the opposite.
    assert_equal [-300.0, 0.0], spans[:face_a]
    assert_equal [-150.0, 150.0], spans[:center]
    assert_equal [0.0, 300.0], spans[:face_b]
  end

  test 'a sloping top gives the trapezoid volume' do
    rec = OWB::WallRecord.new(id: 's1', segments: [line(0, 0, 6000, 0)], type: simple_type(250),
                              height_start: 2400, height_end: 3600)
    res = OWB.build(rec)
    assert res.closed?
    assert_close 6000.0 * 250.0 * ((2400.0 + 3600.0) / 2.0), res.volume, 1e-9
  end

  test 'a gable actually builds an apex instead of a straight slope' do
    rec = OWB::WallRecord.new(id: 'g1', segments: [line(0, 0, 8000, 0)], type: simple_type(200),
                              height_start: 2400, height_mid: 4200, height_end: 2400)
    res = OWB.build(rec)
    assert res.closed?
    # Two trapezoids: L/4 * (hs + 2*hm + he) is the elevation area.
    expected = 200.0 * (8000.0 / 4.0) * (2400.0 + (2 * 4200.0) + 2400.0)
    assert_close expected, res.volume, 1e-9
    _lo, hi = res.layers.first[:mesh].bounds
    assert_close 4200.0, hi[2], 1e-9, 'the apex must reach the mid height'
  end

  test 'an asymmetric pitch works the same way' do
    rec = OWB::WallRecord.new(id: 'g2', segments: [line(0, 0, 8000, 0)], type: simple_type(200),
                              height_start: 2000, height_mid: 5000, height_end: 3000)
    res = OWB.build(rec)
    assert res.closed?
    expected = 200.0 * (8000.0 / 4.0) * (2000.0 + (2 * 5000.0) + 3000.0)
    assert_close expected, res.volume, 1e-9
  end

  test 'base_z lifts the wall without changing it' do
    rec = OWB::WallRecord.new(id: 'b1', segments: [line(0, 0, 3000, 0)], type: simple_type(200),
                              height: 2400, base_z: 3500)
    res = OWB.build(rec)
    assert res.closed?
    lo, hi = res.layers.first[:mesh].bounds
    assert_close 3500.0, lo[2], 1e-9
    assert_close 5900.0, hi[2], 1e-9
    assert_close 3000.0 * 200.0 * 2400.0, res.volume, 1e-9
  end
end

group 'WallBuilder: layer stacks' do
  test 'a cavity wall builds one closed solid per solid layer' do
    rec = straight_wall(length: 4000, height: 2500, type: cavity_type)
    res = OWB.build(rec)
    assert_equal 2, res.layers.size, 'the cavity itself must not produce geometry'
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    brick = res.layers.find { |l| l[:layer].name == 'Brick' }[:mesh]
    block = res.layers.find { |l| l[:layer].name == 'Block' }[:mesh]
    assert_close 4000.0 * 100.0 * 2500.0, brick.volume, 1e-9
    assert_close 4000.0 * 150.0 * 2500.0, block.volume, 1e-9
  end

  test 'the cavity is a real gap between the leaves' do
    res = OWB.build(straight_wall(length: 4000, type: cavity_type))
    brick_lo, brick_hi = res.layers.find { |l| l[:layer].name == 'Brick' }[:mesh].bounds
    block_lo, block_hi = res.layers.find { |l| l[:layer].name == 'Block' }[:mesh].bounds
    gap = [brick_lo[1], block_lo[1]].max - [brick_hi[1], block_hi[1]].min
    assert_close 50.0, gap.abs, 1e-9
  end

  test 'membranes are counted but not modelled as solids' do
    type = OWB::WallType.new(
      id: 'm', name: 'With membrane',
      layers: [
        OWB::Layer.new(name: 'Block', kind: :masonry, thickness: 100, material: 'Block'),
        OWB::Layer.new(name: 'VCL', kind: :membrane, thickness: 0.5, material: 'VCL'),
        OWB::Layer.new(name: 'Board', kind: :finish, thickness: 12.5, material: 'Board')
      ]
    )
    res = OWB.build(straight_wall(length: 3000, type: type))
    assert_equal %w[Block Board], res.layers.map { |l| l[:layer].name }
    assert res.closed?
  end

  test 'total modelled thickness equals the stack minus cavities and membranes' do
    res = OWB.build(straight_wall(length: 3000, type: OWB::WallType.preset('cavity-300')))
    solid = res.layers.sum { |l| l[:layer].thickness }
    assert_close 102.5 + 100 + 100 + 13, solid, 1e-9
  end
end

group 'WallBuilder: openings' do
  test 'a rectangular window removes exactly its own volume' do
    rec = straight_wall(length: 5000, thickness: 200, height: 2700, openings: [window])
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    gross = 5000.0 * 200.0 * 2700.0
    assert_close gross - (1200.0 * 1400.0 * 200.0), res.volume, 1e-9
  end

  test 'a door to floor level removes the floor band too' do
    rec = straight_wall(length: 5000, thickness: 200, height: 2700, openings: [door])
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    gross = 5000.0 * 200.0 * 2700.0
    assert_close gross - (900.0 * 2100.0 * 200.0), res.volume, 1e-9
  end

  test 'several openings in one wall' do
    openings = [
      door(id: 'd1', station: 1200, width: 900, height: 2100),
      window(id: 'w1', station: 3000, width: 1500, height: 1400, sill: 900),
      window(id: 'w2', station: 5200, width: 600, height: 600, sill: 1600)
    ]
    rec = straight_wall(length: 7000, thickness: 215, height: 2800, openings: openings)
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    deduction = ((900 * 2100) + (1500 * 1400) + (600 * 600)) * 215.0
    assert_close (7000.0 * 215.0 * 2800.0) - deduction, res.volume, 1e-9
  end

  test 'an opening cuts every layer of a cavity wall' do
    rec = straight_wall(length: 4000, height: 2700, type: cavity_type, openings: [window])
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    res.each_layer do |entry|
      t = entry[:layer].thickness
      expected = (4000.0 * t * 2700.0) - (1200.0 * 1400.0 * t)
      assert_close expected, entry[:mesh].volume, 1e-9, "layer #{entry[:layer].name}"
    end
  end

  test 'a stacked opening above a door still closes' do
    openings = [
      door(id: 'd1', station: 2000, width: 1000, height: 2100),
      OWB::OpeningRecord.new(id: 'fan', kind: :window, station: 2000, width: 1000,
                             height: 400, sill: 2200, shape: :rect)
    ]
    rec = straight_wall(length: 5000, thickness: 200, height: 3000, openings: openings)
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    deduction = ((1000 * 2100) + (1000 * 400)) * 200.0
    assert_close (5000.0 * 200.0 * 3000.0) - deduction, res.volume, 1e-9
  end

  test 'a semicircular arch closes and removes close to its true area' do
    op = window(id: 'a1', station: 2500, width: 1200, height: 1400, sill: 900, shape: :round)
    rec = straight_wall(length: 5000, thickness: 200, height: 3200, openings: [op])
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    exact = (1200.0 * 1400.0) + (Math::PI * (600.0**2) / 2.0)
    removed = (5000.0 * 200.0 * 3200.0) - res.volume
    assert_in_delta exact * 200.0, removed, exact * 200.0 * 0.002,
                    'faceted arch area should be within 0.2% of the true area'
  end

  test 'a segmental arch closes' do
    op = window(id: 'a2', station: 2500, width: 1800, height: 1200, sill: 800, shape: :arch, rise: 300)
    rec = straight_wall(length: 5000, thickness: 200, height: 3000, openings: [op])
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    assert res.volume < 5000.0 * 200.0 * 3000.0
  end

  test 'a gable-headed opening closes and removes the exact area' do
    op = window(id: 'g1', station: 2500, width: 1000, height: 1200, sill: 900, shape: :gable, rise: 400)
    rec = straight_wall(length: 5000, thickness: 200, height: 3200, openings: [op])
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    exact = (1000.0 * 1200.0) + (1000.0 * 400.0 / 2.0)
    assert_close (5000.0 * 200.0 * 3200.0) - (exact * 200.0), res.volume, 1e-9
  end

  test 'a circular porthole closes despite pinching to nothing at both edges' do
    op = OWB::OpeningRecord.new(id: 'p1', kind: :window, station: 2500, width: 900,
                                height: 900, sill: 1200, shape: :circle)
    rec = straight_wall(length: 5000, thickness: 200, height: 3000, openings: [op])
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    exact = Math::PI * (450.0**2)
    removed = (5000.0 * 200.0 * 3000.0) - res.volume
    assert_in_delta exact * 200.0, removed, exact * 200.0 * 0.005,
                    'angle-uniform sampling should keep a porthole within 0.5% of true area'
  end

  test 'reveals are generated for every opening' do
    rec = straight_wall(length: 5000, openings: [window])
    mesh = OWB.build(rec).layers.first[:mesh]
    assert mesh.area(:reveal_jamb) > 0, 'jambs missing'
    assert mesh.area(:reveal_head) > 0, 'head missing'
    assert mesh.area(:reveal_sill) > 0, 'sill missing'
    assert_close 2 * 1400.0 * 200.0, mesh.area(:reveal_jamb), 1e-9
    assert_close 1200.0 * 200.0, mesh.area(:reveal_head), 1e-9
    assert_close 1200.0 * 200.0, mesh.area(:reveal_sill), 1e-9
  end

  test 'a door gets no sill reveal' do
    mesh = OWB.build(straight_wall(openings: [door])).layers.first[:mesh]
    assert_close 0.0, mesh.area(:reveal_sill), 1e-9
  end

  test 'openings hanging off the end of the wall are reported, not built' do
    off = window(id: 'bad', station: 4900, width: 1200)
    res = OWB.build(straight_wall(length: 5000, openings: [off]))
    assert_equal 1, res.skipped_openings.size
    assert res.closed?
    assert_close 5000.0 * 200.0 * 2700.0, res.volume, 1e-9
  end

  test 'the record flags openings that are too tall for the wall' do
    rec = straight_wall(length: 5000, height: 2400, openings: [window(height: 2000, sill: 900)])
    refute rec.warnings.empty?
    assert rec.warnings.first.include?('taller than the wall')
  end
end

group 'WallBuilder: curves and corners' do
  test 'a curved wall is closed and its volume matches the mitered-band identity' do
    arc = OWB::Path::Arc.through(v(4000, 0), v(2828.427, 2828.427), v(0, 4000))
    rec = OWB::WallRecord.new(id: 'c1', segments: [arc], type: simple_type(250), height: 2700)
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    expected = 250.0 * 2700.0 * polyline_length(rec.centerline_points)
    assert_close expected, res.volume, 1e-9
  end

  test 'the tessellated arc stays close to the true quarter-circle length' do
    arc = OWB::Path::Arc.through(v(4000, 0), v(2828.427, 2828.427), v(0, 4000))
    rec = OWB::WallRecord.new(id: 'c2', segments: [arc], type: simple_type(250))
    assert_in_delta arc.length, polyline_length(rec.centerline_points), arc.length * 1e-4
  end

  test 'a window in a curved wall closes' do
    arc = OWB::Path::Arc.through(v(5000, 0), v(3535.5, 3535.5), v(0, 5000))
    rec = OWB::WallRecord.new(
      id: 'c3', segments: [arc], type: simple_type(300), height: 3000,
      openings: [window(id: 'cw', station: arc.length / 2.0, width: 1500, height: 1500, sill: 900)]
    )
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    assert res.volume < 300.0 * 3000.0 * polyline_length(rec.centerline_points)
  end

  test 'an arched window in a curved gable wall closes -- the hard combination' do
    arc = OWB::Path::Arc.through(v(6000, 0), v(4242.6, 4242.6), v(0, 6000))
    op = OWB::OpeningRecord.new(id: 'hard', kind: :window, station: arc.length / 2.0,
                                width: 1600, height: 1400, sill: 900, shape: :round)
    rec = OWB::WallRecord.new(id: 'c4', segments: [arc], type: cavity_type,
                              height_start: 2600, height_mid: 4200, height_end: 2600,
                              openings: [op])
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    assert_equal 2, res.layers.size
  end

  test 'mixing a line and an arc in one path works without switching tools' do
    straight = line(0, 0, 3000, 0)
    arc = OWB::Path::Arc.through(v(3000, 0), v(4414.2, 585.8), v(5000, 2000))
    rec = OWB::WallRecord.new(id: 'mix', segments: [straight, arc], type: simple_type(200), height: 2700)
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    assert_close 200.0 * 2700.0 * polyline_length(rec.centerline_points), res.volume, 1e-9
  end

  test 'a corner inside a single wall miters without changing the band area' do
    rec = OWB::WallRecord.new(
      id: 'L', segments: [line(0, 0, 4000, 0), line(4000, 0, 4000, 3000)],
      type: simple_type(300), height: 2700
    )
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
    assert_close 300.0 * 2700.0 * 7000.0, res.volume, 1e-9
  end

  test 'a sharp corner still produces a closed solid' do
    rec = OWB::WallRecord.new(
      id: 'sharp', segments: [line(0, 0, 4000, 0), line(4000, 0, 200, 300)],
      type: simple_type(200), height: 2500
    )
    res = OWB.build(rec)
    assert res.closed?, "open layers: #{res.open_layers.inspect}"
  end
end

group 'WallBuilder: determinism' do
  test 'building the same record twice gives byte-identical geometry' do
    rec = straight_wall(length: 5000, openings: [window, door])
    a = OWB.build(rec)
    b = OWB.build(rec)
    assert_equal a.mesh.vertices, b.mesh.vertices
    assert_equal a.mesh.faces.map(&:indices), b.mesh.faces.map(&:indices)
  end

  test 'a record survives a JSON round trip and rebuilds identically' do
    rec = OWB::WallRecord.new(
      id: 'rt', segments: [line(0, 0, 5000, 0), OWB::Path::Arc.through(v(5000, 0), v(6000, 1000), v(5000, 2000))],
      type: cavity_type, height_start: 2400, height_mid: 3600, height_end: 2400,
      openings: [window, door], justification: :face_a
    )
    restored = OWB::WallRecord.from_json(rec.to_json)
    assert_close OWB.build(rec).volume, OWB.build(restored).volume, 1e-12
    assert_equal rec.to_h, restored.to_h
  end

  test 'a finer tolerance on a curve genuinely refines the geometry' do
    arc = OWB::Path::Arc.through(v(4000, 0), v(2828.427, 2828.427), v(0, 4000))
    coarse = OWB::WallRecord.new(id: 'tc', segments: [arc], type: simple_type(200), tolerance: 5.0)
    fine   = OWB::WallRecord.new(id: 'tf', segments: [arc], type: simple_type(200), tolerance: 0.1)
    assert coarse.centerline_points.size < fine.centerline_points.size
    assert OWB.build(coarse).volume < OWB.build(fine).volume,
           'a finer tessellation should approach the true arc from below'
  end
end
