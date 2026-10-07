# frozen_string_literal: true

module OpenWalls
  module SketchUpAdapter
    # Persistence. A wall is a SketchUp group carrying its WallRecord as JSON
    # in an attribute dictionary.
    #
    # One attribute holding a versioned JSON document, rather than thirty
    # typed attributes, because:
    #   * it round-trips exactly, including nested openings and arc metadata
    #   * it is one schema number to check, not thirty optional reads
    #   * it can be diffed, logged, pasted into an issue and replayed in a
    #     terminal with no modeller running -- which is how the engine gets
    #     debugged
    #
    # Nothing here is stored outside the .skp. There is no cloud, no account
    # and no central library: the model file is the database.
    module Attributes
      DICTIONARY = 'OpenWalls'
      RECORD_KEY = 'record'
      SCHEMA_KEY = 'schema'
      KIND_KEY   = 'kind'

      module_function

      def wall?(entity)
        entity.is_a?(Sketchup::Group) && !entity.get_attribute(DICTIONARY, RECORD_KEY).nil?
      end

      def write(entity, record)
        entity.set_attribute(DICTIONARY, KIND_KEY, 'wall')
        entity.set_attribute(DICTIONARY, SCHEMA_KEY, Core::WallRecord::SCHEMA_VERSION)
        entity.set_attribute(DICTIONARY, RECORD_KEY, record.to_json)
        record
      end

      # Returns nil rather than raising when the group is not ours, so callers
      # can filter a mixed selection without rescuing.
      def read(entity)
        return nil unless wall?(entity)

        Core::WallRecord.from_json(entity.get_attribute(DICTIONARY, RECORD_KEY))
      rescue Core::UnsupportedSchema => e
        warn_once("#{entity.name}: #{e.message}")
        nil
      rescue StandardError => e
        warn_once("#{entity.name}: unreadable wall record (#{e.message})")
        nil
      end

      def walls(entities)
        entities.grep(Sketchup::Group).select { |group| wall?(group) }
      end

      def all_walls(model = Sketchup.active_model)
        walls(model.active_entities)
      end

      def records(groups)
        groups.map { |group| read(group) }.compact
      end

      def warn_once(message)
        @warned ||= {}
        return if @warned[message]

        @warned[message] = true
        puts "[OpenWalls] #{message}"
      end
    end
  end
end
