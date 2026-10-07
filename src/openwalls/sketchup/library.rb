# frozen_string_literal: true

module OpenWalls
  module SketchUpAdapter
    # The wall type library and the current drawing defaults.
    #
    # Both live inside the .skp file. Not in a preferences folder, not on a
    # server, not behind an account. Send someone the model and they get your
    # wall types with it; archive the model and the library is archived too.
    # The only thing stored in SketchUp's own preferences is which type you
    # had selected last, because that is a habit, not project data.
    module Library
      DICTIONARY = 'OpenWalls:library'
      TYPES_KEY  = 'wall_types'
      DEFAULTS_KEY = 'defaults'
      PREF_SECTION = 'OpenWalls'

      DEFAULTS = {
        'type_id' => 'cavity-300',
        'height' => 2700.0,
        'base_z' => 0.0,
        'justification' => 'center',
        'tolerance' => Core::Path::DEFAULT_TOLERANCE
      }.freeze

      module_function

      def model
        Sketchup.active_model
      end

      # Every type available for drawing: the built-in presets plus whatever
      # this model has saved. Model types win on id collision, so a project
      # can override a preset without renaming it.
      def types
        stored = read_types
        by_id = {}
        Core::WallType.presets.each { |t| by_id[t.id] = t }
        stored.each { |t| by_id[t.id] = t }
        by_id.values
      end

      def type(id)
        types.find { |t| t.id == id } || types.first
      end

      def read_types
        raw = model.get_attribute(DICTIONARY, TYPES_KEY)
        return [] if raw.nil? || raw.empty?

        JSON.parse(raw).map { |hash| Core::WallType.from_h(hash) }
      rescue StandardError => e
        Attributes.warn_once("wall type library could not be read (#{e.message})")
        []
      end

      def save_type(wall_type)
        stored = read_types.reject { |t| t.id == wall_type.id }
        stored << wall_type
        model.set_attribute(DICTIONARY, TYPES_KEY, JSON.generate(stored.map(&:to_h)))
        wall_type
      end

      def delete_type(id)
        stored = read_types.reject { |t| t.id == id }
        model.set_attribute(DICTIONARY, TYPES_KEY, JSON.generate(stored.map(&:to_h)))
      end

      def defaults
        raw = model.get_attribute(DICTIONARY, DEFAULTS_KEY)
        stored = raw ? JSON.parse(raw) : {}
        DEFAULTS.merge(stored)
      rescue StandardError
        DEFAULTS.dup
      end

      def update_defaults(changes)
        merged = defaults.merge(stringify(changes))
        model.set_attribute(DICTIONARY, DEFAULTS_KEY, JSON.generate(merged))
        Sketchup.write_default(PREF_SECTION, 'last_type_id', merged['type_id'].to_s)
        merged
      end

      def last_type_id
        Sketchup.read_default(PREF_SECTION, 'last_type_id', DEFAULTS['type_id'])
      end

      def stringify(hash)
        hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
      end

      # A record built from the current defaults, ready for the drawing tool
      # to drop a path into.
      def record_for(id, segments, chain_id: nil, overrides: {})
        settings = defaults.merge(stringify(overrides))
        Core::WallRecord.new(
          id: id,
          chain_id: chain_id,
          segments: segments,
          type: type(settings['type_id']),
          justification: settings['justification'].to_sym,
          base_z: settings['base_z'].to_f,
          height: settings['height'].to_f,
          tolerance: settings['tolerance'].to_f
        )
      end

      def next_id(prefix = 'w')
        @counter ||= 0
        @counter += 1
        format('%s%d-%s', prefix, @counter, (Time.now.to_f * 1000).to_i.to_s(36))
      end
    end
  end
end
