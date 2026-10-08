# frozen_string_literal: true

require_relative 'errors'
require_relative 'mesh'
require_relative 'stations'
require_relative 'units'
require_relative 'wall_record'

module OpenWalls
  module Core
    # Schematic timber and cold-formed steel framing for framed wall layers.
    #
    # A framed layer remains an ordinary member of a WallType: it occupies its
    # place in the thickness stack, but is represented by a cutting plan rather
    # than a solid slab. Planning is in wall-local coordinates (station along
    # the centreline, depth through the layer, and height above the base), so
    # the same plan works on straight, curved, sloping and gabled walls.
    #
    # These standards are starting points for coordination and quantity
    # takeoff, not structural design. Header sizes and bearing must be checked
    # by a qualified designer for the actual loads and jurisdiction.
    module Framing
      ROLES = %i[
        sole_plate top_plate stud king_stud jack_stud
        header sill cripple nogging
      ].freeze

      class Member
        attr_reader :role, :section, :s0, :s1, :t0, :t1, :z0, :z1,
                    :z0_end, :z1_end, :material, :label

        # z0/z1 describe the underside/top at s0. z0_end/z1_end optionally
        # describe a raking member's underside/top at s1.
        def initialize(role:, section:, s0:, s1:, t0:, t1:, z0:, z1:,
                       z0_end: nil, z1_end: nil, material: nil, label: nil)
          @role = role.to_sym
          @section = section.to_s
          @s0 = s0.to_f
          @s1 = s1.to_f
          @t0 = t0.to_f
          @t1 = t1.to_f
          @z0 = z0.to_f
          @z1 = z1.to_f
          @z0_end = (z0_end.nil? ? z0 : z0_end).to_f
          @z1_end = (z1_end.nil? ? z1 : z1_end).to_f
          @material = material
          @label = label

          raise InvalidRecord, "unknown framing role #{@role.inspect}" unless ROLES.include?(@role)
          raise InvalidRecord, 'framing member has no length' if @s1 <= @s0
          raise InvalidRecord, 'framing member has no depth' if @t1 <= @t0
          raise InvalidRecord, 'framing member has no height' if [@z1 - @z0, @z1_end - @z0_end].min <= 0
        end

        def raking?
          (@z0_end - @z0).abs > 1e-9 || (@z1_end - @z1).abs > 1e-9
        end

        # The length to order: vertical cut height for studs, and true sloped
        # run length for plates and other horizontal members.
        def cut_length
          return @z1 - @z0 if vertical?

          run = @s1 - @s0
          rise = ((@z0_end - @z0) + (@z1_end - @z1)) / 2.0
          Math.sqrt((run * run) + (rise * rise))
        end

        def vertical?
          %i[stud king_stud jack_stud cripple].include?(@role)
        end

        # Mean section volume. For a raking member this integrates the linear
        # change in height exactly; along a curved wall s is arc length.
        def volume
          mean_height = (((@z1 - @z0) + (@z1_end - @z0_end)) / 2.0)
          (@s1 - @s0) * (@t1 - @t0) * mean_height
        end

        def description
          format('%s  %d mm', @section, cut_length.round)
        end

        def to_h
          {
            'role' => @role.to_s, 'section' => @section, 'material' => @material,
            'label' => @label, 's0' => @s0, 's1' => @s1,
            't0' => @t0, 't1' => @t1, 'z0' => @z0, 'z1' => @z1,
            'z0_end' => @z0_end, 'z1_end' => @z1_end,
            'raking' => raking?, 'cut_length' => cut_length
          }
        end
      end

      # A framing standard describes stock sizes and a repeatable layout.
      class Standard
        attr_reader :id, :name, :region, :stud_width, :stud_depth, :spacing,
                    :plate_count, :plate_thickness, :sill_thickness,
                    :header_depths, :min_bearing, :nogging_spacing, :material, :imperial

        DEFAULT_HEADER_DEPTHS = [
          [900.0, 140.0], [1500.0, 190.0], [2100.0, 240.0],
          [2700.0, 290.0], [3600.0, 390.0]
        ].freeze

        def initialize(id:, name:, region:, stud_width:, spacing:, stud_depth: nil,
                       plate_count: 2, plate_thickness: nil, sill_thickness: nil,
                       header_depths: nil, min_bearing: 90.0, nogging_spacing: nil,
                       material: 'Softwood', imperial: false)
          @id = id.to_s
          @name = name.to_s
          @region = region.to_s
          @stud_width = stud_width.to_f
          @stud_depth = (stud_depth || 0).to_f # zero means fill the framed layer
          @spacing = spacing.to_f
          @plate_count = Integer(plate_count)
          @plate_thickness = (plate_thickness || stud_width).to_f
          @sill_thickness = (sill_thickness || @plate_thickness).to_f
          @header_depths = Array(header_depths || DEFAULT_HEADER_DEPTHS).sort_by(&:first)
          @min_bearing = min_bearing.to_f
          @nogging_spacing = nogging_spacing && nogging_spacing.to_f
          @material = material
          @imperial = !!imperial

          raise InvalidRecord, 'framing standard needs an id and name' if @id.empty? || @name.empty?
          raise InvalidRecord, 'stud width and spacing must be positive' if @stud_width <= 0 || @spacing <= 0
          raise InvalidRecord, 'plate thickness must be positive' if @plate_thickness <= 0
          raise InvalidRecord, 'plate count must be positive' if @plate_count < 1
          raise InvalidRecord, 'minimum bearing cannot be negative' if @min_bearing.negative?
          raise InvalidRecord, 'nogging spacing must be positive' if @nogging_spacing && @nogging_spacing <= 0
          raise InvalidRecord, 'header depth table cannot be empty' if @header_depths.empty?
        end

        # Span -> smallest listed depth that covers it. The last listed depth
        # is returned for an over-span opening; plan() reports that condition.
        def header_depth(span)
          found = @header_depths.find { |limit, _depth| span <= limit }
          found ? found[1] : @header_depths.last[1]
        end

        def max_header_span
          @header_depths.last[0]
        end

        def to_h
          { 'id' => @id, 'name' => @name, 'region' => @region }
        end
      end

      STANDARDS = {
        'us-2x4-16' => Standard.new(
          id: 'us-2x4-16', name: 'US 2x4 @ 16" o.c.', region: 'US / IRC',
          stud_width: 38.1, stud_depth: 88.9, spacing: Units.inches_to_mm(16),
          plate_count: 2, min_bearing: 38.1, imperial: true
        ),
        'us-2x6-16' => Standard.new(
          id: 'us-2x6-16', name: 'US 2x6 @ 16" o.c.', region: 'US / IRC',
          stud_width: 38.1, stud_depth: 139.7, spacing: Units.inches_to_mm(16),
          plate_count: 2, min_bearing: 38.1, imperial: true
        ),
        'us-2x6-24' => Standard.new(
          id: 'us-2x6-24', name: 'US 2x6 @ 24" o.c.', region: 'US / IRC',
          stud_width: 38.1, stud_depth: 139.7, spacing: Units.inches_to_mm(24),
          plate_count: 2, min_bearing: 38.1, imperial: true
        ),
        'ca-38x140-400' => Standard.new(
          id: 'ca-38x140-400', name: 'Canadian 38x140 @ 400 mm', region: 'Canada / NBC',
          stud_width: 38.0, stud_depth: 140.0, spacing: 400.0, plate_count: 2
        ),
        'uk-38x89-600' => Standard.new(
          id: 'uk-38x89-600', name: 'UK 38x89 @ 600 mm', region: 'UK / BS 5268',
          stud_width: 38.0, stud_depth: 89.0, spacing: 600.0,
          plate_count: 1, nogging_spacing: 1350.0
        ),
        'uk-38x140-600' => Standard.new(
          id: 'uk-38x140-600', name: 'UK 38x140 @ 600 mm', region: 'UK / BS 5268',
          stud_width: 38.0, stud_depth: 140.0, spacing: 600.0,
          plate_count: 1, nogging_spacing: 1350.0
        ),
        'au-90x45-450' => Standard.new(
          id: 'au-90x45-450', name: 'Australian 90x45 @ 450 mm', region: 'Australia / AS 1684',
          stud_width: 45.0, stud_depth: 90.0, spacing: 450.0, plate_count: 1,
          nogging_spacing: 1350.0
        ),
        'au-90x35-600' => Standard.new(
          id: 'au-90x35-600', name: 'Australian 90x35 @ 600 mm', region: 'Australia / AS 1684',
          stud_width: 35.0, stud_depth: 90.0, spacing: 600.0, plate_count: 1,
          nogging_spacing: 1350.0
        ),
        'eu-60x120-625' => Standard.new(
          id: 'eu-60x120-625', name: 'European 60x120 @ 625 mm', region: 'EU / Eurocode 5',
          stud_width: 60.0, stud_depth: 120.0, spacing: 625.0, plate_count: 1
        ),
        'din-cw75-625' => Standard.new(
          id: 'din-cw75-625', name: 'Metal CW75 in UW75 @ 625 mm', region: 'DIN 18182',
          stud_width: 0.6, stud_depth: 75.0, spacing: 625.0,
          plate_count: 1, plate_thickness: 40.0, min_bearing: 0.0,
          material: 'Galvanised steel'
        ),
        'din-cw100-625' => Standard.new(
          id: 'din-cw100-625', name: 'Metal CW100 in UW100 @ 625 mm', region: 'DIN 18182',
          stud_width: 0.6, stud_depth: 100.0, spacing: 625.0,
          plate_count: 1, plate_thickness: 40.0, min_bearing: 0.0,
          material: 'Galvanised steel'
        ),
        'aisi-362s-16' => Standard.new(
          id: 'aisi-362s-16', name: 'Steel 362S162 @ 16" o.c.', region: 'AISI S220',
          stud_width: 1.37, stud_depth: 92.1, spacing: Units.inches_to_mm(16),
          plate_count: 1, plate_thickness: 41.3, min_bearing: 0.0,
          material: 'Galvanised steel', imperial: true
        )
      }.freeze

      # Planned framing for one framed layer of one wall.
      class Result
        attr_reader :members, :standard, :layer, :warnings

        def initialize(members:, standard:, layer:, warnings: [])
          @members = members.freeze
          @standard = standard
          @layer = layer
          @warnings = warnings.freeze
        end

        def count(role = nil)
          role ? @members.count { |member| member.role == role.to_sym } : @members.size
        end

        def volume
          @members.sum(&:volume)
        end

        # Identical stock grouped in the form a saw or supplier can use.
        def cutting_list
          groups = Hash.new { |hash, key| hash[key] = [] }
          @members.each do |member|
            key = [member.section, member.cut_length.round, member.role, member.material]
            groups[key] << member
          end
          groups.map do |(section, length, role, material), members|
            {
              'Section' => section, 'Role' => role.to_s.tr('_', ' '),
              'Material' => material, 'Length (mm)' => length,
              'Count' => members.size,
              'Total length (m)' => Units.mm_to_m(length * members.size).round(3)
            }
          end.sort_by { |row| [row['Section'], -row['Length (mm)'], row['Role']] }
        end
      end

      module_function

      def standard(id)
        STANDARDS[id.to_s] || raise(InvalidRecord, "unknown framing standard #{id.inspect}")
      end

      def standards
        STANDARDS.values
      end

      # Plan members in wall-local coordinates. A framed layer must explicitly
      # select a standard; invalid/too-short walls are reported by WallBuilder
      # as a framing warning without suppressing the rest of the wall.
      def plan(record, layer)
        raise InvalidRecord, "layer #{layer.name.inspect} is not framed" unless layer.framed?

        spec = standard(layer.framing)
        length = record.length
        raise DegenerateGeometry, 'wall is too short to frame' if length <= spec.stud_width

        if spec.stud_depth.positive? && spec.stud_depth > layer.thickness + 1e-6
          raise InvalidRecord,
                "framing standard #{spec.id} is #{spec.stud_depth.round(1)} mm deep but " \
                "layer #{layer.name.inspect} is only #{layer.thickness.round(1)} mm thick"
        end
        depth = spec.stud_depth.zero? ? layer.thickness : spec.stud_depth
        t0 = (layer.thickness - depth) / 2.0
        t1 = t0 + depth
        plate_t = spec.plate_thickness
        top_plates_thickness = plate_t * spec.plate_count
        top_at = lambda do |station|
          record.height_at((station / length).clamp(0.0, 1.0)) - top_plates_thickness
        end
        min_height = [record.height_at(0.0), record.height_at(0.5), record.height_at(1.0)].min
        if min_height - top_plates_thickness <= plate_t
          raise DegenerateGeometry, "wall is too short (#{min_height.round} mm) to frame"
        end

        members = [plate(spec, :sole_plate, 0.0, length, t0, t1, 0.0, plate_t, layer)]
        top_runs(record, length).each do |run_s0, run_s1|
          spec.plate_count.times do |index|
            lift = index * plate_t
            members << Member.new(
              role: :top_plate, section: section_name(spec, plate_t),
              s0: run_s0, s1: run_s1, t0: t0, t1: t1,
              z0: top_at.call(run_s0) + lift,
              z1: top_at.call(run_s0) + lift + plate_t,
              z0_end: top_at.call(run_s1) + lift,
              z1_end: top_at.call(run_s1) + lift + plate_t,
              material: layer.material || spec.material
            )
          end
        end

        openings = record.openings.select do |opening|
          opening.start_station >= -1e-6 && opening.end_station <= length + 1e-6
        end.sort_by(&:start_station)
        blocked = []
        warnings = []
        openings.each do |opening|
          opening_members, opening_warnings = opening_frame(
            spec, opening, layer, t0, t1, plate_t, top_at, length
          )
          members.concat(opening_members)
          warnings.concat(opening_warnings)
          frame_margin = (bearing_stud_count(spec) + 1) * spec.stud_width
          blocked << [opening.start_station - frame_margin,
                      opening.end_station + frame_margin]
        end

        positions = regular_stud_positions(spec, length)
        members.concat(common_studs(spec, positions, t0, t1, plate_t, top_at, blocked, layer))
        if spec.nogging_spacing
          top = [top_at.call(0.0), top_at.call(length / 2.0), top_at.call(length)].min
          members.concat(noggings(spec, positions, t0, t1, plate_t, top, blocked, layer))
        end

        Result.new(members: members, standard: spec, layer: layer, warnings: warnings)
      end

      def top_runs(record, length)
        record.height_mid ? [[0.0, length / 2.0], [length / 2.0, length]] : [[0.0, length]]
      end

      def plate(spec, role, s0, s1, t0, t1, z0, z1, layer)
        Member.new(role: role, section: section_name(spec, z1 - z0),
                   s0: s0, s1: s1, t0: t0, t1: t1, z0: z0, z1: z1,
                   material: layer.material || spec.material)
      end

      def stud(spec, role, center, t0, t1, z0, z1, layer)
        half = spec.stud_width / 2.0
        Member.new(role: role, section: section_name(spec, spec.stud_width),
                   s0: center - half, s1: center + half, t0: t0, t1: t1,
                   z0: z0, z1: z1, material: layer.material || spec.material)
      end

      def section_name(spec, along_wall)
        depth = spec.stud_depth.zero? ? nil : spec.stud_depth
        return format('%gx%g', along_wall.round(1), depth.round(1)) if depth

        format('%g wide', along_wall.round(1))
      end

      def regular_stud_positions(spec, length)
        half = spec.stud_width / 2.0
        positions = [half]
        position = spec.spacing
        while position < length - half - 1e-6
          positions << position
          position += spec.spacing
        end
        positions << length - half
        positions.uniq
      end

      def common_studs(spec, positions, t0, t1, bottom, top_at, blocked, layer)
        half = spec.stud_width / 2.0
        positions.each_with_object([]) do |position, out|
          next if positions_clash?(position, half, blocked)

          out << stud(spec, :stud, position, t0, t1, bottom, top_at.call(position), layer)
        end
      end

      def positions_clash?(position, half, blocked)
        blocked.any? do |start_station, end_station|
          position + half > start_station + 1e-6 && position - half < end_station - 1e-6
        end
      end

      def bearing_stud_count(spec)
        [ (spec.min_bearing / spec.stud_width).ceil, 1].max
      end

      # King/jack studs, header, sill and cripple studs around one opening.
      # Warnings are returned separately so the cutting list only contains
      # actual members.
      def opening_frame(spec, opening, layer, t0, t1, bottom, top_at, length)
        out = []
        warnings = []
        half = spec.stud_width / 2.0
        rough_lo = opening.start_station
        rough_hi = opening.end_station
        head = opening.head_height
        sill = opening.sill
        bearing_count = bearing_stud_count(spec)
        jack_left = Array.new(bearing_count) do |index|
          rough_lo - ((index + 0.5) * spec.stud_width)
        end
        jack_right = Array.new(bearing_count) do |index|
          rough_hi + ((index + 0.5) * spec.stud_width)
        end
        king_lo = rough_lo - ((bearing_count + 0.5) * spec.stud_width)
        king_hi = rough_hi + ((bearing_count + 0.5) * spec.stud_width)

        if king_lo - half < -1e-6 || king_hi + half > length + 1e-6
          warnings << "#{opening.name} #{opening.id} is too close to a wall end for a full frame."
          return [out, warnings]
        end

        # Full-height kings sit outside the required bearing pack. The header
        # bears on the jack pack and the clear gap above it gets cripples.
        out << stud(spec, :king_stud, king_lo, t0, t1, bottom, top_at.call(king_lo), layer)
        out << stud(spec, :king_stud, king_hi, t0, t1, bottom, top_at.call(king_hi), layer)

        headroom = [top_at.call(rough_lo), top_at.call(rough_hi)].min - head
        if headroom < spec.plate_thickness
          warnings << "#{opening.name} #{opening.id} has no room for a header; detail it by hand."
        else
          header_span = king_hi - king_lo - spec.stud_width
          if header_span > spec.max_header_span
            warnings << "#{opening.name} #{opening.id} exceeds the " \
                        "#{spec.max_header_span.round} mm header rule-of-thumb span."
          end
          header_depth = [spec.header_depth(header_span), headroom].min
          if header_depth.positive?
            jack_left.each do |center|
              out << stud(spec, :jack_stud, center, t0, t1, bottom, head, layer)
            end
            jack_right.each do |center|
              out << stud(spec, :jack_stud, center, t0, t1, bottom, head, layer)
            end
            out << Member.new(
              role: :header, section: section_name(spec, header_depth),
              s0: king_lo + half, s1: king_hi - half, t0: t0, t1: t1,
              z0: head, z1: head + header_depth,
              material: layer.material || spec.material, label: opening.id
            )
            out.concat(cripples(spec, rough_lo, rough_hi, t0, t1,
                                head + header_depth, top_at, layer))
          else
            warnings << "#{opening.name} #{opening.id} has no usable header depth."
          end
        end

        if sill > bottom + 1e-6
          sill_bottom = [bottom, sill - spec.sill_thickness].max
          out << Member.new(
            role: :sill, section: section_name(spec, spec.sill_thickness),
            s0: rough_lo - (bearing_count * spec.stud_width),
            s1: rough_hi + (bearing_count * spec.stud_width), t0: t0, t1: t1,
            z0: sill_bottom, z1: sill,
            material: layer.material || spec.material, label: opening.id
          )
          out.concat(cripples(spec, rough_lo, rough_hi, t0, t1, bottom,
                              ->(_station) { sill_bottom }, layer))
        end
        [out, warnings]
      end

      def cripples(spec, lo, hi, t0, t1, z0, top_at, layer)
        out = []
        span = hi - lo
        count = [(span / spec.spacing).ceil, 1].max
        step = span / count
        (1...count).each do |index|
          position = lo + (index * step)
          z1 = top_at.call(position)
          next if z1 - z0 < spec.stud_width

          out << stud(spec, :cripple, position, t0, t1, z0, z1, layer)
        end
        out
      end

      def noggings(spec, positions, t0, t1, bottom, top, blocked, layer)
        rows = ((top - bottom) / spec.nogging_spacing).floor
        return [] if rows < 1

        out = []
        step_z = (top - bottom) / (rows + 1)
        positions.each_cons(2) do |left, right|
          s0 = left + (spec.stud_width / 2.0)
          s1 = right - (spec.stud_width / 2.0)
          next if s1 - s0 < 1.0
          next if blocked.any? { |lo, hi| s0 < hi && s1 > lo }

          rows.times do |row|
            z0 = bottom + ((row + 1) * step_z)
            out << Member.new(
              role: :nogging, section: section_name(spec, spec.stud_width),
              s0: s0, s1: s1, t0: t0, t1: t1,
              z0: z0, z1: z0 + spec.stud_width,
              material: layer.material || spec.material
            )
          end
        end
        out
      end

      # ---------------------------------------------------------------- mesh

      def mesh(result, record, stations)
        member_meshes(result, record, stations)
          .each_with_object(Mesh.new) { |(_member, member_mesh), out| out.merge(member_mesh) }
      end

      # One closed mesh per member. The SketchUp adapter turns these into
      # separately selectable, named groups and stamps each with its cut data.
      def member_meshes(result, record, stations)
        layer_near = layer_near_offset(record, result.layer)
        face_a = record.face_a_offset
        base = record.base_z
        result.members.filter_map do |member|
          # Opening planner warnings are strings, not members.
          next unless member.is_a?(Member)

          member_mesh = Mesh.new
          add_box(member_mesh, stations,
                  face_a - layer_near - member.t0,
                  face_a - layer_near - member.t1,
                  member, base)
          [member, member_mesh]
        end
      end

      def layer_near_offset(record, layer)
        record.type.layer_spans.each do |candidate, near, _far|
          return near if candidate.equal?(layer)
        end
        0.0
      end

      # A member as a six-sided box, following the wall rail between stations.
      # Its end faces are flat; long plates and noggings bend with curved walls.
      def add_box(mesh, stations, d0, d1, member, base)
        samples = sample_stations(stations, member)
        near = samples.map { |station| stations.point_on_rail(d0, station) }
        far = samples.map { |station| stations.point_on_rail(d1, station) }
        run = member.s1 - member.s0
        lo = samples.map do |station|
          fraction = run.abs < 1e-9 ? 0.0 : (station - member.s0) / run
          base + member.z0 + ((member.z0_end - member.z0) * fraction)
        end
        hi = samples.map do |station|
          fraction = run.abs < 1e-9 ? 0.0 : (station - member.s0) / run
          base + member.z1 + ((member.z1_end - member.z1) * fraction)
        end

        (0...samples.size - 1).each do |index|
          mesh.add_quad(p3(near[index], lo[index]), p3(near[index], hi[index]),
                        p3(near[index + 1], hi[index + 1]), p3(near[index + 1], lo[index + 1]),
                        tag: member.role, material: member.material, layer: member.label)
          mesh.add_quad(p3(far[index], lo[index]), p3(far[index + 1], lo[index + 1]),
                        p3(far[index + 1], hi[index + 1]), p3(far[index], hi[index]),
                        tag: member.role, material: member.material, layer: member.label)
          mesh.add_quad(p3(far[index], hi[index]), p3(far[index + 1], hi[index + 1]),
                        p3(near[index + 1], hi[index + 1]), p3(near[index], hi[index]),
                        tag: member.role, material: member.material, layer: member.label)
          mesh.add_quad(p3(near[index], lo[index]), p3(near[index + 1], lo[index + 1]),
                        p3(far[index + 1], lo[index + 1]), p3(far[index], lo[index]),
                        tag: member.role, material: member.material, layer: member.label)
        end
        mesh.add_quad(p3(far[0], lo[0]), p3(far[0], hi[0]), p3(near[0], hi[0]), p3(near[0], lo[0]),
                      tag: member.role, material: member.material, layer: member.label)
        last = samples.size - 1
        mesh.add_quad(p3(near[last], lo[last]), p3(near[last], hi[last]),
                      p3(far[last], hi[last]), p3(far[last], lo[last]),
                      tag: member.role, material: member.material, layer: member.label)
      end

      def sample_stations(stations, member)
        inner = stations.arc_lengths.select do |station|
          station > member.s0 + 1e-6 && station < member.s1 - 1e-6
        end
        [member.s0] + inner + [member.s1]
      end

      def p3(point, z)
        [point.x, point.y, z]
      end
    end
  end
end
