# frozen_string_literal: true

module OpenWalls
  module SketchUpAdapter
    # Creating and rebuilding walls inside a model.
    #
    # Rebuilding is always "throw the geometry away and regenerate it from the
    # record". There is no incremental patching of faces, because incremental
    # patching is where every parametric modeller eventually goes wrong: the
    # geometry and the data drift apart and nobody can say which is right.
    # Here the record is always right.
    module ModelBuilder
      MM_PER_INCH = 25.4

      module_function

      # Creates a new wall group and draws it.
      def create(model, record)
        group = model.active_entities.add_group
        Attributes.write(group, record)
        rebuild_chain(model, [group])
        group
      end

      # Rebuilds the given wall groups *and* every wall chained to them, so a
      # corner cannot be left half-mitered after one of its two walls changes.
      def rebuild_chain(model, groups)
        groups = Array(groups).select { |g| g.valid? && Attributes.wall?(g) }
        return [] if groups.empty?

        all_groups = Attributes.all_walls(model)
        by_id = {}
        records = []
        all_groups.each do |group|
          # Fold any native Move/Rotate back into the record first, so the
          # rebuild does not teleport a wall the user just dragged.
          absorb_transformation(group)
          record = Attributes.read(group)
          next unless record

          by_id[record.id] = group
          records << record
        end
        return [] if records.empty?

        wanted = groups.map { |g| Attributes.read(g) }.compact.map(&:id)
        affected = expand_to_chains(records, wanted)

        results = Core.build_all(records)
        materials = model.materials
        touched = []

        results.each do |result|
          next unless affected.include?(result.record.id)

          group = by_id[result.record.id]
          next unless group&.valid?

          EntityBuilder.populate(group, result, materials)
          touched << group
        end
        touched
      end

      def rebuild_all(model = Sketchup.active_model)
        groups = Attributes.all_walls(model)
        return [] if groups.empty?

        model.start_operation('Rebuild OpenWalls', true)
        touched = rebuild_chain(model, groups)
        model.commit_operation
        touched
      end

      # Grows a set of wall ids to include everything sharing a chain with
      # them.
      def expand_to_chains(records, ids)
        wanted = {}
        Core::Chain.group(records).each do |run|
          run_ids = run.records.map(&:id)
          wanted.merge!(run_ids.each_with_object({}) { |i, h| h[i] = true }) if run_ids.any? { |i| ids.include?(i) }
        end
        ids.each { |i| wanted[i] = true }
        wanted.keys
      end

      # If the user moved or rotated a wall with SketchUp's own tools, fold
      # that transform back into the record and reset the group to identity.
      #
      # Without this, the native Move tool silently breaks the parametric
      # link: the geometry is somewhere new but the record still describes
      # where it used to be, so the next rebuild teleports it back. With it,
      # Move and Rotate just work on parametric walls.
      def absorb_transformation(group)
        record = Attributes.read(group)
        return nil unless record

        transform = group.transformation
        return record if identity?(transform)
        return nil unless rigid_in_plan?(transform)

        angle = Math.atan2(transform.xaxis.y, transform.xaxis.x)
        dx = transform.origin.x * MM_PER_INCH
        dy = transform.origin.y * MM_PER_INCH
        dz = transform.origin.z * MM_PER_INCH

        moved = record.to_h
        moved['segments'] = record.segments.map { |segment| transform_segment(segment, angle, dx, dy) }
        moved['base_z'] = record.base_z + dz
        updated = Core::WallRecord.from_h(moved)

        group.transformation = Geom::Transformation.new
        Attributes.write(group, updated)
        updated
      end

      def transform_segment(segment, angle, dx, dy)
        hash = segment.to_h
        %w[a b center].each do |key|
          next unless hash[key]

          x, y = hash[key]
          hash[key] = [
            (x * Math.cos(angle)) - (y * Math.sin(angle)) + dx,
            (x * Math.sin(angle)) + (y * Math.cos(angle)) + dy
          ]
        end
        hash
      end

      def identity?(transform)
        transform.to_a.each_with_index.all? do |value, i|
          (value - Geom::Transformation.new.to_a[i]).abs < 1e-9
        end
      end

      # Rotation about Z plus translation, no scaling, no mirroring. Anything
      # else (a scaled or flipped wall) we leave alone rather than silently
      # producing a wall whose record no longer matches its geometry.
      def rigid_in_plan?(transform)
        x = transform.xaxis
        y = transform.yaxis
        z = transform.zaxis
        return false if (x.length - 1.0).abs > 1e-6 || (y.length - 1.0).abs > 1e-6 || (z.length - 1.0).abs > 1e-6
        return false if z.z < 0.999

        x.cross(y).z > 0.999
      end

      # Collects every wall record in the model, for takeoff and reporting.
      def all_results(model = Sketchup.active_model)
        records = Attributes.records(Attributes.all_walls(model))
        Core.build_all(records)
      end
    end
  end
end
