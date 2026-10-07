# frozen_string_literal: true

# Thin wrappers so `rake` works for people who have it. The scripts in tools/
# are the real entry points and need neither rake nor bundler, because the
# development sandbox this was built in had no Ruby at all.

desc 'Run the geometry test suite'
task :test do
  sh 'ruby test/run.rb'
end

desc 'Parse-check every Ruby file, SketchUp adapter included'
task :syntax do
  sh 'tools/syntax'
end

desc 'Build the demo building headlessly and write preview/ + CSVs'
task :demo do
  sh 'ruby tools/demo.rb'
end

desc 'Package dist/openwalls-<version>.rbz'
task :build do
  sh 'tools/build'
end

desc 'Serve the 3D preview on http://localhost:8080'
task :preview do
  sh 'ruby tools/demo.rb && python3 -m http.server 8080 --directory preview'
end

task default: %i[syntax test]
