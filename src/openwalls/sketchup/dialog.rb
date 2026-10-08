# frozen_string_literal: true

module OpenWalls
  module SketchUpAdapter
    # The properties panel.
    #
    # One dialog, one pattern: the panel always shows the record of whatever
    # is selected, edits are applied to the record, and the geometry is
    # regenerated. There is no "create" mode distinct from an "edit" mode,
    # because there is no difference: a wall you drew five minutes ago and a
    # wall you drew last year are the same kind of object with the same
    # editable spec sheet.
    module Dialog
      module_function

      def instance
        @instance ||= build
      end

      def visible?
        !@instance.nil? && @instance.visible?
      end

      def show
        dialog = instance
        dialog.visible? ? dialog.bring_to_front : dialog.show
        refresh
        dialog
      end

      def toggle
        visible? ? instance.close : show
      end

      def build
        dialog = UI::HtmlDialog.new(
          dialog_title: 'OpenWalls',
          preferences_key: 'com.openwalls.panel',
          scrollable: true,
          resizable: true,
          width: 420,
          height: 760,
          min_width: 360,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        dialog.set_file(File.join(OpenWalls::PLUGIN_DIR, 'ui', 'panel.html'))
        register_callbacks(dialog)
        dialog.set_on_closed { @instance = nil }
        dialog
      end

      def register_callbacks(dialog)
        dialog.add_action_callback('ow_ready') { |_ctx| refresh }
        dialog.add_action_callback('ow_apply') { |_ctx, payload| apply(payload) }
        dialog.add_action_callback('ow_defaults') { |_ctx, payload| set_defaults(payload) }
        dialog.add_action_callback('ow_save_type') { |_ctx, payload| save_type(payload) }
        dialog.add_action_callback('ow_tool') { |_ctx, payload| start_tool(payload) }
        dialog.add_action_callback('ow_takeoff') { |_ctx| send_takeoff }
        dialog.add_action_callback('ow_export') { |_ctx| Commands.export_takeoff }
        dialog.add_action_callback('ow_delete_opening') { |_ctx, payload| delete_opening(payload) }
      end

      # -- Outbound ---------------------------------------------------------

      def refresh
        return unless visible?

        push('ow:state', state)
      end

      def push(channel, payload)
        return unless visible?

        instance.execute_script("window.OpenWalls.receive(#{JSON.generate(channel)}, #{JSON.generate(payload)});")
      end

      def state
        model = Sketchup.active_model
        selected = selected_walls(model)
        {
          'version' => OpenWalls::VERSION,
          'types' => Library.types.map(&:to_h),
          'framingStandards' => Core::Framing.standards.map(&:to_h),
          'defaults' => Library.defaults,
          'selection' => selected.map { |group| Attributes.read(group).to_h }.compact,
          'wallCount' => Attributes.all_walls(model).size
        }
      rescue StandardError => e
        { 'error' => e.message }
      end

      def send_takeoff
        results = ModelBuilder.all_results
        push('ow:takeoff', Core::Takeoff.sheets(results))
      rescue StandardError => e
        push('ow:takeoff', { 'error' => e.message })
      end

      # -- Inbound ----------------------------------------------------------

      def selected_walls(model = Sketchup.active_model)
        model.selection.grep(Sketchup::Group).select { |g| Attributes.wall?(g) }
      end

      # Applies a sparse patch to every selected wall. Sparse on purpose: the
      # panel sends only what the user touched, so editing the height of a
      # mixed selection does not flatten everything else to the first wall's
      # values.
      def apply(payload)
        patch = JSON.parse(payload)
        model = Sketchup.active_model
        groups = selected_walls(model)
        return UI.messagebox('Select one or more OpenWalls walls first.') if groups.empty?

        model.start_operation('Edit walls', true)
        groups.each do |group|
          record = Attributes.read(group)
          next unless record

          Attributes.write(group, patched(record, patch))
        end
        ModelBuilder.rebuild_chain(model, groups)
        model.commit_operation
        refresh
      rescue StandardError => e
        Sketchup.active_model.abort_operation
        UI.messagebox("OpenWalls could not apply that change:\n\n#{e.message}")
      end

      def patched(record, patch)
        hash = record.to_h
        hash['name'] = patch['name'] if patch['name'] && !patch['name'].empty?
        hash['justification'] = patch['justification'] if patch['justification']
        hash['base_z'] = patch['base_z'].to_f if patch.key?('base_z')
        hash['tolerance'] = patch['tolerance'].to_f if patch.key?('tolerance')

        if patch.key?('height')
          height = patch['height'].to_f
          hash['height_start'] = height
          hash['height_end'] = height
        end
        hash['height_start'] = patch['height_start'].to_f if patch.key?('height_start')
        hash['height_end'] = patch['height_end'].to_f if patch.key?('height_end')
        if patch.key?('height_mid')
          value = patch['height_mid']
          hash['height_mid'] = (value.nil? || value.to_s.empty?) ? nil : value.to_f
        end
        hash['type'] = Library.type(patch['type_id']).to_h if patch['type_id']
        hash['openings'] = patch['openings'] if patch['openings']

        Core::WallRecord.from_h(hash)
      end

      def delete_opening(payload)
        data = JSON.parse(payload)
        model = Sketchup.active_model
        groups = selected_walls(model)
        model.start_operation('Delete opening', true)
        groups.each do |group|
          record = Attributes.read(group)
          next unless record

          remaining = record.openings.reject { |op| op.id == data['id'] }
          next if remaining.size == record.openings.size

          Attributes.write(group, Core::WallRecord.from_h(record.to_h.merge('openings' => remaining.map(&:to_h))))
        end
        ModelBuilder.rebuild_chain(model, groups)
        model.commit_operation
        refresh
      rescue StandardError => e
        Sketchup.active_model.abort_operation
        UI.messagebox("OpenWalls: #{e.message}")
      end

      def set_defaults(payload)
        Library.update_defaults(JSON.parse(payload))
        refresh
      rescue StandardError => e
        UI.messagebox("OpenWalls: #{e.message}")
      end

      def save_type(payload)
        data = JSON.parse(payload)
        wall_type = Core::WallType.from_h(data)
        Library.save_type(wall_type)
        refresh
      rescue StandardError => e
        UI.messagebox("OpenWalls could not save that wall type:\n\n#{e.message}")
      end

      def start_tool(payload)
        data = JSON.parse(payload)
        case data['tool']
        when 'wall' then Sketchup.active_model.select_tool(WallTool.new)
        when 'door', 'window', 'louver', 'opening'
          overrides = {}
          overrides[:shape] = data['shape'].to_sym if data['shape']
          overrides[:width] = data['width'].to_f if data['width']
          overrides[:height] = data['height'].to_f if data['height']
          overrides[:sill] = data['sill'].to_f if data['sill']
          Sketchup.active_model.select_tool(OpeningTool.new(data['tool'], overrides))
        end
      end
    end
  end
end
