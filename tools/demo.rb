# frozen_string_literal: true

# Builds a small building with the OpenWalls engine and writes it out as JSON
# and OBJ. No SketchUp involved -- that is the whole point. The same code that
# produces geometry inside the modeller runs here in a terminal, which is how
# it can be tested, profiled and previewed in a browser.
#
#   ./tools/ruby tools/demo.rb [output-dir]

require_relative '../src/openwalls/core'

include OpenWalls::Core # rubocop:disable Style/MixinUsage

# $0 rather than __FILE__ so this works under both a native ruby and the
# source-bundling ruby.wasm runner in tools/ruby.
OUT = ARGV[0] || File.join(File.dirname(File.dirname(File.expand_path($0))), 'preview')

def v(x, y)
  Vec2.new(x, y)
end

def wall(id, name, points, type, **extra)
  segments = points.each_cons(2).map { |(a, b)| Path::Line.new(a, b) }
  WallRecord.new(id: id, name: name, segments: segments, type: type, **extra)
end

# ---------------------------------------------------------------- the plan

CAVITY = WallType.preset('cavity-300')
PARTITION = WallType.preset('partition-100')
CONCRETE = WallType.preset('concrete-200')

W = 9000.0
D = 6000.0
EAVES = 2600.0
RIDGE = 4600.0

front = wall('front', 'Front wall', [v(0, 0), v(W, 0)], CAVITY, height: EAVES,
                                                                openings: [
                                                                  OpeningRecord.new(id: 'd1', name: 'Front door', kind: :door, station: 1500,
                                                                                    width: 1000, height: 2100, sill: 0),
                                                                  OpeningRecord.new(id: 'w1', name: 'Living window', kind: :window, station: 4200,
                                                                                    width: 2400, height: 1500, sill: 800),
                                                                  OpeningRecord.new(id: 'w2', name: 'Study window', kind: :window, station: 7400,
                                                                                    width: 1200, height: 1500, sill: 800)
                                                                ])

# The two short walls carry the gable: one record each, apex in the middle.
right = wall('right', 'Gable east', [v(W, 0), v(W, D)], CAVITY,
             height_start: EAVES, height_mid: RIDGE, height_end: EAVES,
             openings: [
               OpeningRecord.new(id: 'w3', name: 'Stair light', kind: :window, station: 3000,
                                 width: 1400, height: 1200, sill: 1000, shape: :round),
               OpeningRecord.new(id: 'w4', name: 'Gable porthole', kind: :window, station: 3000,
                                 width: 700, height: 700, sill: 3200, shape: :circle)
             ])

back = wall('back', 'Back wall', [v(W, D), v(0, D)], CAVITY, height: EAVES,
                                                             openings: [
                                                               OpeningRecord.new(id: 'd2', name: 'Garden doors', kind: :door, station: 4500,
                                                                                 width: 2400, height: 2200, sill: 0),
                                                               OpeningRecord.new(id: 'w5', name: 'Kitchen window', kind: :window, station: 1400,
                                                                                 width: 1500, height: 1200, sill: 1100)
                                                             ])

left = wall('left', 'Gable west', [v(0, D), v(0, 0)], CAVITY,
            height_start: EAVES, height_mid: RIDGE, height_end: EAVES,
            openings: [
              OpeningRecord.new(id: 'w6', name: 'Gable window', kind: :window, station: 3000,
                                width: 1600, height: 1400, sill: 900, shape: :gable, rise: 500)
            ])

partition = wall('part', 'Hall partition', [v(3600, 0), v(3600, D)], PARTITION, height: EAVES,
                                                                                openings: [
                                                                                  OpeningRecord.new(id: 'd3', name: 'Hall door', kind: :door, station: 1800,
                                                                                                    width: 850, height: 2040, sill: 0)
                                                                                ])

# A curved garden wall, mitered into a straight return: metadata-first arc,
# tessellated to a 0.5 mm sagitta at build time.
arc = Path::Arc.through(v(-1500, -2500), v(2000, -4200), v(5500, -2500))
garden_curve = WallRecord.new(id: 'garden-a', name: 'Garden wall (curved)',
                              segments: [arc], type: CONCRETE, height: 900, base_z: 0,
                              openings: [
                                OpeningRecord.new(id: 'o1', name: 'Gate', kind: :opening,
                                                  station: arc.length / 2.0, width: 1100, height: 800, sill: 0)
                              ])
