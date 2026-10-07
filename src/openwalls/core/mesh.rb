# frozen_string_literal: true

require_relative 'errors'

module OpenWalls
  module Core
    # A plain indexed polygon soup: the single currency between the geometry
    # engine and whatever draws it.
    #
    # The engine never touches a SketchUp Face. It emits a Mesh, and an adapter
    # turns that into SketchUp entities, an OBJ file, a Three.js buffer or a
    # test assertion. That is why the whole engine is unit-testable outside
    # SketchUp -- and why a second front end costs a day instead of a rewrite.
    class Mesh
      # Faces carry a +tag+ (what part of the wall this is: :face_a, :top,
      # :reveal_head, ...) and a +material+ name. Quantity takeoff and material
      # assignment both read the tag, so neither needs to re-derive geometry.
      Face = Struct.new(:indices, :tag, :material, :layer) do
        def to_h
          { 'indices' => indices, 'tag' => tag.to_s, 'material' => material, 'layer' => layer }
        end
      end

      # Vertex welding tolerance in millimetres. Coarser than Vec2::EPS on
      # purpose: rails computed by different routes must still weld.
      WELD = 1e-4

      attr_reader :vertices, :faces

      def initialize
        @vertices = []
        @faces = []
        @index = {}
      end

      def add_vertex(x, y, z)
        key = [(x / WELD).round, (y / WELD).round, (z / WELD).round]
        found = @index[key]
        return found if found

        @index[key] = @vertices.size
        @vertices << [x.to_f, y.to_f, z.to_f]
        @vertices.size - 1
      end

      # Adds a polygon from an array of [x, y, z]. Silently drops degenerate
      # polygons (repeated or collinear points collapsing to zero area) --
      # these are a normal product of zero-height bands at a gable apex or a
      # circular opening's tangent edges, not an error.
      def add_face(points, tag: nil, material: nil, layer: nil)
        idx = points.map { |p| add_vertex(p[0], p[1], p[2]) }
        idx = collapse(idx)
        return nil if idx.size < 3
        return nil if polygon_area(idx) < 1e-6

        face = Face.new(idx, tag, material, layer)
        @faces << face
        face
      end

      # Adds a quad as two triangles only when it is non-planar; otherwise
      # keeps it as a quad so SketchUp gets clean rectangular faces.
      def add_quad(p0, p1, p2, p3, tag: nil, material: nil, layer: nil)
        if planar?([p0, p1, p2, p3])
          add_face([p0, p1, p2, p3], tag: tag, material: material, layer: layer)
        else
          add_face([p0, p1, p2], tag: tag, material: material, layer: layer)
          add_face([p0, p2, p3], tag: tag, material: material, layer: layer)
        end
      end

      def empty?
        @faces.empty?
      end

      def face_count
        @faces.size
      end

      def merge(other)
        other.faces.each do |f|
          pts = f.indices.map { |i| other.vertices[i] }
          add_face(pts, tag: f.tag, material: f.material, layer: f.layer)
        end
        self
      end

      # Signed volume via the divergence theorem. Correct only for a closed
      # mesh with outward-facing winding -- which is exactly what we want to
      # assert in tests.
      def volume
        total = 0.0
        @faces.each do |f|
          v0 = @vertices[f.indices[0]]
          (1...f.indices.size - 1).each do |i|
            v1 = @vertices[f.indices[i]]
            v2 = @vertices[f.indices[i + 1]]
            total += triple(v0, v1, v2)
          end
        end
        total / 6.0
      end

      def area(tag = nil)
        @faces.select { |f| tag.nil? || f.tag == tag }.sum { |f| polygon_area(f.indices) }
      end

      def area_by_tag
        @faces.each_with_object(Hash.new(0.0)) { |f, h| h[f.tag] += polygon_area(f.indices) }
      end

      # Directed edges that have no opposite twin. An empty result means the
      # mesh is a closed, consistently wound shell: the strongest single
      # correctness check we have for the generator, and it catches an opening
      # that failed to stitch long before anyone opens SketchUp.
      def boundary_edges
        seen = Hash.new(0)
        @faces.each do |f|
          idx = f.indices
          idx.each_with_index do |a, i|
            b = idx[(i + 1) % idx.size]
            seen[[a, b]] += 1
          end
        end
        seen.keys.reject { |(a, b)| seen[[b, a]].positive? }
      end

      def closed?
        boundary_edges.empty?
      end

      # Geometric watertightness, which is the property we actually want.
      #
      # The mesher deliberately emits the *minimum* number of faces: the wall
      # skin next to an opening is one tall quad on one side of the jamb and
      # two shorter ones on the other. That is a T-vertex -- topologically the
      # tall quad's edge has no single twin -- but the shell has no hole in
      # it, and it is the right output: SketchUp splits the long edge
      # automatically where the short ones land, so the result is clean
      # manifold geometry with no redundant edges running across a wall face.
      #
      # So instead of demanding a one-to-one edge pairing, this checks that
      # every unmatched edge is exactly cancelled by opposite-facing edges
      # lying on the same line. Any real hole leaves a residual interval.
      #
      # Returns the residual (uncancelled) intervals; empty means watertight.
      def open_boundary(tolerance: 1e-3)
        lines = Hash.new { |h, k| h[k] = [] }

        boundary_edges.each do |(ai, bi)|
          a = @vertices[ai]
          b = @vertices[bi]
          dir = normalize3(sub3(b, a))
          next unless dir

          canon = canonical_direction(dir)
          flipped = dot3(canon, dir).negative?
          origin = perpendicular_foot(a, canon)
          key = [quantize(canon), quantize(origin)]
          t0 = dot3(sub3(a, origin), canon)
          t1 = dot3(sub3(b, origin), canon)
          lo, hi = t0 < t1 ? [t0, t1] : [t1, t0]
          lines[key] << [lo, hi, flipped ? -1 : 1]
        end

        residual = []
        lines.each_value do |intervals|
          cuts = intervals.flat_map { |(lo, hi, _)| [lo, hi] }.sort.uniq
          cuts.each_cons(2) do |lo, hi|
            next if hi - lo < tolerance

            mid = (lo + hi) / 2.0
            weight = intervals.sum { |(a, b, w)| mid > a && mid < b ? w : 0 }
            residual << [lo, hi, weight] unless weight.zero?
          end
        end
        residual
      end

      def watertight?(tolerance: 1e-3)
        open_boundary(tolerance: tolerance).empty?
      end

      def bounds
        return nil if @vertices.empty?

        lo = [Float::INFINITY] * 3
        hi = [-Float::INFINITY] * 3
        @vertices.each do |v|
          3.times do |i|
            lo[i] = v[i] if v[i] < lo[i]
            hi[i] = v[i] if v[i] > hi[i]
          end
        end
        [lo, hi]
      end

      def to_obj(name = 'wall')
        lines = ["# OpenWalls export -- units: millimetres", "o #{name}"]
        @vertices.each { |v| lines << format('v %.4f %.4f %.4f', v[0], v[1], v[2]) }
        @faces.group_by { |f| f.tag || :untagged }.each do |tag, faces|
          lines << "g #{tag}"
          faces.each { |f| lines << "f #{f.indices.map { |i| i + 1 }.join(' ')}" }
        end
        lines.join("\n") << "\n"
      end

      def to_h
        {
          'vertices' => @vertices,
          'faces' => @faces.map(&:to_h)
        }
      end

      private

      def collapse(indices)
        out = []
        indices.each { |i| out << i unless out.last == i }
        out.pop while out.size > 1 && out.first == out.last
        out
      end

      def polygon_area(indices)
        return 0.0 if indices.size < 3

        v0 = @vertices[indices[0]]
        nx = ny = nz = 0.0
        (1...indices.size - 1).each do |i|
          v1 = @vertices[indices[i]]
          v2 = @vertices[indices[i + 1]]
          ax = v1[0] - v0[0]
          ay = v1[1] - v0[1]
          az = v1[2] - v0[2]
          bx = v2[0] - v0[0]
          by = v2[1] - v0[1]
          bz = v2[2] - v0[2]
          nx += ay * bz - az * by
          ny += az * bx - ax * bz
          nz += ax * by - ay * bx
        end
        Math.sqrt(nx * nx + ny * ny + nz * nz) / 2.0
      end

      def planar?(points, tolerance = 1e-4)
        return true if points.size < 4

        v0, v1, v2 = points[0, 3]
        ax = v1[0] - v0[0]
        ay = v1[1] - v0[1]
        az = v1[2] - v0[2]
        bx = v2[0] - v0[0]
        by = v2[1] - v0[1]
        bz = v2[2] - v0[2]
        nx = ay * bz - az * by
        ny = az * bx - ax * bz
        nz = ax * by - ay * bx
        len = Math.sqrt(nx * nx + ny * ny + nz * nz)
        return true if len < 1e-9

        points[3..].all? do |p|
          d = ((p[0] - v0[0]) * nx + (p[1] - v0[1]) * ny + (p[2] - v0[2]) * nz) / len
          d.abs < tolerance
        end
      end

      def sub3(a, b)
        [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
      end

      def dot3(a, b)
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
      end

      def normalize3(v)
        len = Math.sqrt(dot3(v, v))
        return nil if len < 1e-12

        [v[0] / len, v[1] / len, v[2] / len]
      end

      # Picks one of the two opposite directions deterministically so that
      # edges running either way along a line hash to the same bucket.
      def canonical_direction(dir)
        dir.each do |component|
          return dir.map { |c| -c } if component < -1e-9
          break if component > 1e-9
        end
        dir
      end

      # Point on the line through +point+ with direction +dir+ that is closest
      # to the origin; a stable identifier for the line itself.
      def perpendicular_foot(point, dir)
        t = dot3(point, dir)
        [point[0] - (dir[0] * t), point[1] - (dir[1] * t), point[2] - (dir[2] * t)]
      end

      def quantize(vec, grid = 1e-3)
        vec.map { |c| (c / grid).round }
      end

      def triple(a, b, c)
        cx = b[1] * c[2] - b[2] * c[1]
        cy = b[2] * c[0] - b[0] * c[2]
        cz = b[0] * c[1] - b[1] * c[0]
        a[0] * cx + a[1] * cy + a[2] * cz
      end
    end
  end
end
