# frozen_string_literal: true

require_relative 'errors'

module OpenWalls
  module Core
    # An opening is not a hole that was cut. It is a *profile function*.
    #
    # Every shape -- rectangle, segmental arch, semicircle, gable, porthole --
    # is expressed as one method: given a position across the opening's width
    # (u from 0 to 1), what is the bottom and top of the void there? The mesher
    # then builds the wall skin *around* that function and never performs a
    # boolean subtraction at all.
    #
    # That is why openings here are "self-healing" for free: there is no cut to
    # go stale. Move the wall, bend it into an arc, raise the gable -- the skin
    # is regenerated from the same profile and the opening comes with it.
    class OpeningRecord
      SHAPES = %i[rect arch round gable circle].freeze
      KINDS  = %i[door window louver opening].freeze

      attr_reader :id, :kind, :station, :width, :height, :sill, :shape, :rise, :material, :reveal_material, :name

      # station: arc length along the wall centreline to the opening's centre
      # height:  sill to springing line (the top of the rectangular part)
      # rise:    extra height of the curved/pointed head above the springing
      def initialize(id:, station:, width:, height:, kind: :window, sill: 900.0, shape: :rect,
                     rise: nil, material: nil, reveal_material: nil, name: nil)
        @id = id.to_s
        @kind = kind.to_sym
        @station = station.to_f
        @width = width.to_f
        @height = height.to_f
        @sill = sill.to_f
        @shape = shape.to_sym
        @material = material
        @reveal_material = reveal_material
        @name = name || default_name

        raise InvalidRecord, "unknown opening kind #{@kind.inspect}" unless KINDS.include?(@kind)
        raise InvalidRecord, "unknown opening shape #{@shape.inspect}" unless SHAPES.include?(@shape)
        raise InvalidRecord, "opening #{@id} has non-positive width" if @width <= 0
        raise InvalidRecord, "opening #{@id} has negative sill" if @sill.negative?

        @rise = resolve_rise(rise)
        raise InvalidRecord, "opening #{@id} has no height" if head_height <= @sill + 1e-6
      end

      def default_name
        { door: 'Door', window: 'Window', louver: 'Louver', opening: 'Opening' }[@kind] || 'Opening'
      end

      def resolve_rise(value)
        case @shape
        when :rect   then 0.0
        when :round  then @width / 2.0
        when :circle then 0.0
        else (value || @width / 4.0).to_f
        end
      end

      def circle?
        @shape == :circle
      end

      def curved_head?
        %i[arch round circle].include?(@shape)
      end

      # [start, end] arc length along the wall centreline.
      def span
        [@station - @width / 2.0, @station + @width / 2.0]
      end

      def start_station
        @station - @width / 2.0
      end

      def end_station
        @station + @width / 2.0
      end

      # Highest point of the void above the wall base.
      def head_height
        circle? ? @sill + @width : @sill + @height + @rise
      end

      def lowest_point
        @sill
      end

      # The void at normalised position u across the width, as [z_low, z_high]
      # relative to the wall base. Returns nil where the void is empty (the
      # tangent edges of a porthole).
      def profile(u)
        u = u.clamp(0.0, 1.0)
        t = (2.0 * u) - 1.0 # -1 .. +1

        case @shape
        when :rect
          [@sill, @sill + @height]
        when :gable
          [@sill, @sill + @height + @rise * (1.0 - t.abs)]
        when :arch, :round
          [@sill, @sill + @height + @rise * Math.sqrt([1.0 - (t * t), 0.0].max)]
        when :circle
          r = @width / 2.0
          cz = @sill + r
          half = r * Math.sqrt([1.0 - (t * t), 0.0].max)
          return nil if half < 1e-9

          [cz - half, cz + half]
        end
      end

      # Extra station positions (as u in 0..1, exclusive of the ends) needed to
      # describe the head curve to the given chord tolerance. A rectangle needs
      # none; a porthole needs a handful; a 6 m arch needs more than a 900 mm
      # one.
      def profile_parameters(tolerance = 0.5)
        case @shape
        when :rect  then []
        when :gable then [0.5]
        else
          # Sample the head by *angle*, not by width. Uniform steps in u
          # bunch facets where the curve is flat and starves the near-vertical
          # springing, which is both uglier and measurably less accurate; the
          # substitution u = (1 - cos(theta)) / 2 spreads them evenly along
          # the curve instead.
          r = circle? ? @width / 2.0 : curvature_radius
          return [0.25, 0.5, 0.75] if r <= tolerance

          max_angle = 2.0 * Math.acos([1.0 - (tolerance / r), -1.0].max.clamp(-1.0, 1.0))
          n = max_angle <= 1e-9 ? 24 : (Math::PI / max_angle).ceil
          n = n.clamp(4, 48)
          (1...n).map { |i| (1.0 - Math.cos(Math::PI * i / n)) / 2.0 }
        end
      end

      # Radius of the circle through the springing points and the crown, used
      # only to pick a facet count.
      def curvature_radius
        half = @width / 2.0
        return half if @rise <= 1e-9

        ((half * half) + (@rise * @rise)) / (2.0 * @rise)
      end

      # Elevational area of the void, by numeric integration of the profile.
      # Exact for rect and gable; converges fast for the curved heads.
      def area(samples = 512)
        step = 1.0 / samples
        total = 0.0
        samples.times do |i|
          u = (i + 0.5) * step
          band = profile(u)
          total += (band[1] - band[0]) * step * @width if band
        end
        total
      end

      def to_h
        {
          'id' => @id, 'kind' => @kind.to_s, 'name' => @name, 'station' => @station,
          'width' => @width, 'height' => @height, 'sill' => @sill, 'shape' => @shape.to_s,
          'rise' => @rise, 'material' => @material, 'reveal_material' => @reveal_material
        }
      end

      def self.from_h(hash)
        new(
          id: hash['id'], kind: (hash['kind'] || 'window').to_sym, name: hash['name'],
          station: hash['station'], width: hash['width'], height: hash['height'],
          sill: hash['sill'] || 0.0, shape: (hash['shape'] || 'rect').to_sym,
          rise: hash['rise'], material: hash['material'], reveal_material: hash['reveal_material']
        )
      end
    end
  end
end
