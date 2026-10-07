# frozen_string_literal: true

module OpenWalls
  VERSION = File.read(File.join(File.dirname(__FILE__), 'VERSION')).strip

  # Oldest SketchUp this extension supports. SketchUp 2021 ships Ruby 2.7, so
  # the whole codebase stays inside 2.7 syntax -- no endless methods, no hash
  # shorthand, no Data.define. Supporting four more years of SketchUp than the
  # commercial alternatives costs nothing but discipline.
  MINIMUM_SKETCHUP = 21
end
