# frozen_string_literal: true

module OpenWalls
  module Core
    # Base class for every error the geometry core raises. The SketchUp adapter
    # catches this and turns it into a dialog instead of a red Ruby console.
    class Error < StandardError; end

    # The inputs describe something that cannot exist: a zero-length wall, a
    # zero-radius arc, a negative thickness.
    class DegenerateGeometry < Error; end

    # The record is structurally wrong: unknown layer kind, opening wider than
    # its host wall, missing required field.
    class InvalidRecord < Error; end

    # A stored record came from a schema version this build cannot read.
    class UnsupportedSchema < Error; end
  end
end
