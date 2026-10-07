# frozen_string_literal: true

module OpenWalls
  module Core
    # Immutable 2D vector in model units (millimetres).
    #
    # The whole geometry core works in plan (XY); the third dimension is only
    # ever a height scalar. Keeping plan maths in a dedicated 2D type is what
    # makes offsetting, mitering and station arithmetic readable.
    class Vec2
      # Tolerance for geometric comparisons, in millimetres. 1e-6 mm is a
      # nanometre -- far below anything a building model cares about, but large
      # enough to absorb float noise from trig.
      EPS = 1e-6

      attr_reader :x, :y

      def initialize(x, y)
        @x = x.to_f
        @y = y.to_f
        freeze
      end

      def self.[](x, y)
        new(x, y)
      end

      ZERO = new(0, 0)

      # Unit vector at +angle+ radians from +X.
      def self.polar(angle, radius = 1.0)
        new(Math.cos(angle) * radius, Math.sin(angle) * radius)
      end

      def +(other)
        Vec2.new(@x + other.x, @y + other.y)
      end

      def -(other)
        Vec2.new(@x - other.x, @y - other.y)
      end

      def *(scalar)
        Vec2.new(@x * scalar, @y * scalar)
      end

      def /(scalar)
        Vec2.new(@x / scalar, @y / scalar)
      end

      def -@
        Vec2.new(-@x, -@y)
      end

      def dot(other)
        @x * other.x + @y * other.y
      end

      # 2D cross product (signed area of the parallelogram). Positive when
      # +other+ is counter-clockwise from +self+.
      def cross(other)
        @x * other.y - @y * other.x
      end

      def length
        Math.sqrt(length2)
      end

      def length2
        @x * @x + @y * @y
      end

      def zero?
        length2 < EPS * EPS
      end

      def normalize
        len = length
        raise DegenerateGeometry, "cannot normalize a zero-length vector" if len < EPS

        Vec2.new(@x / len, @y / len)
      end

      # Left-hand normal: rotates 90 degrees counter-clockwise.
      def perp
        Vec2.new(-@y, @x)
      end

      def rotate(angle)
        c = Math.cos(angle)
        s = Math.sin(angle)
        Vec2.new(@x * c - @y * s, @x * s + @y * c)
      end

      def lerp(other, t)
        Vec2.new(@x + (other.x - @x) * t, @y + (other.y - @y) * t)
      end

      def distance_to(other)
        (self - other).length
      end

      def angle
        Math.atan2(@y, @x)
      end

      def round_to(decimals)
        Vec2.new(@x.round(decimals), @y.round(decimals))
      end

      def ==(other)
        other.is_a?(Vec2) && (@x - other.x).abs < EPS && (@y - other.y).abs < EPS
      end
      alias eql? ==

      def hash
        [(@x / EPS).round, (@y / EPS).round].hash
      end

      def to_a
        [@x, @y]
      end

      def to_s
        format('(%.3f, %.3f)', @x, @y)
      end

      def inspect
        "#<Vec2 #{self}>"
      end

      # Intersection of two infinite lines, each given as a point and a
      # direction. Returns nil when the lines are (near) parallel.
      def self.line_intersection(p1, d1, p2, d2)
        denom = d1.cross(d2)
        return nil if denom.abs < 1e-12

        t = (p2 - p1).cross(d2) / denom
        p1 + d1 * t
      end
    end
  end
end
