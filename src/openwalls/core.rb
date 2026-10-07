# frozen_string_literal: true

require_relative 'core/errors'
require_relative 'core/units'
require_relative 'core/vec2'
require_relative 'core/path'
require_relative 'core/offset'
require_relative 'core/stations'
require_relative 'core/mesh'
require_relative 'core/wall_type'
require_relative 'core/opening_record'
require_relative 'core/wall_record'
require_relative 'core/wall_builder'
require_relative 'core/chain'
require_relative 'core/takeoff'

module OpenWalls
  # The geometry engine.
  #
  # Everything under Core is plain Ruby with no dependency on SketchUp, on a
  # gem, or on anything being installed. You can run it, test it and debug it
  # in a terminal. The SketchUp-specific code lives in OpenWalls::SketchUpAdapter
  # and is a thin translation layer on top of this.
  #
  # That split is not tidiness for its own sake: it is what makes the hard
  # parts (mitering, arcs, openings, takeoff) testable at all, and it is why
  # this engine can drive a Three.js preview and an OBJ export without
  # SketchUp being involved.
  module Core
    # Builds every wall in a set, auto-mitering wherever walls form a run.
    # This is the entry point the adapter and the CLI both call.
    def self.build_all(records)
      records = Array(records)
      return [] if records.empty?

      stations = Chain.solve(records)
      records.map { |record| WallBuilder.new(record, stations: stations[record.id]).build }
    end

    # Convenience for the common case of a single, unchained wall.
    def self.build(record)
      WallBuilder.build(record)
    end
  end
end
