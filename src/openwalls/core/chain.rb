# frozen_string_literal: true

require_relative 'vec2'
require_relative 'stations'
require_relative 'wall_builder'

module OpenWalls
  module Core
    # Auto-mitering across separate walls.
    #
    # Most tools solve corners by special-casing the joint: find the
    # neighbour, work out a bisector, trim two solids against each other, hope
    # the boolean holds. This does something simpler and more robust. Walls
    # that meet end-to-start and share a compatible layer stack are
    # concatenated into one continuous centreline, offset *once* as a single
    # run -- which makes every corner an ordinary interior miter -- and then
    # sliced back apart at the junction vertices.
    #
    # Because the slice happens on the already-mitered rails, each wall's end
    # cap lands exactly on the bisector, and the two walls agree on the corner
    # to the last float. Edit one endpoint and the whole run re-miters, because
    # there was never any per-corner state to go stale.
    module Chain
      JOIN_TOLERANCE = 1e-3

      # One continuous run of walls.
      Run = Struct.new(:records, :closed, keyword_init: true)

      module_function

      # Two walls only miter when the joint is actually well defined: same
      # layer boundaries to miter, same justification, same base. Anything
      # else gets a clean butt joint, which is honest, instead of a guess that
      # looks wrong in section.
      def compatible?(a, b)
        a.type.miter_signature == b.type.miter_signature &&
          a.justification == b.justification &&
          (a.base_z - b.base_z).abs < 1e-6
      end

      def start_point(record)
        record.segments.first.a
      end

      def end_point(record)
        record.segments.last.b
      end

      def key(point)
        [(point.x / JOIN_TOLERANCE).round, (point.y / JOIN_TOLERANCE).round]
      end

      # Groups records into maximal head-to-tail runs. A vertex where three or
      # more walls meet is never chained through -- there is no single correct
      # miter there, so all of them butt.
      def group(records)
        incidence = Hash.new { |h, k| h[k] = [] }
        records.each do |r|
          incidence[key(start_point(r))] << r
          incidence[key(end_point(r))] << r
        end

        successor = {}
        predecessor = {}
        records.each do |a|
          k = key(end_point(a))
          next unless incidence[k].size == 2

          b = records.find { |c| !c.equal?(a) && key(start_point(c)) == k }
          next unless b && compatible?(a, b)
          next if successor.key?(a.id) || predecessor.key?(b.id)

          successor[a.id] = b
          predecessor[b.id] = a
        end

        by_id = records.each_with_object({}) { |r, h| h[r.id] = r }
        visited = {}
        runs = []

        records.each do |record|
          next if visited[record.id]

          # Walk back to the head of this run (or detect a ring).
          head = record
          seen = { head.id => true }
          while (prev = predecessor[head.id]) && !seen[prev.id]
            head = prev
            seen[head.id] = true
          end
          closed = !predecessor[head.id].nil?

          chain = []
          node = head
          loop do
            break if node.nil? || visited[node.id]

            visited[node.id] = true
            chain << node
            node = successor[node.id]
          end
          runs << Run.new(records: chain, closed: closed && chain.size > 2)
        end

        runs.reject { |r| r.records.empty? }.each { |r| r.records.map! { |x| by_id[x.id] } }
      end

      # => { wall_id => Stations or nil }. nil means "build your own stations",
      # which is the right answer for a wall that is not chained to anything.
      def solve(records)
        out = {}
        group(records).each do |run|
          if run.records.size < 2
            out[run.records.first.id] = nil if run.records.first
            next
          end

          points = []
          starts = []
          run.records.each_with_index do |rec, i|
            starts << polyline_length(points)
            cp = rec.centerline_points
            cp = cp.drop(1) if i.positive?
            points.concat(cp)
          end

          splits = run.records.each_with_index.flat_map do |rec, i|
            WallBuilder.new(rec).required_splits.map { |s| starts[i] + s }
          end

          stations = Stations.build(points, splits: splits, closed: run.closed)

          run.records.each_with_index do |rec, i|
            from = starts[i]
            to = i == run.records.size - 1 ? stations.total_length : starts[i + 1]
            begin
              out[rec.id] = stations.slice(stations.index_at(from), stations.index_at(to))
            rescue DegenerateGeometry
              out[rec.id] = nil # fall back to an unmitered build rather than failing
            end
          end
        end
        out
      end

      def polyline_length(points)
        return 0.0 if points.size < 2

        total = 0.0
        (1...points.size).each { |i| total += points[i].distance_to(points[i - 1]) }
        total
      end
    end
  end
end
