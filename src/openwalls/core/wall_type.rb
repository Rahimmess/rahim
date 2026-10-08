# frozen_string_literal: true

require_relative 'errors'

module OpenWalls
  module Core
    # A wall is a *layer stack*, full stop.
    #
    # This is the one design decision the whole engine hangs off. Most wall
    # tools model "a single wall", then bolt on "a double wall" as a second
    # mode, then bolt on "finishes" as a third concept that behaves like
    # neither. Real construction has no such distinction: a wall is an ordered
    # set of material layers across its thickness, which is also exactly how
    # IFC models it (IfcMaterialLayerSet).
    #
    # So OpenWalls has one concept. A 110 mm partition is a one-layer stack. A
    # brick-and-block cavity wall is five layers. Adding insulation is adding a
    # layer, not switching mode. Every downstream feature -- geometry,
    # openings, takeoff, materials, IFC export -- reads the same structure.
    class Layer
      KINDS = %i[structure masonry insulation cavity membrane finish cladding sheathing].freeze

      # A cavity carries no geometry but still occupies thickness. Membranes
      # are too thin to model as a solid and are counted by area instead.
      NON_SOLID = %i[cavity membrane].freeze

      attr_reader :name, :kind, :thickness, :material, :structural, :framing

      # +framing+ names a Framing standard. A framed layer is studs and plates
      # with air between them, not a solid slab; it is measured by its members
      # and generated separately from the surrounding layer geometry.
      def initialize(name:, thickness:, kind: :structure, material: nil, structural: nil, framing: nil)
        @name = name.to_s
        @kind = kind.to_sym
        @thickness = thickness.to_f
        @material = material
        @framing = framing && !framing.to_s.empty? ? framing.to_s : nil
        @structural = structural.nil? ? %i[structure masonry].include?(@kind) : !!structural

        raise InvalidRecord, "unknown layer kind #{@kind.inspect}" unless KINDS.include?(@kind)
        raise InvalidRecord, "layer #{@name.inspect} has non-positive thickness" if @thickness <= 0
      end

      def framed?
        !@framing.nil?
      end

      def solid?
        !NON_SOLID.include?(@kind) && !framed?
      end

      def cavity?
        @kind == :cavity
      end

      # Membranes are counted by area, framed layers by piece, solids by volume.
      def measure
        return :pieces if framed?

        @kind == :membrane ? :area : :volume
      end

      def to_h
        {
          'name' => @name, 'kind' => @kind.to_s, 'thickness' => @thickness,
          'material' => @material, 'structural' => @structural, 'framing' => @framing
        }
      end

      def self.from_h(hash)
        new(
          name: hash['name'],
          thickness: hash['thickness'],
          kind: (hash['kind'] || 'structure').to_sym,
          material: hash['material'],
          structural: hash['structural'],
          framing: hash['framing']
        )
      end
    end

    # A named, reusable stack. Stored in the model file, not on a server.
    class WallType
      attr_reader :id, :name, :layers, :description

      def initialize(id:, name:, layers:, description: nil)
        @id = id.to_s
        @name = name.to_s
        @layers = layers
        @description = description
        raise InvalidRecord, "wall type #{@name.inspect} has no layers" if layers.nil? || layers.empty?
      end

      def total_thickness
        @layers.sum(&:thickness)
      end

      def solid_layers
        @layers.select(&:solid?)
      end

      # Distance of each layer's two boundaries measured from face A, as
      # [layer, near, far] with near < far. Face A is the first layer's outer
      # surface -- by convention the exterior.
      def layer_spans
        acc = 0.0
        @layers.map do |layer|
          span = [layer, acc, acc + layer.thickness]
          acc += layer.thickness
          span
        end
      end

      # A signature that is equal for two types whose boundaries can be
      # mitered into each other. Chains only auto-miter across walls with the
      # same signature; anything else gets a clean butt joint instead of a
      # guess.
      def miter_signature
        @layers.map { |l| l.thickness.round(4) }
      end

      def to_h
        { 'id' => @id, 'name' => @name, 'description' => @description, 'layers' => @layers.map(&:to_h) }
      end

      def self.from_h(hash)
        new(
          id: hash['id'], name: hash['name'], description: hash['description'],
          layers: (hash['layers'] || []).map { |l| Layer.from_h(l) }
        )
      end

      # Built-in starting points. Users override and save their own into the
      # model; these just mean the plugin is useful the second it loads.
      def self.presets
        @presets ||= [
          new(id: 'partition-100', name: 'Blockwork partition 100', description: 'Single leaf, plastered both sides',
              layers: [
                Layer.new(name: 'Plaster', kind: :finish, thickness: 13, material: 'Plaster'),
                Layer.new(name: 'Block 100', kind: :masonry, thickness: 100, material: 'Blockwork'),
                Layer.new(name: 'Plaster', kind: :finish, thickness: 13, material: 'Plaster')
              ]),
          new(id: 'cavity-300', name: 'Masonry cavity wall 300', description: 'Brick / cavity / block, plastered',
              layers: [
                Layer.new(name: 'Facing brick', kind: :masonry, thickness: 102.5, material: 'Brick'),
                Layer.new(name: 'Cavity', kind: :cavity, thickness: 50, material: nil),
                Layer.new(name: 'Insulation', kind: :insulation, thickness: 100, material: 'PIR'),
                Layer.new(name: 'Block 100', kind: :masonry, thickness: 100, material: 'Blockwork'),
                Layer.new(name: 'Plaster', kind: :finish, thickness: 13, material: 'Plaster')
              ]),
          new(id: 'stud-140', name: 'Timber stud 140', description: 'Sheathed stud wall, boarded both sides',
              layers: [
                Layer.new(name: 'Cladding', kind: :cladding, thickness: 19, material: 'Timber cladding'),
                Layer.new(name: 'Cavity', kind: :cavity, thickness: 25, material: nil),
                Layer.new(name: 'Sheathing', kind: :sheathing, thickness: 11, material: 'OSB'),
                Layer.new(name: 'Stud zone 140', kind: :insulation, thickness: 140, material: 'Mineral wool'),
                Layer.new(name: 'Vapour barrier', kind: :membrane, thickness: 0.5, material: 'VCL'),
                Layer.new(name: 'Plasterboard', kind: :finish, thickness: 12.5, material: 'Plasterboard')
              ]),
          new(id: 'concrete-200', name: 'Concrete wall 200', description: 'Fair-faced reinforced concrete',
              layers: [Layer.new(name: 'Concrete', kind: :structure, thickness: 200, material: 'Concrete C30/37')]),
          new(id: 'timber-frame-140', name: 'Timber frame 140 (UK)',
              description: 'Studs at 600 mm, sheathed, clad and boarded',
              layers: [
                Layer.new(name: 'Cladding', kind: :cladding, thickness: 19, material: 'Timber cladding'),
                Layer.new(name: 'Cavity', kind: :cavity, thickness: 25),
                Layer.new(name: 'Sheathing', kind: :sheathing, thickness: 11, material: 'OSB'),
                Layer.new(name: 'Stud zone 140', kind: :structure, thickness: 140,
                          material: 'Softwood C16', framing: 'uk-38x140-600'),
                Layer.new(name: 'Vapour barrier', kind: :membrane, thickness: 0.5, material: 'VCL'),
                Layer.new(name: 'Plasterboard', kind: :finish, thickness: 12.5, material: 'Plasterboard')
              ]),
          new(id: 'timber-frame-2x6', name: 'Timber frame 2x6 (US)',
              description: 'Studs at 16 in o.c., sheathed and boarded',
              layers: [
                Layer.new(name: 'Sheathing', kind: :sheathing, thickness: 11.1, material: 'OSB'),
                Layer.new(name: 'Stud zone 2x6', kind: :structure, thickness: 139.7,
                          material: 'SPF No.2', framing: 'us-2x6-16'),
                Layer.new(name: 'Vapour barrier', kind: :membrane, thickness: 0.5, material: 'VCL'),
                Layer.new(name: 'Gypsum board', kind: :finish, thickness: 12.7, material: 'Plasterboard')
              ]),
          new(id: 'metal-stud-100', name: 'Metal stud 100 (DIN)',
              description: 'CW100 in UW100 at 625 mm, two boards per face',
              layers: [
                Layer.new(name: 'Board outer', kind: :finish, thickness: 12.5, material: 'Plasterboard'),
                Layer.new(name: 'Board inner', kind: :finish, thickness: 12.5, material: 'Plasterboard'),
                Layer.new(name: 'CW100 zone', kind: :structure, thickness: 100,
                          material: 'Galvanised steel', framing: 'din-cw100-625'),
                Layer.new(name: 'Board inner', kind: :finish, thickness: 12.5, material: 'Plasterboard'),
                Layer.new(name: 'Board outer', kind: :finish, thickness: 12.5, material: 'Plasterboard')
              ])
        ]
      end

      def self.preset(id)
        presets.find { |t| t.id == id } || presets.first
      end
    end
  end
end
