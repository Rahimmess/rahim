# frozen_string_literal: true

# Compiles every Ruby file in the repository without executing it.
#
# Most of src/openwalls/sketchup/ cannot be *run* outside SketchUp, but it can
# always be parsed, and a typo there would otherwise only surface on a user's
# machine. Paths come in on ARGV so this works identically under a native ruby
# and under tools/ruby.
bad = 0
ARGV.each do |path|
  begin
    RubyVM::InstructionSequence.compile(File.read(path), path)
  rescue SyntaxError => e
    bad += 1
    puts "  FAIL #{path}"
    puts "       #{e.message.lines.first(4).join('       ').strip}"
  end
end
puts(bad.zero? ? "  #{ARGV.size} files parse cleanly" : "  #{bad} of #{ARGV.size} files failed to parse")
