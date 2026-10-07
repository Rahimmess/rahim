# frozen_string_literal: true

module OpenWalls
  module SketchUpAdapter
    # Keeps the panel in step with the selection, and re-attaches itself when
    # the user opens another model.
    module Observers
      class SelectionWatcher < Sketchup::SelectionObserver
        def onSelectionBulkChange(_selection)
          Dialog.refresh
        end

        def onSelectionCleared(_selection)
          Dialog.refresh
        end

        def onSelectionAdded(_selection, _entity)
          Dialog.refresh
        end
      end

      class AppWatcher < Sketchup::AppObserver
        def onNewModel(model)
          Observers.attach(model)
        end

        def onOpenModel(model)
          Observers.attach(model)
        end
      end

      module_function

      def install
        return if @installed

        attach(Sketchup.active_model)
        Sketchup.add_observer(AppWatcher.new)
        @installed = true
      end

      def attach(model)
        return unless model

        model.selection.add_observer(SelectionWatcher.new)
        Dialog.refresh
      rescue StandardError => e
        Attributes.warn_once("could not attach observers (#{e.message})")
      end
    end
  end
end
