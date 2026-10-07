# frozen_string_literal: true

# A ~100 line test framework.
#
# Not using minitest/rspec on purpose: SketchUp's embedded Ruby ships no
# bundler and no reliable gem path, and a plugin's test suite that cannot run
# inside the host it targets is a test suite people stop running. This harness
# works in a terminal, in SketchUp's Ruby console, and in the ruby.wasm
# sandbox used to develop this repo.
module TinyTest
  Case = Struct.new(:group, :name, :block)

  class Failure < StandardError; end

  # Flushed explicitly after every line. The harness has to survive the
  # process dying mid-run (a native crash in the host interpreter, say) with
  # its output intact, otherwise you learn nothing about which test did it.
  def self.say(line = '')
    puts line
    $stdout.flush
  end

  class << self
    def cases
      @cases ||= []
    end

    def current_group
      @current_group ||= 'general'
    end

    def group(name)
      previous = current_group
      @current_group = name
      yield
    ensure
      @current_group = previous
    end

    def test(name, &block)
      cases << Case.new(current_group, name, block)
    end

    def run!(filter: nil)
      selected = filter ? cases.select { |c| "#{c.group} #{c.name}".include?(filter) } : cases
      failures = []
      errors = []
      started = now

      last_group = nil
      selected.each do |test_case|
        if test_case.group != last_group
          TinyTest.say "\n  #{test_case.group}"
          last_group = test_case.group
        end
        context = Context.new
        begin
          context.instance_eval(&test_case.block)
          TinyTest.say "    \u2713 #{test_case.name}"
        rescue Failure => e
          failures << [test_case, e]
          TinyTest.say "    \u2717 #{test_case.name}"
          TinyTest.say "        #{e.message}"
        rescue StandardError, ScriptError => e
          errors << [test_case, e]
          TinyTest.say "    ! #{test_case.name}"
          TinyTest.say "        #{e.class}: #{e.message}"
          Array(e.backtrace).first(4).each { |line| TinyTest.say "          #{line}" }
        end
      end

      elapsed = now - started
      TinyTest.say
      TinyTest.say format('  %d tests, %d failures, %d errors  (%.2fs)',
                  selected.size, failures.size, errors.size, elapsed)
      (failures.empty? && errors.empty?)
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      Time.now.to_f
    end
  end

  # Assertions live on their own object so a test body cannot accidentally
  # reach into the runner's state.
  class Context
    def assert(condition, message = nil)
      return true if condition

      raise Failure, message || 'expected condition to be true'
    end

    def refute(condition, message = nil)
      assert(!condition, message || 'expected condition to be false')
    end

    def assert_equal(expected, actual, message = nil)
      return true if expected == actual

      raise Failure, message || "expected #{expected.inspect}, got #{actual.inspect}"
    end

    def assert_in_delta(expected, actual, delta = 1e-6, message = nil)
      diff = (expected - actual).abs
      return true if diff <= delta

      raise Failure,
            message || format('expected %.9g +/- %.3g, got %.9g (off by %.3g)', expected, delta, actual, diff)
    end

    # Relative comparison, which is what you want for volumes in cubic
    # millimetres where an absolute epsilon is meaningless.
    def assert_close(expected, actual, relative = 1e-9, message = nil)
      scale = [expected.abs, actual.abs, 1.0].max
      assert_in_delta(expected, actual, relative * scale, message)
    end

    def assert_raises(klass, message = nil)
      yield
      raise Failure, message || "expected #{klass} to be raised, nothing was"
    rescue Failure
      raise
    rescue StandardError => e
      return e if e.is_a?(klass)

      raise Failure, message || "expected #{klass}, got #{e.class}: #{e.message}"
    end

    def assert_includes(collection, item, message = nil)
      return true if collection.include?(item)

      raise Failure, message || "expected #{collection.inspect} to include #{item.inspect}"
    end

    def assert_empty(collection, message = nil)
      return true if collection.respond_to?(:empty?) && collection.empty?

      raise Failure, message || "expected empty, got #{collection.inspect}"
    end
  end
end

def test(name, &block)
  TinyTest.test(name, &block)
end

def group(name, &block)
  TinyTest.group(name, &block)
end
