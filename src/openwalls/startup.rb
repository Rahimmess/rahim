# frozen_string_literal: true

module OpenWalls
  # Startup helpers are deliberately separate from the adapter so the boot
  # path can be exercised with a tiny fake SketchUp API in the test suite.
  module Startup
    module_function

    # SketchUp reports versions as strings such as "21.1.332". Reading only
    # the major component avoids relying on String#to_i's permissive parsing.
    def major_version(version)
      match = version.to_s.match(/\A\s*(\d+)/)
      match ? match[1].to_i : 0
    end

    def report_error(error)
      message = "OpenWalls could not start.\n\n#{error.class}: #{error.message}"
      warn("[OpenWalls] #{message.gsub("\n", ' ')}")
      return unless defined?(UI) && UI.respond_to?(:messagebox)

      UI.messagebox(message)
    rescue StandardError => dialog_error
      warn("[OpenWalls] startup error dialog failed: #{dialog_error.message}")
      nil
    end
  end

  # Installs menus, toolbar and observers. Safe to call repeatedly (SketchUp
  # can reload extension files during development); the boot flag is set only
  # after every installation step succeeds, so a partial failure can be
  # retried instead of leaving the extension half-registered.
  def self.boot
    return true if @booted

    reported_version = Sketchup.version
    major = Startup.major_version(reported_version)
    if major < MINIMUM_SKETCHUP
      required = 2000 + MINIMUM_SKETCHUP
      detected = major.positive? ? "Detected SketchUp #{reported_version}." : 'Could not determine the SketchUp version.'
      UI.messagebox("OpenWalls needs SketchUp #{required} or newer.\n#{detected}")
      return false
    end

    SketchUpAdapter::Commands.install
    SketchUpAdapter::Observers.install
    @booted = true
    true
  rescue StandardError => e
    @booted = false
    Startup.report_error(e)
    false
  end

  def self.booted?
    !!@booted
  end
end
