# frozen_string_literal: true

require_relative 'errors'
require_relative 'mesh'
require_relative 'stations'
require_relative 'wall_record'

module OpenWalls
  module Core
    # Turns a WallRecord into geometry.
    #
    # The algorithm is a *ribbon mesher*, and it is deliberately boring:
    #
    #   1. Tessellate the centreline, inserting a station at every arc length
    #      that matters -- each opening edge, each facet of each arched head.
    #   2. Offset that station list into one rail per layer boundary. Every
    #      rail has the same number of points as the centreline, so station
    #      index i means the same place on all of them.
    #   3. Walk the bands between consecutive stations. In each band the set of
    #      openings is constant (step 1 guaranteed that), so the wall skin is
    #      just a stack of quads between the voids.
    #
    # No boolean operations, anywhere. Nothing to go stale, no coplanar-face
    # cleanup, no "the cut failed" state. A curved wall with an arched window
    # in a gable goes through exactly the same code path as a straight wall
    # with nothing in it, which is why that combination actually works.
    class WallBuilder
      EPS = 1e-6

      # Result of a build: one closed mesh per solid layer, plus the stations
      # so callers can place components, dimensions or labels without
      # recomputing anything.
      class Result
        attr_reader :record, :stations, :layers, :skipped_openings

        def initialize(record, stations, layers, skipped_openings)
          @record = record
          @stations = stations
          @layers = layers
          @skipped_openings = skipped_openings
        end

        # [{ layer:, mesh: }] for every layer that produced geometry.
        def each_layer(&block)
          @layers.each(&block)
        end

        def mesh
          @mesh ||= @layers.each_with_object(Mesh.new) { |entry, m| m.merge(entry[:mesh]) }
        end

        def volume
          @layers.sum { |entry| entry[:mesh].volume }
        end

        # Watertight rather than strictly manifold: see Mesh#open_boundary for
        # why the minimum-face output legitimately contains T-vertices.
        def closed?
          @layers.all? { |entry| entry[:mesh].watertight? }
        end

        def open_layers
          @layers.reject { |entry| entry[:mesh].watertight? }.map { |entry| entry[:layer].name }
        end
      end

      attr_reader :record

      def initialize(record, stations: nil)
        @record = record
        @stations = stations
        @length = record.length
      end

      def self.build(record, stations: nil)
        new(record, stations: stations).build
      end

      def build
        points = @record.centerline_points
        stations = @stations || Stations.build(points, splits: required_splits(polyline_length(points)))
        openings = usable_openings
        skipped = @record.openings - openings

        layers = []
        @record.type.layer_spans.each do |layer, near, far|
          next unless layer.solid?

          mesh = build_layer(stations, layer, near, far, openings)
          layers << { layer: layer, near: near, far: far, mesh: mesh } unless mesh.empty?
        end
        Result.new(@record, stations, layers, skipped)
      end

      # Arc lengths that must become stations: every opening edge, enough
      # interior points to describe a curved head, and the apex of a gable.
      #
      # Getting this list right is the entire reason the mesher can stay
      # simple -- after this, no band ever straddles a feature boundary.
      def required_splits(total = @length)
        splits = usable_openings.flat_map do |op|
          [op.start_station, op.end_station] +
            op.profile_parameters(@record.tolerance).map { |u| op.start_station + (u * op.width) }
        end
        # Without a station at mid-span a gable wall would quietly build as a
        # straight slope between its two end heights.
        splits << total / 2.0 if @record.height_mid
        splits
      end

      def polyline_length(points)
        (1...points.size).sum { |i| points[i].distance_to(points[i - 1]) }
      end

      # Openings that actually sit on this wall. Anything hanging off the end
      # is reported rather than silently producing a broken solid.
      def usable_openings
        @usable_openings ||= @record.openings.select do |op|
          op.start_station > -EPS && op.end_station < @length + EPS && op.width > EPS
        end.sort_by(&:start_station)
      end

      private

      # Builds one closed solid between two rails.
      def build_layer(stations, layer, near, far, openings)
        mesh = Mesh.new
        a_off = @record.face_a_offset
        rail_a = stations.rail(a_off - near, miter_limit: @record.miter_limit)
        rail_b = stations.rail(a_off - far, miter_limit: @record.miter_limit)

        base = @record.base_z
        params = stations.parameters
        tops = params.map { |t| base + @record.height_at(t) }
        arcs = stations.arc_lengths
        n = stations.count
        mat = layer.material
        name = layer.name

        (0...n - 1).each do |i|
          mid = (arcs[i] + arcs[i + 1]) / 2.0
          # Sorted by sill so a window stacked over a door yields bands in
          # ascending Z, which is what solid_bands assumes.
          active = openings.select { |op| op.start_station <= mid + EPS && op.end_station >= mid - EPS }
                           .sort_by(&:sill)

          voids_i  = active.map { |op| clamp_void(void_at(op, arcs[i]), base, tops[i]) }
          voids_i1 = active.map { |op| clamp_void(void_at(op, arcs[i + 1]), base, tops[i + 1]) }

          bands_i  = solid_bands(base, tops[i], voids_i)
          bands_i1 = solid_bands(base, tops[i + 1], voids_i1)

          bands_i.each_index do |k|
            lo_i, hi_i = bands_i[k]
            lo_j, hi_j = bands_i1[k]

            # Face A skin: outward normal points away from the wall core.
            mesh.add_quad(
              pt(rail_a[i], lo_i), pt(rail_a[i], hi_i),
              pt(rail_a[i + 1], hi_j), pt(rail_a[i + 1], lo_j),
              tag: :face_a, material: mat, layer: name
            )
            # Face B skin: opposite winding.
            mesh.add_quad(
              pt(rail_b[i], lo_i), pt(rail_b[i + 1], lo_j),
              pt(rail_b[i + 1], hi_j), pt(rail_b[i], hi_i),
              tag: :face_b, material: mat, layer: name
            )
          end

          # Top band, unless an opening breaks through it.
          unless voids_i.each_index.any? { |k| voids_i[k][1] > tops[i] - EPS || voids_i1[k][1] > tops[i + 1] - EPS }
            mesh.add_quad(
              pt(rail_a[i], tops[i]), pt(rail_b[i], tops[i]),
              pt(rail_b[i + 1], tops[i + 1]), pt(rail_a[i + 1], tops[i + 1]),
              tag: :top, material: mat, layer: name
            )
          end

          # Bottom band, unless a door runs through it.
          unless voids_i.each_index.any? { |k|
                   (voids_i[k][0] < base + EPS && voids_i[k][1] > base + EPS) ||
                     (voids_i1[k][0] < base + EPS && voids_i1[k][1] > base + EPS)
                 }
            mesh.add_quad(
              pt(rail_a[i], base), pt(rail_a[i + 1], base),
              pt(rail_b[i + 1], base), pt(rail_b[i], base),
              tag: :bottom, material: mat, layer: name
            )
          end
        end

        add_end_caps(mesh, rail_a, rail_b, base, tops, n, mat, name)
        openings.each { |op| add_reveals(mesh, op, stations, rail_a, rail_b, base, tops, name) }
        mesh
      end

      def add_end_caps(mesh, rail_a, rail_b, base, tops, n, mat, name)
        last = n - 1
        mesh.add_quad(
          pt(rail_a[0], base), pt(rail_b[0], base),
          pt(rail_b[0], tops[0]), pt(rail_a[0], tops[0]),
          tag: :end_start, material: mat, layer: name
        )
        mesh.add_quad(
          pt(rail_a[last], base), pt(rail_a[last], tops[last]),
          pt(rail_b[last], tops[last]), pt(rail_b[last], base),
          tag: :end_end, material: mat, layer: name
        )
      end

      # Jambs, head and sill: the surfaces that face into the void. These are
      # what make an opening read as a real reveal rather than a hole in a
      # sheet of card, and they are generated from the same profile function
      # as the skin, so they can never disagree with it.
      def add_reveals(mesh, opening, stations, rail_a, rail_b, base, tops, layer_name)
        arcs = stations.arc_lengths
        i0 = stations.index_at(opening.start_station)
        i1 = stations.index_at(opening.end_station)
        return if i1 <= i0

        mat = opening.reveal_material

        (i0...i1).each do |i|
          lo_i, hi_i = clamp_void(void_at(opening, arcs[i]), base, tops[i])
          lo_j, hi_j = clamp_void(void_at(opening, arcs[i + 1]), base, tops[i + 1])

          # Sill: faces up into the void. Skipped for a threshold at floor level.
          if lo_i > base + EPS || lo_j > base + EPS
            mesh.add_quad(
              pt(rail_a[i], lo_i), pt(rail_b[i], lo_i),
              pt(rail_b[i + 1], lo_j), pt(rail_a[i + 1], lo_j),
              tag: :reveal_sill, material: mat, layer: layer_name
            )
          end

          # Head: faces down into the void. Omitted where the void breaks
          # through the top of the wall and there is nothing above it.
          next if hi_i > tops[i] - EPS && hi_j > tops[i + 1] - EPS

          mesh.add_quad(
            pt(rail_a[i], hi_i), pt(rail_a[i + 1], hi_j),
            pt(rail_b[i + 1], hi_j), pt(rail_b[i], hi_i),
            tag: :reveal_head, material: mat, layer: layer_name
          )
        end

        lo0, hi0 = clamp_void(void_at(opening, arcs[i0]), base, tops[i0])
        lo1, hi1 = clamp_void(void_at(opening, arcs[i1]), base, tops[i1])

        mesh.add_quad(
          pt(rail_a[i0], lo0), pt(rail_a[i0], hi0),
          pt(rail_b[i0], hi0), pt(rail_b[i0], lo0),
          tag: :reveal_jamb, material: mat, layer: layer_name
        )
        mesh.add_quad(
          pt(rail_a[i1], lo1), pt(rail_b[i1], lo1),
          pt(rail_b[i1], hi1), pt(rail_a[i1], hi1),
          tag: :reveal_jamb, material: mat, layer: layer_name
        )
      end

      # The void of +opening+ at arc length +s+, in absolute Z.
      def void_at(opening, s)
        u = ((s - opening.start_station) / opening.width).clamp(0.0, 1.0)
        band = opening.profile(u)
        base = @record.base_z
        unless band
          pinch = base + opening.sill + (opening.width / 2.0)
          return [pinch, pinch]
        end
        [base + band[0], base + band[1]]
      end

      def clamp_void(void, base, top)
        lo = void[0].clamp(base, top)
        hi = void[1].clamp(base, top)
        hi = lo if hi < lo
        [lo, hi]
      end

      # Solid Z intervals left over once the voids are removed. Always returns
      # voids.size + 1 intervals, so the band at station i pairs up one-to-one
      # with the band at station i+1.
      def solid_bands(base, top, voids)
        cursor = base
        bands = []
        voids.each do |(lo, hi)|
          bands << [cursor, [lo, cursor].max]
          cursor = [hi, cursor].max
        end
        bands << [cursor, [top, cursor].max]
        bands
      end

      def pt(vec, z)
        [vec.x, vec.y, z]
      end
    end
  end
end
