# frozen_string_literal: true

# Test entry point. Works under a real ruby, inside SketchUp's console, and
# under the ruby.wasm runner used when no native ruby is available.
#
#   ./tools/ruby test/run.rb            # everything
#   ./tools/ruby test/run.rb openings   # only matching tests

require_relative 'harness'
require_relative 'test_core_math'
require_relative 'test_records'
require_relative 'test_wall_builder'
require_relative 'test_chain'
require_relative 'test_takeoff'

filter = ARGV.find { |a| !a.start_with?('-') }
TinyTest.say "\nOpenWalls test suite#{filter ? " (filter: #{filter})" : ''}"
ok = TinyTest.run!(filter: filter)
TinyTest.say(ok ? "\n  all green\n" : "\n  FAILED\n")
raise 'test suite failed' unless ok
