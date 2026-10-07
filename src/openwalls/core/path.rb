# frozen_string_literal: true

require_relative 'vec2'
require_relative 'errors'

module OpenWalls
  module Core
    # A wall path is an ordered chain of segments. Each segment is stored as
    # *metadata*, never as a baked polyline: an arc keeps its centre, radius and
    # sweep, and the polyline you see is regenerated from the formula on every
    # rebuild. Re-open the model in two years with a finer tolerance and the
    # curve gets smoother instead of staying as the 12 facets someone happened
    # to draw it with.
    module Path
      # Default chord tolerance for arc tessellation, in millimetres. A 0.5 mm
      # sagitta is invisible at any architectural scale and keeps facet counts
      # sane.
      DEFAULT_TOLERANCE = 0.5

      # Safety cap so a pathological radius/tolerance pair cannot explode the
      # facet count. Set high enough that the sagitta tolerance is actually
      # honoured at real architectural radii -- a cap that silently breaks the
      # tolerance contract is worse than no tolerance at all. At the default
      # 0.5 mm a 20 m radius quarter-circle lands around 112 facets, well
      # inside this.
      MAX_ARC_SEGMENTS = 256
      MIN_ARC_SEGMENTS = 2

      class Segment
        attr_reader :a, :b

        def initialize(a, b)
          @a = a
          @b = b
          raise DegenerateGeometry, "zero-length segment at #{a}" if a.distance_to(b) < Vec2::EPS
        end

        def reverse
          raise NotImplementedError
        end
      end

      class Line < Segment
        def kind
          :line
        end

        def length
          @a.distance_to(@b)
        end

        # Points *after* the start point, so segments can be concatenated
        # without duplicating shared vertices.
        def tail_points(_tolerance)
          [@b]
        end

        def reverse
          Line.new(@b, @a)
        end

        def to_h
          { 'kind' => 'line', 'a' => @a.to_a, 'b' => @b.to_a }
        end
      end

      # Circular arc stored metadata-first: centre, radius, start/end angle and
      # sweep direction.
      class Arc < Segment
        attr_reader :center, :radius, :ccw

        def initialize(a, b, center, ccw)
          super(a, b)
          @center = center
          @radius = (a - center).length
          @ccw = ccw
          raise DegenerateGeometry, 'arc radius is zero' if @radius < Vec2::EPS

          other = (b - center).length
          if (other - @radius).abs > 1e-3
            raise DegenerateGeometry,
                  format('arc endpoints are not equidistant from the centre (%.4f vs %.4f)', @radius, other)
          end
        end

        # Builds the arc through three points -- the way a human draws one:
        # click start, click end, drag the bulge. Returns a Line when the three
        # points are collinear, which is the right answer and not an error.
        def self.through(a, mid, b)
          ax = a.x
          ay = a.y
          bx = mid.x
          by = mid.y
          cx = b.x
          cy = b.y
          d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
          return Line.new(a, b) if d.abs < 1e-9

          ux = ((ax**2 + ay**2) * (by - cy) + (bx**2 + by**2) * (cy - ay) + (cx**2 + cy**2) * (ay - by)) / d
          uy = ((ax**2 + ay**2) * (cx - bx) + (bx**2 + by**2) * (ax - cx) + (cx**2 + cy**2) * (bx - ax)) / d
          center = Vec2.new(ux, uy)
          ccw = (mid - a).cross(b - mid) > 0
          new(a, b, center, ccw)
        end

        def kind
          :arc
        end

        def start_angle
          (@a - @center).angle
        end

        def end_angle
          (@b - @center).angle
        end

        # Always positive, in radians.
        def sweep
          delta = end_angle - start_angle
          if @ccw
            delta += 2 * Math::PI while delta <= Vec2::EPS
          else
            delta -= 2 * Math::PI while delta >= -Vec2::EPS
          end
          delta.abs
        end

        def length
          @radius * sweep
        end

        # Adaptive facet count from a chord (sagitta) tolerance:
        #   sagitta = r * (1 - cos(theta / 2))  =>  theta = 2 * acos(1 - tol/r)
        # so a 20 m radius wall gets far fewer facets than a 300 mm nib for the
        # same visual fidelity.
        def segment_count(tolerance)
          tol = [tolerance, @radius * 0.999].min
          return MAX_ARC_SEGMENTS if tol <= 0

          max_angle = 2.0 * Math.acos(1.0 - (tol / @radius))
          return MAX_ARC_SEGMENTS if max_angle <= 1e-9

          n = (sweep / max_angle).ceil
          n.clamp(MIN_ARC_SEGMENTS, MAX_ARC_SEGMENTS)
        end

        def tail_points(tolerance)
          n = segment_count(tolerance)
          sign = @ccw ? 1.0 : -1.0
          step = sweep * sign / n
          a0 = start_angle
          pts = (1...n).map { |i| @center + Vec2.polar(a0 + step * i, @radius) }
          pts << @b
          pts
        end

        def reverse
          Arc.new(@b, @a, @center, !@ccw)
        end

        def to_h
          { 'kind' => 'arc', 'a' => @a.to_a, 'b' => @b.to_a, 'center' => @center.to_a, 'ccw' => @ccw }
        end
      end

      module_function

      def segment_from_h(hash)
        a = Vec2.new(*hash['a'])
        b = Vec2.new(*hash['b'])
        case hash['kind']
        when 'line' then Line.new(a, b)
        when 'arc'  then Arc.new(a, b, Vec2.new(*hash['center']), !!hash['ccw'])
        else raise InvalidRecord, "unknown segment kind #{hash['kind'].inspect}"
        end
      end

      # Turns a chain of segments into a polyline. Mixing lines and arcs in one
      # path is the normal case, not a special mode.
      def tessellate(segments, tolerance = DEFAULT_TOLERANCE)
        raise DegenerateGeometry, 'path has no segments' if segments.nil? || segments.empty?

        points = [segments.first.a]
        segments.each_with_index do |seg, i|
          if i.positive? && seg.a.distance_to(points.last) > 1e-3
            raise DegenerateGeometry,
                  "path is not continuous: segment #{i} starts at #{seg.a} but previous ended at #{points.last}"
          end
          points.concat(seg.tail_points(tolerance))
        end
        dedupe(points)
      end

      def total_length(segments)
        segments.sum(&:length)
      end

      def dedupe(points)
        out = [points.first]
        points.each { |p| out << p if p.distance_to(out.last) > Vec2::EPS }
        out
      end

      def closed?(segments)
        segments.size > 1 && segments.first.a.distance_to(segments.last.b) < 1e-3
      end
    end
  end
end
