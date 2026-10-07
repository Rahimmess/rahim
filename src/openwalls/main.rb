# frozen_string_literal: true

# Loaded by SketchUp once the extension is enabled.
#
# The load order below is the architecture in one glance: the engine first,
# with no knowledge that SketchUp exists, then a thin adapter on top of it.

require 'json'

require_relative 'version'
require_relative 'core'

module OpenWalls
  # Everything that touches the SketchUp API lives in here and nowhere else.
  module SketchUpAdapter
  end
end

require_relative 'sketchup/attributes'
require_relative 'sketchup/entity_builder'
require_relative 'sketchup/library'
require_relative 'sketchup/model_builder'
require_relative 'sketchup/wall_tool'
require_relative 'sketchup/opening_tool'
require_relative 'sketchup/dialog'
require_relative 'sketchup/commands'
require_relative 'sketchup/observers'

module OpenWalls
  def self.boot
    if Sketchup.version.to_i < MINIMUM_SKETCHUP
      UI.messagebox("OpenWalls needs SketchUp #{2000 + MINIMUM_SKETCHUP} or newer.")
      return false
    end

    SketchUpAdapter::Commands.install
    SketchUpAdapter::Observers.install
    true
  end

  boot
end
