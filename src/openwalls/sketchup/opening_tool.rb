# frozen_string_literal: true

module OpenWalls
  module SketchUpAdapter
    # Places doors, windows, louvers and plain holes.
    #
    # Hover a wall and the opening slides along it, snapping to the wall's own
    # geometry: the centre of the wall, the centre of the bay between its
    # neighbours, and the edges of openings that are already there. Click to
    # drop it in. The wall rebuilds from its record, so the opening is part of
    # the wall from that moment -- not a hole subtracted from it.
    class OpeningTool
      MM_PER_INCH = 25.4
      SNAP_TOLERANCE = 150.0 # mm on screen-independent model distance

      DEFAULTS = {
        door: { width: 900.0, height: 2100.0, sill: 0.0, shape: :rect },
        window: { width: 1200.0, height: 1400.0, sill: 900.0, shape: :rect },
        louver: { width: 600.0, height: 600.0, sill: 1800.0, shape: :rect },
        opening: { width: 1000.0, height: 2100.0, sill: 0.0, shape: :rect }
      }.freeze

      def initialize(kind = :window, overrides = {})
        @kind = kind.to_sym
        @spec = DEFAULTS.fetch(@kind, DEFAULTS[:window]).merge(overrides)
        @target = nil
      end

      def activate
        @ip = Sketchup::InputPoint.new
        update_status
      end

      def deactivate(view)
        view.invalidate
      end

      def onMouseMove(_flags, x, y, view)
        @ip.pick(view, x, y)
        @target = @ip.valid? ? locate(plan_point(@ip.position)) : nil
        view.invalidate
      end

      def onLButtonDown(_flags, _x, _y, view)
        return unless @target

        place(@target)
        view.invalidate
      end

      def onCancel(_reason, _view)
        Sketchup.active_model.select_tool(nil)
      end

      def enableVCB?
        true
      end

      # Typing sets the width, or "width x height" sets both.
      def onUserText(text, view)
        parts = text.to_s.split(/[x*]/i)
        @spec = @spec.merge(width: Core::Units.parse(parts[0]))
        @spec = @spec.merge(height: Core::Units.parse(parts[1])) if parts[1]
        update_status
        view.invalidate
      rescue Core::Error => e
        UI.messagebox("OpenWalls: #{e.message}")
      end

      def draw(view)
        return unless @target

        outline = elevation_outline(@target)
        return if outline.size < 2

        view.line_width = 2
        view.drawing_color = Sketchup::Color.new(230, 120, 40)
        view.draw(GL_LINE_LOOP, outline)
      end

      def getExtents
        Sketchup.active_model.bounds
      end

      private

      # Finds the wall nearest the cursor and the station along it, applying
      # snaps.
      def locate(point)
        best = nil
        Attributes.all_walls(Sketchup.active_model).each do |group|
          record = Attributes.read(group)
          next unless record

          stations = Core::Stations.build(record.centerline_points)
          station, distance = stations.project(point)
          limit = (record.total_thickness / 2.0) + SNAP_TOLERANCE
          next if distance > limit
          next if best && distance >= best[:distance]

          best = { group: group, record: record, station: station, distance: distance }
        end
        return nil unless best

        best[:station] = snap(best[:record], best[:station])
        best
      end

      # Snap candidates, nearest wins: the middle of the wall, and a clear
      # margin from each existing opening.
      def snap(record, station)
        candidates = [record.length / 2.0]
        record.openings.each do |op|
          candidates << op.start_station - (@spec[:width] / 2.0)
          candidates << op.end_station + (@spec[:width] / 2.0)
        end
        best = candidates.min_by { |c| (c - station).abs }
        return best if best && (best - station).abs < SNAP_TOLERANCE

        station
      end

      def place(target)
        record = target[:record]
        opening = Core::OpeningRecord.new(
          id: Library.next_id(@kind.to_s[0]),
          kind: @kind,
          station: target[:station],
          width: @spec[:width],
          height: @spec[:height],
          sill: @spec[:sill],
          shape: @spec[:shape],
          rise: @spec[:rise]
        )

        updated = Core::WallRecord.from_h(
          record.to_h.merge('openings' => record.openings.map(&:to_h) + [opening.to_h])
        )
        warnings = updated.warnings
        unless warnings.empty?
          return unless UI.messagebox("#{warnings.join("\n")}\n\nPlace it anyway?", MB_YESNO) == IDYES
        end

        model = Sketchup.active_model
        model.start_operation("Place #{@kind}", true)
        Attributes.write(target[:group], updated)
        ModelBuilder.rebuild_chain(model, [target[:group]])
        model.commit_operation
      rescue Core::Error => e
        Sketchup.active_model.abort_operation
        UI.messagebox("OpenWalls could not place that opening:\n\n#{e.message}")
      end

      # Preview rectangle drawn on the face of the host wall.
      def elevation_outline(target)
        record = target[:record]
        stations = Core::Stations.build(record.centerline_points)
        half = @spec[:width] / 2.0
        s0 = target[:station] - half
        s1 = target[:station] + half
        rail_distance = record.face_a_offset

        points = []
        [[s0, @spec[:sill]], [s1, @spec[:sill]],
         [s1, @spec[:sill] + @spec[:height]], [s0, @spec[:sill] + @spec[:height]]].each do |(s, z)|
          plan = point_at(stations, rail_distance, s)
          next unless plan

          points << Geom::Point3d.new(plan.x / MM_PER_INCH, plan.y / MM_PER_INCH,
                                      (record.base_z + z) / MM_PER_INCH)
        end
        points
      rescue Core::Error
        []
      end

      def point_at(stations, rail_distance, arc_length)
        rail = stations.rail(rail_distance)
        arcs = stations.arc_lengths
        return rail.first if arc_length <= arcs.first
        return rail.last if arc_length >= arcs.last

        index = arcs.each_index.find { |i| arcs[i + 1] && arcs[i + 1] >= arc_length }
        return rail.last unless index

        span = arcs[index + 1] - arcs[index]
        t = span < 1e-9 ? 0.0 : (arc_length - arcs[index]) / span
        rail[index].lerp(rail[index + 1], t)
      end

      def plan_point(position)
        Core::Vec2.new(position.x * MM_PER_INCH, position.y * MM_PER_INCH)
      end

      def update_status
        Sketchup.status_text = format(
          'OpenWalls -- place %s %d x %d mm, sill %d. Hover a wall, click to place. Type "1200x2100" to resize.',
          @kind, @spec[:width], @spec[:height], @spec[:sill]
        )
        Sketchup.vcb_label = 'Width x Height'
      end
    end
  end
end
