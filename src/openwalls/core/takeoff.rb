# frozen_string_literal: true

require_relative 'units'

module OpenWalls
  module Core
    # Quantity takeoff read straight off the built geometry.
    #
    # The numbers are not a parallel estimate of what the walls probably
    # contain -- they are the volume of the meshes that were actually
    # generated, so an opening deduction cannot drift out of step with the
    # model. If the hole is in the geometry it is out of the quantity, by
    # construction.
    module Takeoff
      # Converts a list of WallBuilder::Result into a set of named sheets,
      # each a plain array of hashes. Writers (CSV, the dialog table, a
      # spreadsheet) all consume the same structure.
      module_function

      def sheets(results)
        {
          'Walls' => walls_sheet(results),
          'Materials' => materials_sheet(results),
          'Layers' => layers_sheet(results),
          'Framing' => framing_sheet(results),
          'Cutting list' => cutting_list_sheet(results),
          'Openings' => openings_sheet(results),
          'Opening types' => opening_types_sheet(results),
          'Finish areas' => finish_areas_sheet(results)
        }
      end

      def walls_sheet(results)
        results.map do |res|
          rec = res.record
          {
            'Wall' => rec.name,
            'Id' => rec.id,
            'Type' => rec.type.name,
            'Length (m)' => r3(Units.mm_to_m(rec.length)),
            'Thickness (mm)' => r3(rec.total_thickness),
            'Height start (mm)' => r3(rec.height_start),
            'Height end (mm)' => r3(rec.height_end),
            'Base (mm)' => r3(rec.base_z),
            'Net volume (m3)' => r3(Units.mm3_to_m3(res.volume)),
            'Framing pieces' => res.members.size,
            'Framing volume (m3)' => r3(Units.mm3_to_m3(res.framing_volume)),
            'Openings' => rec.openings.size
          }
        end
      end

      # Volume per material, summed across every wall. This is the sheet a
      # quantity surveyor actually wants.
      def materials_sheet(results)
        acc = Hash.new { |h, k| h[k] = { volume: 0.0, area: 0.0, walls: {} } }
        results.each do |res|
          res.each_layer do |entry|
            layer = entry[:layer]
            key = layer.material || layer.name
            bucket = acc[key]
            bucket[:volume] += entry[:mesh].volume if layer.measure == :volume
            # Elevational area as well as volume: bricks and boards are
            # ordered by the square metre, concrete by the cubic metre, and
            # the sheet should answer both without a second export.
            bucket[:area] += entry[:mesh].area(:face_a)
            bucket[:walls][res.record.id] = true
          end
        end

        acc.map do |material, data|
          {
            'Material' => material,
            'Net volume (m3)' => r3(Units.mm3_to_m3(data[:volume])),
            'Face area (m2)' => r3(Units.mm2_to_m2(data[:area])),
            'Walls' => data[:walls].size
          }
        end.sort_by { |row| -row['Net volume (m3)'] }
      end

      def layers_sheet(results)
        rows = []
        results.each do |res|
          res.each_layer do |entry|
            layer = entry[:layer]
            mesh = entry[:mesh]
            rows << {
              'Wall' => res.record.name,
              'Layer' => layer.name,
              'Kind' => layer.kind.to_s,
              'Material' => layer.material,
              'Thickness (mm)' => r3(layer.thickness),
              'Net volume (m3)' => r3(Units.mm3_to_m3(mesh.volume)),
              'Face A area (m2)' => r3(Units.mm2_to_m2(mesh.area(:face_a))),
              'Face B area (m2)' => r3(Units.mm2_to_m2(mesh.area(:face_b)))
            }
          end
        end
        rows
      end

      # One summary line per framed wall layer, including any warnings that
      # require human review (for example an oversized header span).
      def framing_sheet(results)
        rows = []
        results.each do |res|
          res.framing.each do |entry|
            plan = entry[:plan]
            rows << {
              'Wall' => res.record.name,
              'Layer' => entry[:layer].name,
              'Standard' => plan ? plan.standard.name : entry[:layer].framing,
              'Spacing (mm)' => plan ? r3(plan.standard.spacing) : nil,
              'Studs' => plan ? plan.count(:stud) + plan.count(:king_stud) + plan.count(:jack_stud) : 0,
              'Cripples' => plan ? plan.count(:cripple) : 0,
              'Headers' => plan ? plan.count(:header) : 0,
              'Sills' => plan ? plan.count(:sill) : 0,
              'Plates' => plan ? plan.count(:sole_plate) + plan.count(:top_plate) : 0,
              'Noggings' => plan ? plan.count(:nogging) : 0,
              'Pieces' => plan ? plan.count : 0,
              'Volume (m3)' => plan ? r3(Units.mm3_to_m3(plan.volume)) : 0.0,
              'Warnings' => entry[:error] || (plan && plan.warnings.join('; '))
            }
          end
        end
        rows
      end

      # Aggregate framing into a merchant-ready cut list. Material is part of
      # the key so steel and timber with the same nominal section never merge.
      def cutting_list_sheet(results)
        counts = Hash.new(0)
        results.each do |res|
          res.framing.each do |entry|
            next unless entry[:plan]

            entry[:plan].cutting_list.each do |row|
              key = [row['Section'], row['Role'], row['Material'], row['Length (mm)']]
              counts[key] += row['Count']
            end
          end
        end
        counts.map do |(section, role, material, length), count|
          {
            'Section' => section, 'Role' => role, 'Material' => material,
            'Length (mm)' => length, 'Count' => count,
            'Total length (m)' => r3(Units.mm_to_m(length * count))
          }
        end.sort_by { |row| [row['Section'], -row['Length (mm)'], row['Role']] }
      end

      def openings_sheet(results)
        rows = []
        results.each do |res|
          rec = res.record
          rec.openings.each do |op|
            rows << {
              'Mark' => op.id,
              'Name' => op.name,
              'Kind' => op.kind.to_s,
              'Shape' => op.shape.to_s,
              'Wall' => rec.name,
              'Station (mm)' => r3(op.station),
              'Width (mm)' => r3(op.width),
              'Height (mm)' => r3(op.height),
              'Head (mm)' => r3(op.head_height),
              'Sill (mm)' => r3(op.sill),
              'Area (m2)' => r3(Units.mm2_to_m2(op.area)),
              'Built' => res.skipped_openings.include?(op) ? 'no - off wall' : 'yes'
            }
          end
        end
        rows
      end

      # Openings grouped by identical size and shape: the door/window
      # schedule, with a count against each type.
      def opening_types_sheet(results)
        acc = Hash.new { |h, k| h[k] = { count: 0, sample: nil } }
        results.each do |res|
          res.record.openings.each do |op|
            key = [op.kind, op.shape, op.width.round(1), op.height.round(1), op.sill.round(1), op.rise.round(1)]
            acc[key][:count] += 1
            acc[key][:sample] ||= op
          end
        end

        acc.values.sort_by { |d| [-d[:count], d[:sample].width] }.each_with_index.map do |data, i|
          op = data[:sample]
          {
            'Type' => format('%s%02d', op.kind.to_s[0].upcase, i + 1),
            'Kind' => op.kind.to_s,
            'Shape' => op.shape.to_s,
            'Width (mm)' => r3(op.width),
            'Height (mm)' => r3(op.height),
            'Sill (mm)' => r3(op.sill),
            'Area each (m2)' => r3(Units.mm2_to_m2(op.area)),
            'Count' => data[:count],
            'Total area (m2)' => r3(Units.mm2_to_m2(op.area * data[:count]))
          }
        end
      end

      # Paintable / renderable surface, already net of openings because the
      # skin was never generated there.
      def finish_areas_sheet(results)
        acc = Hash.new(0.0)
        results.each do |res|
          res.each_layer do |entry|
            next unless %i[finish cladding].include?(entry[:layer].kind)

            mesh = entry[:mesh]
            acc[[entry[:layer].material, 'Face A']] += mesh.area(:face_a)
            acc[[entry[:layer].material, 'Face B']] += mesh.area(:face_b)
          end
        end
        acc.reject { |_, v| v < 1.0 }.map do |(material, side), area|
          { 'Material' => material, 'Side' => side, 'Area (m2)' => r3(Units.mm2_to_m2(area)) }
        end
      end

      def r3(value)
        value.is_a?(Numeric) ? value.round(3) : value
      end

      # RFC 4180 CSV. Hand-rolled on purpose: no gem, nothing to install, and
      # it behaves identically on Windows and macOS SketchUp.
      def to_csv(rows)
        return '' if rows.empty?

        headers = rows.first.keys
        lines = [headers.map { |h| csv_cell(h) }.join(',')]
        rows.each { |row| lines << headers.map { |h| csv_cell(row[h]) }.join(',') }
        lines.join("\r\n") + "\r\n"
      end

      def csv_cell(value)
        str = value.nil? ? '' : value.to_s
        return str unless str.match?(/[",\r\n]/)

        '"' + str.gsub('"', '""') + '"'
      end

      # One file per sheet is friendlier than a single mega-CSV, and Excel
      # opens each cleanly. Returns { filename => contents }.
      def to_csv_bundle(results)
        sheets(results).each_with_object({}) do |(name, rows), out|
          out["#{name.downcase.tr(' ', '-')}.csv"] = to_csv(rows)
        end
      end
    end
  end
end
