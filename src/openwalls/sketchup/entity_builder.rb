# frozen_string_literal: true

module OpenWalls
  module SketchUpAdapter
    # Mesh -> SketchUp entities. The entire translation layer between the
    # engine and the modeller is this file plus Attributes; everything else
    # about how a wall is shaped lives in OpenWalls::Core and runs without
    # SketchUp.
    module EntityBuilder
      MM_PER_INCH = 25.4

      module_function

      def point(xyz)
        Geom::Point3d.new(xyz[0] / MM_PER_INCH, xyz[1] / MM_PER_INCH, xyz[2] / MM_PER_INCH)
      end

      # Rebuilds the contents of +group+ from +result+.
      #
      # Each layer of the stack becomes its own nested group, so a cavity wall
      # gives you brick, insulation and block as separate, separately
      # selectable, separately materialled solids -- not one lump you have to
      # explode to work with.
      def populate(group, result, materials)
        group.entities.clear!
        group.name = result.record.name

        result.each_layer do |entry|
          layer = entry[:layer]
          mesh = entry[:mesh]
          next if mesh.empty?

          sub = group.entities.add_group
          sub.name = layer.name
          material = material_for(materials, layer.material)
          add_mesh(sub.entities, mesh, material)
          tag_layer(sub, layer)
        end

        group
      end

      def add_mesh(entities, mesh, material)
        mesh.faces.each do |face_record|
          points = face_record.indices.map { |i| point(mesh.vertices[i]) }
          next if points.size < 3

          face = begin
            entities.add_face(points)
          rescue StandardError
            # A face SketchUp refuses (duplicate points after rounding to its
            # internal tolerance) is not worth aborting a whole wall for.
            nil
          end
          next unless face

          orient(face, mesh, face_record)
          next unless material

          face.material = material
          face.back_material = material
        end
      end

      # The engine winds every polygon outward. SketchUp decides a face's
      # front side from the point order too, but normalises loops it merges
      # with existing geometry, so check and flip rather than assume.
      def orient(face, mesh, face_record)
        expected = polygon_normal(mesh, face_record.indices)
        return if expected.nil?

        actual = face.normal
        dot = (actual.x * expected[0]) + (actual.y * expected[1]) + (actual.z * expected[2])
        face.reverse! if dot.negative?
      end

      def polygon_normal(mesh, indices)
        v0 = mesh.vertices[indices[0]]
        nx = ny = nz = 0.0
        (1...indices.size - 1).each do |i|
          v1 = mesh.vertices[indices[i]]
          v2 = mesh.vertices[indices[i + 1]]
          ax = v1[0] - v0[0]
          ay = v1[1] - v0[1]
          az = v1[2] - v0[2]
          bx = v2[0] - v0[0]
          by = v2[1] - v0[1]
          bz = v2[2] - v0[2]
          nx += (ay * bz) - (az * by)
          ny += (az * bx) - (ax * bz)
          nz += (ax * by) - (ay * bx)
        end
        len = Math.sqrt((nx * nx) + (ny * ny) + (nz * nz))
        return nil if len < 1e-12

        [nx / len, ny / len, nz / len]
      end

      # Materials are resolved by *name* every rebuild rather than held as
      # object references, so a wall reopened in a model whose materials were
      # purged and re-imported still finds its brick.
      def material_for(materials, name)
        return nil if name.nil? || name.to_s.empty?

        existing = materials[name]
        return existing if existing

        material = materials.add(name)
        material.color = default_colour(name)
        material
      end

      DEFAULT_COLOURS = {
        'brick' => [150, 84, 68],
        'blockwork' => [176, 176, 170],
        'block' => [176, 176, 170],
        'concrete' => [160, 160, 158],
        'plaster' => [236, 232, 222],
        'plasterboard' => [238, 236, 230],
        'pir' => [226, 198, 120],
        'mineral wool' => [214, 206, 182],
        'osb' => [198, 166, 112],
        'timber cladding' => [150, 110, 70],
        'render' => [224, 222, 214]
      }.freeze

      def default_colour(name)
        key = name.to_s.downcase
        rgb = DEFAULT_COLOURS.find { |candidate, _| key.include?(candidate) }
        Sketchup::Color.new(*(rgb ? rgb[1] : [190, 190, 190]))
      end

      # Puts each layer on a SketchUp tag named after it, so you can switch
      # off every plasterboard layer in the model in one click.
      def tag_layer(group, layer)
        model = Sketchup.active_model
        name = "OpenWalls / #{layer.kind.to_s.capitalize}"
        tag = model.layers[name] || model.layers.add(name)
        group.layer = tag
      rescue StandardError
        nil
      end
    end
  end
end
