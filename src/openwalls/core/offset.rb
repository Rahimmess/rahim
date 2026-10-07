# frozen_string_literal: true

require_relative 'vec2'
require_relative 'errors'

module OpenWalls
  module Core
    # Parallel offsetting of an open or closed polyline.
    #
    # The one invariant that matters here: the output has exactly one point per
    # input point. Every rail of a wall (each layer boundary, the two faces,
    # the finishes) is therefore index-aligned with the centreline, so a
    # station index means the same thing on every rail. That is what lets the
    # mesher stitch layers, openings and top profiles together without any
    # nearest-point searching.
    #
    # The price is that a corner sharper than the miter limit is *clamped*
    # rather than bevelled (a bevel would add a point and break the alignment).
    # Validation reports those corners so the user can see them.
    module Offset
      # Miter length is capped at this multiple of the offset distance.
      # 4.0 starts clamping at roughly a 29 degree included angle.
      DEFAULT_MITER_LIMIT = 4.0

      module_function

      # Offsets +points+ by +distance+ to the left of travel direction
      # (negative goes right). Returns an Array<Vec2> of the same size.
      def polyline(points, distance, miter_limit: DEFAULT_MITER_LIMIT, closed: false)
        raise DegenerateGeometry, 'need at least two points to offset' if points.size < 2
        return points.dup if distance.abs < Vec2::EPS

        n = points.size
        dirs = []
        (0...(closed ? n : n - 1)).each do |i|
          a = points[i]
          b = points[(i + 1) % n]
          dirs << (b - a).normalize
        end
        normals = dirs.map { |d| d.perp * distance }

        (0...n).map do |i|
          if !closed && i.zero?
            points[i] + normals[0]
          elsif !closed && i == n - 1
            points[i] + normals[-1]
          else
            prev_n = normals[(i - 1) % normals.size]
            next_n = normals[i % normals.size]
            miter_point(points[i], prev_n, next_n, distance, miter_limit)
          end
        end
      end

      # Corner point where two offset lines meet.
      def miter_point(vertex, prev_normal, next_normal, distance, miter_limit)
        sum = prev_normal + next_normal
        # A full 180 degree reversal (a spike) has no miter; fall back to the
        # incoming offset so the rail stays continuous instead of flying off.
        return vertex + prev_normal if sum.zero?

        direction = sum.normalize
        cos_half = direction.dot(prev_normal) / distance
        return vertex + prev_normal if cos_half.abs < 1e-9

        len = distance / cos_half
        cap = miter_limit * distance.abs
        len = len.positive? ? [len, cap].min : [len, -cap].max
        vertex + direction * len
      end

      # Corners that the miter limit had to clamp, reported as
      # [index, included_angle_degrees]. The UI surfaces these as warnings
      # rather than silently drawing a slightly wrong corner.
      def clamped_corners(points, distance, miter_limit: DEFAULT_MITER_LIMIT, closed: false)
        return [] if points.size < 3 || distance.abs < Vec2::EPS

        n = points.size
        out = []
        range = closed ? (0...n) : (1...n - 1)
        range.each do |i|
          a = points[(i - 1) % n]
          b = points[i]
          c = points[(i + 1) % n]
          d1 = (b - a).normalize
          d2 = (c - b).normalize
          cos_half = Math.sqrt([(1.0 + d1.dot(d2)) / 2.0, 0.0].max)
          next if cos_half < 1e-9

          out << [i, (Math.acos(d1.dot(d2).clamp(-1.0, 1.0)) * 180.0 / Math::PI - 180.0).abs] if 1.0 / cos_half > miter_limit
        end
        out
      end
    end
  end
end
