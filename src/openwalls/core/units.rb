# frozen_string_literal: true

module OpenWalls
  module Core
    # The core works exclusively in millimetres. Nothing in core/ knows what an
    # inch is; the SketchUp adapter converts at the boundary (SketchUp's
    # internal unit is the inch). Keeping one unit inside the engine removes a
    # whole category of bug.
    module Units
      MM_PER_INCH  = 25.4
      MM_PER_FOOT  = 304.8

      module_function

      def inches_to_mm(value)
        value * MM_PER_INCH
      end

      def mm_to_inches(value)
        value / MM_PER_INCH
      end

      def feet_to_mm(value)
        value * MM_PER_FOOT
      end

      def mm_to_m(value)
        value / 1000.0
      end

      # mm^3 -> m^3
      def mm3_to_m3(value)
        value / 1_000_000_000.0
      end

      # mm^2 -> m^2
      def mm2_to_m2(value)
        value / 1_000_000.0
      end

      # Parses the dimension strings people actually type into dialogs:
      #   "230"  "230mm"  "2.3 m"  "9in"  "9\""  "3'"  "3' 6\""  "3'-6 1/2\""
      # Returns millimetres as a Float. Raises InvalidRecord on nonsense.
      def parse(text)
        raise InvalidRecord, 'empty dimension' if text.nil?

        str = text.to_s.strip.downcase
        raise InvalidRecord, 'empty dimension' if str.empty?

        return str.to_f if str =~ /\A-?\d+(\.\d+)?\z/

        if (m = str.match(/\A(-?[\d.]+)\s*(mm|cm|m|in|"|ft|'|)\z/))
          value = m[1].to_f
          case m[2]
          when 'mm', '' then return value
          when 'cm'     then return value * 10.0
          when 'm'      then return value * 1000.0
          when 'in', '"' then return inches_to_mm(value)
          when 'ft', "'" then return feet_to_mm(value)
          end
        end

        # Imperial compound: 3' 6 1/2"
        if (m = str.match(%r{\A(?:(-?\d+)\s*')?\s*-?\s*(?:(\d+)\s*)?(?:(\d+)/(\d+)\s*)?"?\z})) && m[1..3].any?
          feet   = m[1].to_f
          inches = m[2].to_f
          inches += m[3].to_f / m[4].to_f if m[3] && m[4]
          sign = feet.negative? ? -1.0 : 1.0
          return feet_to_mm(feet) + sign * inches_to_mm(inches)
        end

        raise InvalidRecord, "cannot read dimension #{text.inspect}"
      end

      # Human-readable millimetres, trimming pointless decimals.
      def format_mm(value)
        rounded = value.round(1)
        rounded == rounded.to_i ? "#{rounded.to_i} mm" : "#{rounded} mm"
      end
    end
  end
end
