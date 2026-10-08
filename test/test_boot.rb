# frozen_string_literal: true

require_relative 'support'
require_relative '../src/openwalls/startup'

OpenWalls.const_set(:MINIMUM_SKETCHUP, 21) unless OpenWalls.const_defined?(:MINIMUM_SKETCHUP)

# Minimal host doubles: startup orchestration should not need a running
# SketchUp process to be tested.
module Sketchup
  class << self
    attr_accessor :test_version

    def version
      @test_version || '22.0.0'
    end
  end
end

module UI
  class << self
    attr_accessor :messages

    def messagebox(message)
      self.messages ||= []
      messages << message
    end
  end
end

module OpenWalls
  module SketchUpAdapter
    module Commands
      class << self
        attr_accessor :install_count, :raise_on_install

        def install
          raise 'simulated toolbar failure' if raise_on_install

          self.install_count = (install_count || 0) + 1
        end
      end
    end

    module Observers
      class << self
        attr_accessor :install_count

        def install
          self.install_count = (install_count || 0) + 1
        end
      end
    end
  end
end

def reset_boot_test
  OpenWalls.instance_variable_set(:@booted, false)
  Sketchup.test_version = '22.0.0'
  UI.messages = []
  OpenWalls::SketchUpAdapter::Commands.install_count = 0
  OpenWalls::SketchUpAdapter::Commands.raise_on_install = false
  OpenWalls::SketchUpAdapter::Observers.install_count = 0
end

group 'Startup: boot' do
  test 'major version parsing accepts standard SketchUp version strings' do
    assert_equal 21, OpenWalls::Startup.major_version('21.1.332')
    assert_equal 25, OpenWalls::Startup.major_version(' 25.0.419 ')
    assert_equal 0, OpenWalls::Startup.major_version('unknown')
  end

  test 'older SketchUp versions are rejected before installing UI hooks' do
    reset_boot_test
    Sketchup.test_version = '20.0.0'

    refute OpenWalls.boot
    refute OpenWalls.booted?
    assert UI.messages.last.include?('SketchUp 2021 or newer')
    assert_equal 0, OpenWalls::SketchUpAdapter::Commands.install_count
    assert_equal 0, OpenWalls::SketchUpAdapter::Observers.install_count
  end

  test 'startup failures are reported and returned instead of escaping' do
    reset_boot_test
    OpenWalls::SketchUpAdapter::Commands.raise_on_install = true

    refute OpenWalls.boot
    refute OpenWalls.booted?
    assert UI.messages.last.include?('simulated toolbar failure')
  end

  test 'supported startup is successful and idempotent' do
    reset_boot_test
    Sketchup.test_version = '25.0.419'

    assert OpenWalls.boot
    assert OpenWalls.booted?
    assert OpenWalls.boot
    assert_equal 1, OpenWalls::SketchUpAdapter::Commands.install_count
    assert_equal 1, OpenWalls::SketchUpAdapter::Observers.install_count
  end
end
