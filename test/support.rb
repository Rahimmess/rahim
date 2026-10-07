# frozen_string_literal: true

require_relative '../src/openwalls/core'

# Shared fixtures. Deliberately tiny: the point of these tests is that real
# wall geometry can be asserted against closed-form answers.
module Fixtures
  include OpenWalls::Core
  V = OpenWalls::Core::Vec2
  C = OpenWalls::Core

  module_function

  def v(x, y)
    OpenWalls::Core::Vec2.new(x, y)
  end

  def line(ax, ay, bx, by)
    OpenWalls::Core::Path::Line.new(v(ax, ay), v(bx, by))
  end

  # One solid layer, so volume assertions are unambiguous.
  def simple_type(thickness = 200.0, material = 'Concrete')
    OpenWalls::Core::WallType.new(
      id: 'simple', name: "Solid #{thickness.to_i}",
      layers: [OpenWalls::Core::Layer.new(name: 'Core', kind: :structure, thickness: thickness, material: material)]
    )
  end

  def cavity_type
    OpenWalls::Core::WallType.new(
      id: 'cavity', name: 'Cavity 300',
      layers: [
        OpenWalls::Core::Layer.new(name: 'Brick', kind: :masonry, thickness: 100, material: 'Brick'),
        OpenWalls::Core::Layer.new(name: 'Cavity', kind: :cavity, thickness: 50),
        OpenWalls::Core::Layer.new(name: 'Block', kind: :masonry, thickness: 150, material: 'Block')
      ]
    )
  end

  def straight_wall(length: 5000.0, thickness: 200.0, height: 2700.0, openings: [], **extra)
    OpenWalls::Core::WallRecord.new(
      id: extra.delete(:id) || 'w1',
      segments: [line(0, 0, length, 0)],
      type: extra.delete(:type) || simple_type(thickness),
      height: height,
      openings: openings,
      **extra
    )
  end

  def window(id: 'o1', station: 2500.0, width: 1200.0, height: 1400.0, sill: 900.0, shape: :rect, rise: nil)
    OpenWalls::Core::OpeningRecord.new(
      id: id, kind: :window, station: station, width: width,
      height: height, sill: sill, shape: shape, rise: rise
    )
  end

  def door(id: 'd1', station: 1500.0, width: 900.0, height: 2100.0)
    OpenWalls::Core::OpeningRecord.new(
      id: id, kind: :door, station: station, width: width, height: height, sill: 0.0
    )
  end

  # Length of the tessellated centreline. Several volume identities are exact
  # against this rather than against the analytic arc length, because the
  # mesher builds what it tessellated.
  def polyline_length(points)
    (1...points.size).sum { |i| points[i].distance_to(points[i - 1]) }
  end
end
