# frozen_string_literal: true

require_relative 'support'

include Fixtures # rubocop:disable Style/MixinUsage

OW = OpenWalls::Core

group 'Vec2' do
  test 'arithmetic and products' do
    a = OW::Vec2.new(3, 4)
    b = OW::Vec2.new(1, 2)
    assert_equal OW::Vec2.new(4, 6), a + b
    assert_equal OW::Vec2.new(2, 2), a - b
    assert_in_delta 5.0, a.length
    assert_in_delta 11.0, a.dot(b)
    assert_in_delta 2.0, a.cross(b)
    assert_in_delta 1.0, a.normalize.length
  end

  test 'perp is the left-hand normal' do
    assert_equal OW::Vec2.new(0, 1), OW::Vec2.new(1, 0).perp
    assert_equal OW::Vec2.new(-1, 0), OW::Vec2.new(0, 1).perp
  end

  test 'normalising a zero vector is an error, not a NaN' do
    assert_raises(OW::DegenerateGeometry) { OW::Vec2.new(0, 0).normalize }
  end

  test 'line intersection, including the parallel case' do
    hit = OW::Vec2.line_intersection(
      OW::Vec2.new(0, 0), OW::Vec2.new(1, 0),
      OW::Vec2.new(5, -5), OW::Vec2.new(0, 1)
    )
    assert_equal OW::Vec2.new(5, 0), hit
    assert_equal nil, OW::Vec2.line_intersection(
      OW::Vec2.new(0, 0), OW::Vec2.new(1, 0),
      OW::Vec2.new(0, 3), OW::Vec2.new(1, 0)
    )
  end

  test 'vectors hash by value so they can key a map' do
    assert_equal 1, [OW::Vec2.new(1.0, 2.0), OW::Vec2.new(1.0, 2.0)].uniq.size
  end
end

