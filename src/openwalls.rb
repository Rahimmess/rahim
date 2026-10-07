# frozen_string_literal: true

# OpenWalls -- parametric wall design for SketchUp.
#
# This file is the extension registrar. SketchUp loads it at startup; it does
# nothing except describe the extension and point at openwalls/main.rb, which
# is only evaluated once the user has the extension enabled.
#
# Copyright (c) 2026 OpenWalls contributors. MIT licensed.

require 'sketchup.rb'
require 'extensions.rb'

module OpenWalls
  PLUGIN_ROOT = File.dirname(__FILE__)
  PLUGIN_DIR  = File.join(PLUGIN_ROOT, 'openwalls')

  unless defined?(@extension_registered)
    loader = File.join(PLUGIN_DIR, 'main')

    @extension = SketchupExtension.new('OpenWalls', loader)
    @extension.version     = File.read(File.join(PLUGIN_DIR, 'VERSION')).strip
    @extension.creator     = 'OpenWalls contributors'
    @extension.copyright   = "2026 OpenWalls contributors, MIT licensed"
    @extension.description =
      'Parametric walls for SketchUp. A wall is a layer stack with a path: ' \
      'single, cavity or any assembly you like, straight or curved, with ' \
      'self-healing openings, auto-mitered corners and one-click quantity ' \
      'takeoff. Open source, no licence server, works offline.'

    Sketchup.register_extension(@extension, true)
    @extension_registered = true
  end

  def self.extension
    @extension
  end
end
