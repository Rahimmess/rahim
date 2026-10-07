# frozen_string_literal: true

module OpenWalls
  module SketchUpAdapter
    # Menu, toolbar and context menu.
    module Commands
      module_function

      def install
        return if @installed

        toolbar = UI::Toolbar.new('OpenWalls')
        menu = UI.menu('Extensions').add_submenu('OpenWalls')

        definitions.each do |spec|
          command = build_command(spec)
          toolbar.add_item(command)
          menu.add_item(command)
          toolbar.add_separator if spec[:separator_after]
        end

        menu.add_separator
        menu.add_item('Run self test') { run_self_test }
        menu.add_item('About OpenWalls') { about }

        install_context_menu
        toolbar.restore
        @installed = true
      end

      def definitions
        [
          { name: 'Draw wall', icon: 'wall',
            tip: 'Draw a run of parametric walls. A = arc, Enter = finish.',
            action: -> { Sketchup.active_model.select_tool(WallTool.new) } },
          { name: 'Door', icon: 'door', tip: 'Place a door in a wall.',
            action: -> { Sketchup.active_model.select_tool(OpeningTool.new(:door)) } },
          { name: 'Window', icon: 'window', tip: 'Place a window in a wall.',
            action: -> { Sketchup.active_model.select_tool(OpeningTool.new(:window)) } },
          { name: 'Arched window', icon: 'arch', tip: 'Place a window with a semicircular head.',
            action: -> { Sketchup.active_model.select_tool(OpeningTool.new(:window, shape: :round)) },
            separator_after: true },
          { name: 'Wall properties', icon: 'panel', tip: 'Open the OpenWalls panel.',
            action: -> { Dialog.show } },
          { name: 'Quantity takeoff', icon: 'takeoff', tip: 'Export quantities as CSV.',
            action: -> { export_takeoff } },
          { name: 'Rebuild all walls', icon: 'rebuild', tip: 'Regenerate every wall from its record.',
            action: -> { rebuild_all } }
        ]
      end

      def build_command(spec)
        command = UI::Command.new(spec[:name]) { safely(&spec[:action]) }
        command.tooltip = spec[:name]
        command.status_bar_text = spec[:tip]
        command.menu_text = spec[:name]
        attach_icons(command, spec[:icon])
        command
      end

      def attach_icons(command, icon)
        dir = File.join(OpenWalls::PLUGIN_DIR, 'ui', 'icons')
        path = File.join(dir, "#{icon}.svg")
        return unless File.exist?(path)

        command.small_icon = path
        command.large_icon = path
      end

      def install_context_menu
        UI.add_context_menu_handler do |context|
          walls = Dialog.selected_walls
          next if walls.empty?

          context.add_item('OpenWalls: properties') { Dialog.show }
          context.add_item('OpenWalls: rebuild') { safely { rebuild_selection(walls) } }
          context.add_item('OpenWalls: copy record as JSON') { safely { copy_record(walls.first) } }
        end
      end

      # -- Actions ----------------------------------------------------------

      def rebuild_all
        touched = ModelBuilder.rebuild_all
        Sketchup.status_text = "OpenWalls rebuilt #{touched.size} wall#{'s' unless touched.size == 1}."
      end

      def rebuild_selection(groups)
        model = Sketchup.active_model
        model.start_operation('Rebuild walls', true)
        ModelBuilder.rebuild_chain(model, groups)
        model.commit_operation
      end

      def copy_record(group)
        record = Attributes.read(group)
        return unless record

        text = JSON.pretty_generate(record.to_h)
        # No clipboard API in the SketchUp Ruby API; the console is the
        # reliable cross-platform place to put it.
        Sketchup.send_action('showRubyPanel:')
        puts text
      end

      # Writes one CSV per sheet into a folder the user picks. One file per
      # sheet rather than a single mega-CSV: every spreadsheet opens them
      # cleanly, and you can diff last week's materials sheet against this
      # week's.
      def export_takeoff
        results = ModelBuilder.all_results
        return UI.messagebox('There are no OpenWalls walls in this model yet.') if results.empty?

        bundle = Core::Takeoff.to_csv_bundle(results)
        target = UI.savepanel('Export quantity takeoff', nil, 'openwalls-takeoff.csv')
        return unless target

        directory = File.dirname(target)
        stem = File.basename(target, '.csv')
        written = bundle.map do |name, contents|
          path = File.join(directory, "#{stem}-#{name}")
          File.write(path, contents)
          path
        end

        UI.messagebox("Wrote #{written.size} sheets:\n\n#{written.map { |p| File.basename(p) }.join("\n")}")
      end

      def run_self_test
        results = ModelBuilder.all_results
        if results.empty?
          UI.messagebox('No walls to check yet. Draw one first.')
          return
        end

        open = results.reject(&:closed?)
        warnings = results.flat_map { |r| r.record.warnings }
        skipped = results.flat_map(&:skipped_openings)

        lines = ["#{results.size} walls checked."]
        lines << (open.empty? ? 'All solids are watertight.' : "#{open.size} wall(s) produced an open solid.")
        lines << "#{skipped.size} opening(s) could not be built." unless skipped.empty?
        lines.concat(warnings.first(10)) unless warnings.empty?
        UI.messagebox(lines.join("\n"))
      end

      def about
        UI.messagebox(<<~TEXT)
          OpenWalls #{OpenWalls::VERSION}

          Parametric walls for SketchUp. A wall is a layer stack with a path:
          every property stays editable, geometry is regenerated from the
          record, and quantities are read off the geometry.

          MIT licensed. No licence server, no account, works offline.
          Your wall types are stored inside your .skp file.
        TEXT
      end

      # Any engine error becomes a readable dialog instead of a red console.
      def safely
        yield
      rescue Core::Error => e
        UI.messagebox("OpenWalls:\n\n#{e.message}")
      rescue StandardError => e
        UI.messagebox("OpenWalls hit an unexpected problem:\n\n#{e.class}: #{e.message}")
        puts e.backtrace.first(10).join("\n")
      end
    end
  end
end