group 'Units' do
  test 'reads the dimension strings people actually type' do
    assert_in_delta 230.0, OW::Units.parse('230')
    assert_in_delta 230.0, OW::Units.parse('230mm')
    assert_in_delta 2300.0, OW::Units.parse('2.3 m')
    assert_in_delta 100.0, OW::Units.parse('10cm')
    assert_in_delta 228.6, OW::Units.parse('9in'), 1e-9
    assert_in_delta 228.6, OW::Units.parse('9"'), 1e-9
    assert_in_delta 914.4, OW::Units.parse("3'"), 1e-9
  end

  test 'reads compound imperial' do
    assert_in_delta 1066.8, OW::Units.parse(%q(3' 6")), 1e-6
    assert_in_delta 1079.5, OW::Units.parse(%q(3' 6 1/2")), 1e-6
  end

  test 'rejects nonsense instead of guessing' do
    assert_raises(OW::InvalidRecord) { OW::Units.parse('wide-ish') }
    assert_raises(OW::InvalidRecord) { OW::Units.parse('') }
  end

  test 'round trips through inches, which is what SketchUp stores' do
    assert_in_delta 102.5, OW::Units.inches_to_mm(OW::Units.mm_to_inches(102.5)), 1e-9
  end
end

group 'Path' do
  test 'line length and tessellation' do
    seg = line(0, 0, 3000, 4000)
    assert_in_delta 5000.0, seg.length
    assert_equal 2, OW::Path.tessellate([seg]).size
  end

  test 'an arc through three points recovers its centre and radius' do
    arc = OW::Path::Arc.through(v(1000, 0), v(0, 1000), v(-1000, 0))
    assert_equal :arc, arc.kind
    assert_in_delta 1000.0, arc.radius, 1e-6
    assert_in_delta 0.0, arc.center.length, 1e-6
    assert_in_delta Math::PI, arc.sweep, 1e-9
    assert_in_delta Math::PI * 1000.0, arc.length, 1e-6
  end

  test 'three collinear points give a line, not a divide-by-zero' do
    seg = OW::Path::Arc.through(v(0, 0), v(500, 0), v(1000, 0))
    assert_equal :line, seg.kind
  end

  test 'arc facet count adapts to radius and tolerance' do
    tight = OW::Path::Arc.through(v(100, 0), v(0, 100), v(-100, 0))
    wide  = OW::Path::Arc.through(v(20_000, 0), v(0, 20_000), v(-20_000, 0))
    assert wide.segment_count(0.5) > tight.segment_count(0.5),
           'a 20 m radius arc needs more facets than a 100 mm one at equal sagitta'
    assert tight.segment_count(5.0) < tight.segment_count(0.05),
           'a looser tolerance must produce fewer facets'
    assert wide.segment_count(0.0001) <= OW::Path::MAX_ARC_SEGMENTS,
           'the safety cap must still hold'
  end

  test 'facet counts stay sane at everyday radii' do
    quarter = OW::Path::Arc.new(v(20_000, 0), v(0, 20_000), v(0, 0), true)
    assert quarter.segment_count(0.5) < 150,
           "a 20 m quarter circle should not need #{quarter.segment_count(0.5)} facets"
  end

  test 'tessellated arc stays within tolerance of the true radius' do
    arc = OW::Path::Arc.through(v(3000, 0), v(0, 3000), v(-3000, 0))
    pts = OW::Path.tessellate([arc], 0.5)
    pts.each_cons(2) do |a, b|
      mid = a.lerp(b, 0.5)
      sagitta = 3000.0 - mid.length
      assert sagitta <= 0.5 + 1e-9, format('sagitta %.4f exceeded tolerance', sagitta)
    end
  end

  test 'a discontinuous path is rejected with a useful message' do
    error = assert_raises(OW::DegenerateGeometry) do
      OW::Path.tessellate([line(0, 0, 1000, 0), line(2000, 0, 3000, 0)])
    end
    assert error.message.include?('not continuous')
  end

  test 'zero-length segments are rejected at construction' do
    assert_raises(OW::DegenerateGeometry) { line(0, 0, 0, 0) }
  end
end

group 'Offset' do
  test 'a straight run offsets to a parallel line' do
    pts = [v(0, 0), v(1000, 0)]
    left = OW::Offset.polyline(pts, 100)
    assert_equal v(0, 100), left[0]
    assert_equal v(1000, 100), left[1]
  end

  test 'a right-angle corner miters exactly' do
    pts = [v(0, 0), v(1000, 0), v(1000, 1000)]
    outer = OW::Offset.polyline(pts, -100) # right-hand side of travel
    inner = OW::Offset.polyline(pts, 100)
    # Outside of the turn: the corner point sits 100 out on both axes.
    assert_equal v(1100, -100), outer[1]
    assert_equal v(900, 100), inner[1]
  end

  test 'offset output is always index-aligned with the input' do
    pts = [v(0, 0), v(1000, 0), v(2000, 500), v(3000, 500)]
    [50, -50, 0.0, 500].each do |d|
      assert_equal pts.size, OW::Offset.polyline(pts, d).size
    end
  end

  test 'a closed ring miters at the seam too' do
    square = [v(0, 0), v(1000, 0), v(1000, 1000), v(0, 1000)]
    ring = OW::Offset.polyline(square, -100, closed: true)
    assert_equal v(-100, -100), ring[0]
    assert_equal v(1100, -100), ring[1]
    assert_equal v(1100, 1100), ring[2]
    assert_equal v(-100, 1100), ring[3]
  end

  test 'a needle-sharp corner is clamped by the miter limit and reported' do
    pts = [v(0, 0), v(1000, 0), v(0, 10)]
    out = OW::Offset.polyline(pts, 100, miter_limit: 4.0)
    assert out[1].distance_to(v(1000, 0)) <= 4.0 * 100 + 1e-6,
           'miter length must respect the limit'
    refute OW::Offset.clamped_corners(pts, 100, miter_limit: 4.0).empty?,
           'the clamped corner should be reported to the user'
  end

  test 'gentle corners are not reported as clamped' do
    pts = [v(0, 0), v(1000, 0), v(2000, 100)]
    assert_empty OW::Offset.clamped_corners(pts, 100)
  end
end

group 'Stations' do
  test 'splits land exactly on the requested arc lengths' do
    st = OW::Stations.build([v(0, 0), v(1000, 0), v(1000, 1000)], splits: [500, 1200])
    assert_close 500.0, st.arc_lengths[st.index_at(500)], 1e-9
    assert_close 1200.0, st.arc_lengths[st.index_at(1200)], 1e-9
    assert_close 2000.0, st.total_length, 1e-9
  end

  test 'splits outside the run are ignored rather than corrupting the spine' do
    st = OW::Stations.build([v(0, 0), v(1000, 0)], splits: [-50, 0, 1000, 5000])
    assert_equal 2, st.count
  end

  test 'a slice keeps the parent rails, which is what preserves a miter' do
    parent = OW::Stations.build([v(0, 0), v(1000, 0), v(1000, 1000)])
    corner = parent.rail(-100)[1]
    piece = parent.slice(0, 1)
    assert_equal corner, piece.rail(-100).last,
                 'the slice must end on the chain corner, not a fresh perpendicular cap'
  end

  test 'projecting a point finds its station on the centreline' do
    st = OW::Stations.build([v(0, 0), v(4000, 0)])
    s, d = st.project(v(1500, 250))
    assert_close 1500.0, s, 1e-9
    assert_close 250.0, d, 1e-9
  end

  test 'projection clamps to the ends of the run' do
    st = OW::Stations.build([v(0, 0), v(4000, 0)])
    assert_close 0.0, st.project(v(-800, 0))[0], 1e-9
    assert_close 4000.0, st.project(v(9000, 0))[0], 1e-9
  end
end

group 'Mesh' do
  test 'a hand-built cube is closed and has the right volume' do
    m = OW::Mesh.new
    s = 100.0
    # bottom, top, and four sides, all wound outward
    m.add_face([[0, 0, 0], [0, s, 0], [s, s, 0], [s, 0, 0]])
    m.add_face([[0, 0, s], [s, 0, s], [s, s, s], [0, s, s]])
    m.add_face([[0, 0, 0], [s, 0, 0], [s, 0, s], [0, 0, s]])
    m.add_face([[s, 0, 0], [s, s, 0], [s, s, s], [s, 0, s]])
    m.add_face([[s, s, 0], [0, s, 0], [0, s, s], [s, s, s]])
    m.add_face([[0, s, 0], [0, 0, 0], [0, 0, s], [0, s, s]])
    assert m.closed?, "cube should be closed, open edges: #{m.boundary_edges.inspect}"
    assert_close s**3, m.volume, 1e-12
    assert_equal 8, m.vertices.size, 'coincident corners must weld'
  end

  test 'degenerate polygons are dropped rather than stored' do
    m = OW::Mesh.new
    assert_equal nil, m.add_face([[0, 0, 0], [0, 0, 0], [1, 1, 1]])
    assert_equal nil, m.add_face([[0, 0, 0], [10, 0, 0], [20, 0, 0]])
    assert_equal 0, m.face_count
  end

  test 'an unclosed shell reports its boundary edges' do
    m = OW::Mesh.new
    m.add_face([[0, 0, 0], [100, 0, 0], [100, 100, 0]])
    refute m.closed?
    assert_equal 3, m.boundary_edges.size
  end

  test 'non-planar quads are split into triangles' do
    m = OW::Mesh.new
    m.add_quad([0, 0, 0], [100, 0, 0], [100, 100, 50], [0, 100, 0])
    assert_equal 2, m.face_count
  end

  test 'OBJ export is 1-indexed and grouped by tag' do
    m = OW::Mesh.new
    m.add_face([[0, 0, 0], [100, 0, 0], [100, 100, 0]], tag: :top)
    obj = m.to_obj('x')
    assert obj.include?('g top')
    assert obj.include?('f 1 2 3')
  end
end
