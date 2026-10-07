# frozen_string_literal: true

require_relative 'vec2'
require_relative 'offset'
require_relative 'path'
require_relative 'errors'

module OpenWalls
  module Core
    # A station list is the spine every wall is built on: a tessellated
    # centreline where each vertex carries its arc length, plus lazily built
    # offset rails at any distance.
    #
    # Openings, junctions and height breaks are all expressed as arc lengths
    # and are *inserted as stations before any rail is built*. After that the
    # mesher only ever deals with whole bands between consecutive stations, so
    # it never has to cut a quad in half -- an opening edge always lands
    # exactly on a station boundary.
    class Stations
      attr_reader :points, :arc_lengths

      # +rail_source+ / +rail_range+ let a wall inside a mitered chain borrow
      # the chain's rails instead of re-offsetting its own slice. That is the
      # whole trick behind cross-wall miters: the corner point is computed once
      # for the continuous run, and each wall simply ends on it, so both walls
      # agree on the joint to the last float.
      def initialize(points, rail_source: nil, rail_range: nil, closed: false)
        raise DegenerateGeometry, 'need at least two stations' if points.size < 2

        @points = points.freeze
        @arc_lengths = cumulative(points).freeze
        @rails = {}
        @rail_source = rail_source
        @rail_range = rail_range
        @closed = closed
      end

      def closed?
        @closed
      end

      # Builds a station list from a polyline, inserting a station at each arc
      # length in +splits+ (duplicates and out-of-range values are ignored).
      # Set +closed+ for a ring of walls (a room). The first and last point
      # must coincide; the rails are then offset as a closed loop so the seam
      # corner miters like every other corner instead of showing a butt joint.
      def self.build(points, splits: [], closed: false)
        points = Array(points)
        raise DegenerateGeometry, 'need at least two points' if points.size < 2

        if closed && points.first.distance_to(points.last) > Vec2::EPS
          points = points + [points.first]
        end

        cum = cumulative(points)
        total = cum.last
        wanted = splits.map(&:to_f).select { |s| s > 1e-4 && s < total - 1e-4 }.sort.uniq

        out = []
        si = 0
        (0...points.size - 1).each do |i|
          out << points[i]
          lo = cum[i]
          hi = cum[i + 1]
          span = hi - lo
          while si < wanted.size && wanted[si] < hi - 1e-4
            s = wanted[si]
            if s > lo + 1e-4 && span > Vec2::EPS
              t = (s - lo) / span
              out << points[i].lerp(points[i + 1], t)
            end
            si += 1
          end
        end
        out << points.last
        kept = Path.dedupe(out)
        kept << points.last if closed && kept.last.distance_to(points.last) > Vec2::EPS
        new(kept, closed: closed)
      end

      def self.cumulative(points)
        acc = 0.0
        out = [0.0]
        (1...points.size).each do |i|
          acc += points[i].distance_to(points[i - 1])
          out << acc
        end
        out
      end

      def cumulative(points)
        self.class.cumulative(points)
      end

      def count
        @points.size
      end

      def total_length
        @arc_lengths.last
      end

      # Offset rail at +distance+ to the left of travel. Memoised because a
      # wall asks for the same boundary distances once per layer.
      def rail(distance, miter_limit: Offset::DEFAULT_MITER_LIMIT)
        key = [distance.round(9), miter_limit]
        @rails[key] ||=
          if @rail_source
            @rail_source.rail(distance, miter_limit: miter_limit)[@rail_range]
          elsif @closed
            ring = Offset.polyline(@points[0..-2], distance, miter_limit: miter_limit, closed: true)
            ring + [ring.first]
          else
            Offset.polyline(@points, distance, miter_limit: miter_limit)
          end
      end

      # Index of the station at arc length +s+. Raises if no station sits
      # there, which means somebody forgot to pass it to .build as a split.
      def index_at(s, tolerance: 1e-3)
        idx = @arc_lengths.index { |v| (v - s).abs <= tolerance }
        return idx if idx

        raise DegenerateGeometry, format('no station at arc length %.4f (did you forget a split?)', s)
      end

      # Normalised position (0..1) of each station along the run.
      def parameters
        total = total_length
        return Array.new(count, 0.0) if total < Vec2::EPS

        @arc_lengths.map { |s| s / total }
      end

      # Unit tangent at a station, averaged across the corner.
      def tangent_at(index)
        if index.zero?
          (@points[1] - @points[0]).normalize
        elsif index == count - 1
          (@points[-1] - @points[-2]).normalize
        else
          a = (@points[index] - @points[index - 1]).normalize
          b = (@points[index + 1] - @points[index]).normalize
          sum = a + b
          sum.zero? ? a : sum.normalize
        end
      end

      # A contiguous slice [from_index..to_index] as its own Stations object
      # that still reads its rails from this one, so a wall split out of a
      # mitered chain keeps the chain's corner points as its end caps.
      def slice(from_index, to_index)
        Stations.new(@points[from_index..to_index],
                     rail_source: @rail_source || self,
                     rail_range: shift_range(from_index, to_index))
      end

      private

      def shift_range(from_index, to_index)
        base = @rail_range ? @rail_range.first : 0
        (base + from_index)..(base + to_index)
      end
    end
  end
end
