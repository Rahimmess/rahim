# frozen_string_literal: true

module OpenWalls
  module SketchUpAdapter
    # The drawing tool.
    #
    # Click to start, click for each corner, Enter or Escape to finish. Press
    # A to make the next segment an arc and click its bulge point. Type a
    # length and hit Enter to place the next corner exactly.
    #
    # Each segment becomes its own wall record sharing a chain id, which is
    # what makes the corners auto-miter: the engine recognises the run and
    # offsets it as one continuous centreline. You still get one selectable,
    # separately editable wall per segment.
    class WallTool
      MM_PER_INCH = 25.4

      def initialize
        @points = []
        @segments = []
        @arc_stage = nil # nil | :end | :bulge
        @arc_end = nil
      end

      # -- Tool protocol ----------------------------------------------------

      def activate
        @ip = Sketchup::InputPoint.new
        @ip_previous = Sketchup::InputPoint.new
        reset_path
        update_status
      end

      def deactivate(view)
        view.invalidate
      end

      def resume(view)
        update_status
        view.invalidate
      end

      def suspend(view)
        view.invalidate
      end

      def onMouseMove(_flags, x, y, view)
        @ip.pick(view, x, y, @ip_previous)
        view.tooltip = @ip.tooltip if @ip.valid?
        view.invalidate
      end

      def onLButtonDown(_flags, _x, _y, view)
        return unless @ip.valid?

        point = plan_point(@ip.position)

        case @arc_stage
        when :end
          @arc_end = point
          @arc_stage = :bulge
        when :bulge
          commit_arc(point)
        else
          @points << point
          @segments << Core::Path::Line.new(@points[-2], @points[-1]) if @points.size > 1
        end

        @ip_previous.copy!(@ip)
        update_status
        view.invalidate
      end

      def onLButtonDoubleClick(_flags, _x, _y, view)
        finish(view)
      end

      def onReturn(view)
        finish(view)
      end

      def onCancel(_reason, view)
        if @points.size > 1
          finish(view)
        else
          reset_path
          view.invalidate
        end
      end

      def onKeyDown(key, _repeat, _flags, view)
        # 'A' arms arc mode: next click sets where the arc ends, the one
        # after sets how far it bulges.
        if (key == 65 || key == 97) && @points.any?
          @arc_stage = @arc_stage.nil? ? :end : nil
          @arc_end = nil
          update_status
          view.invalidate
          return true
        end
        false
      end

      def enableVCB?
        true
      end

      # Typing a length places the next corner along the current direction.
      def onUserText(text, view)
        return if @points.empty?

        length = Core::Units.parse(text)
        direction = current_direction
        return unless direction

        @points << @points.last + (direction * length)
        @segments << Core::Path::Line.new(@points[-2], @points[-1])
        update_status
        view.invalidate
      rescue Core::Error => e
        UI.messagebox("OpenWalls: #{e.message}")
      end

      def getExtents
        bounds = Geom::BoundingBox.new
        bounds.add(Sketchup.active_model.bounds)
        @points.each { |p| bounds.add(to_su(p, 0.0)) }
        bounds
      end

      # -- Preview ----------------------------------------------------------

      def draw(view)
        preview_segments = @segments + [rubber_band].compact
        return if preview_segments.empty?

        draw_rails(view, preview_segments)
        draw_centerline(view, preview_segments)
        @ip.draw(view) if @ip.valid?
      end

      private

      def draw_centerline(view, segments)
        points = Core::Path.tessellate(segments, 2.0).map { |p| to_su(p, base_z) }
        return if points.size < 2

        view.line_width = 1
        view.line_stipple = '-'
        view.drawing_color = Sketchup::Color.new(120, 120, 120)
        view.draw(GL_LINE_STRIP, points)
      rescue Core::Error
        nil
      end

      # Shows the real thickness of the selected wall type while drawing,
      # mitered exactly as it will be built -- the preview is produced by the
      # same offsetting code as the final geometry, not an approximation of it.
      def draw_rails(view, segments)
        record = preview_record(segments)
        return unless record

        stations = Core::Stations.build(record.centerline_points)
        offset = record.face_a_offset
        [offset, offset - record.total_thickness].each do |distance|
          rail = stations.rail(distance).map { |p| to_su(p, base_z) }
          next if rail.size < 2

          view.line_width = 2
          view.line_stipple = ''
          view.drawing_color = Sketchup::Color.new(40, 110, 200)
          view.draw(GL_LINE_STRIP, rail)
        end
      rescue Core::Error
        nil
      end

      def preview_record(segments)
        Library.record_for('preview', segments)
      rescue Core::Error
        nil
      end

      def rubber_band
        return nil unless @ip.valid? && @points.any?

        target = plan_point(@ip.position)
        return nil if target.distance_to(@points.last) < 1.0

        if @arc_stage == :bulge && @arc_end
          # Arc.through degrades to a straight line when the three points are
          # collinear, so dragging the bulge back through the chord simply
          # flattens the preview instead of blowing up.
          Core::Path::Arc.through(@points.last, target, @arc_end)
        else
          Core::Path::Line.new(@points.last, target)
        end
      rescue Core::Error
        nil
      end

      def commit_arc(bulge)
        start = @points.last
        segment = begin
          Core::Path::Arc.through(start, bulge, @arc_end)
        rescue Core::Error
          Core::Path::Line.new(start, @arc_end)
        end
        @points << @arc_end
        @segments << segment
        @arc_stage = nil
        @arc_end = nil
      end

      def current_direction
        return nil if @points.size < 2 && !@ip.valid?

        from = @points.last
        to = @ip.valid? ? plan_point(@ip.position) : nil
        return (to - from).normalize if to && to.distance_to(from) > 1e-6
        return nil if @points.size < 2

        (@points[-1] - @points[-2]).normalize
      rescue Core::Error
        nil
      end

      def finish(view)
        build if @segments.any?
        reset_path
        view.invalidate
        update_status
      end

      def build
        model = Sketchup.active_model
        model.start_operation('Draw walls', true)
        chain_id = Library.next_id('chain')
        groups = @segments.map do |segment|
          record = Library.record_for(Library.next_id, [segment], chain_id: chain_id)
          group = model.active_entities.add_group
          Attributes.write(group, record)
          group
        end
        ModelBuilder.rebuild_chain(model, groups)
        model.commit_operation
        model.selection.clear
        model.selection.add(groups)
      rescue Core::Error => e
        model.abort_operation
        UI.messagebox("OpenWalls could not build that wall:\n\n#{e.message}")
      end

      def reset_path
        @points = []
        @segments = []
        @arc_stage = nil
        @arc_end = nil
      end

      def base_z
        Library.defaults['base_z'].to_f
      end

      def plan_point(position)
        Core::Vec2.new(position.x * MM_PER_INCH, position.y * MM_PER_INCH)
      end

      def to_su(vec, z)
        Geom::Point3d.new(vec.x / MM_PER_INCH, vec.y / MM_PER_INCH, z / MM_PER_INCH)
      end

      def update_status
        type = Library.type(Library.defaults['type_id'])
        hint =
          if @points.empty?
            'Click to start a wall run.'
          elsif @arc_stage == :end
            'Click where the arc should end. A = back to straight.'
          elsif @arc_stage == :bulge
            'Click how far the arc bulges.'
          else
            'Click the next corner. A = arc, Enter = finish, Esc = cancel.'
          end
        Sketchup.status_text = "OpenWalls -- #{type.name} (#{type.total_thickness.round} mm). #{hint}"
        Sketchup.vcb_label = 'Length'
      end
    end
  end
end