garden_return = WallRecord.new(id: 'garden-b', name: 'Garden wall (return)',
                               segments: [Path::Line.new(v(5500, -2500), v(9000, -2500))],
                               type: CONCRETE, height: 900)

RECORDS = [front, right, back, left, partition, garden_curve, garden_return].freeze

# ------------------------------------------------------------------- build

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
results = OpenWalls::Core.build_all(RECORDS)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

# ------------------------------------------------------------------ report

puts
puts '  OpenWalls demo building'
puts '  ' + ('-' * 62)
results.each do |result|
  record = result.record
  flag = result.closed? ? 'watertight' : "OPEN: #{result.open_layers.join(', ')}"
  puts format('  %-22s %6.2f m  %2d layers  %7.3f m3  %s',
              record.name, OpenWalls::Core::Units.mm_to_m(record.length),
              result.layers.size, OpenWalls::Core::Units.mm3_to_m3(result.volume), flag)
  record.warnings.each { |w| puts "      ! #{w}" }
end
puts '  ' + ('-' * 62)
total = results.sum(&:volume)
faces = results.sum { |r| r.mesh.face_count }
puts format('  %d walls, %d faces, %.3f m3 of material, built in %.0f ms',
            results.size, faces, OpenWalls::Core::Units.mm3_to_m3(total), elapsed * 1000)
puts

puts '  Materials'
OpenWalls::Core::Takeoff.materials_sheet(results).each do |row|
  puts format('    %-16s %8.3f m3  %8.2f m2', row['Material'], row['Net volume (m3)'], row['Face area (m2)'])
end
puts

puts '  Opening schedule'
OpenWalls::Core::Takeoff.opening_types_sheet(results).each do |row|
  puts format('    %-5s %-7s %5d x %-5d sill %-5d  x%d', row['Type'], row['Kind'],
              row['Width (mm)'], row['Height (mm)'], row['Sill (mm)'], row['Count'])
end
puts

# ------------------------------------------------------------------ export

def write(path, contents)
  File.write(path, contents)
  puts format('  wrote %-34s %8.1f kB', File.basename(path), contents.bytesize / 1024.0)
end

KIND_COLOURS = {
  'masonry' => '#9c5a44', 'structure' => '#a7a7a4', 'insulation' => '#e0c477',
  'finish' => '#e8e4d8', 'cladding' => '#96703f', 'sheathing' => '#c4a46e'
}.freeze

payload = {
  'generator' => 'OpenWalls demo',
  'units' => 'mm',
  'stats' => {
    'walls' => results.size,
    'faces' => faces,
    'volume_m3' => OpenWalls::Core::Units.mm3_to_m3(total).round(3),
    'build_ms' => (elapsed * 1000).round(1),
    'watertight' => results.all?(&:closed?)
  },
  'walls' => results.map do |result|
    {
      'id' => result.record.id,
      'name' => result.record.name,
      'type' => result.record.type.name,
      'volume_m3' => OpenWalls::Core::Units.mm3_to_m3(result.volume).round(3),
      'watertight' => result.closed?,
      'layers' => result.layers.map do |entry|
        mesh = entry[:mesh]
        {
          'name' => entry[:layer].name,
          'kind' => entry[:layer].kind.to_s,
          'material' => entry[:layer].material,
          'colour' => KIND_COLOURS[entry[:layer].kind.to_s] || '#b0b0b0',
          'thickness' => entry[:layer].thickness,
          'volume_m3' => OpenWalls::Core::Units.mm3_to_m3(mesh.volume).round(4),
          'positions' => mesh.triangle_positions,
          'edges' => mesh.edge_positions
        }
      end
    }
  end,
  'takeoff' => OpenWalls::Core::Takeoff.sheets(results)
}

require 'json'
write(File.join(OUT, 'model.json'), JSON.generate(payload))

combined = results.each_with_object(OpenWalls::Core::Mesh.new) { |r, m| m.merge(r.mesh) }
write(File.join(OUT, 'model.obj'), combined.to_obj('openwalls-demo'))

OpenWalls::Core::Takeoff.to_csv_bundle(results).each do |name, csv|
  write(File.join(OUT, "takeoff-#{name}"), csv)
end

puts
puts '  Open preview/index.html to see it in 3D.'
puts
