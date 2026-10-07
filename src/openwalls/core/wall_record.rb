# frozen_string_literal: true

require_relative 'errors'
require_relative 'path'
require_relative 'wall_type'
require_relative 'opening_record'

module OpenWalls
  module Core
    # The spec sheet. Geometry is generated *from* this record on every
    # rebuild; the record is never generated from geometry.
    #
    # Consequences worth stating out loud, because they are the whole point:
    #   * every property stays editable forever -- nothing is baked into faces
    #   * a curved wall is a centre/radius/sweep, not 12 frozen facets
    #   * reopening a file and rebuilding is deterministic and idempotent
    #   * the record round-trips through JSON, so it survives version changes
    #     and can be diffed, logged and tested without a modeller running
    class WallRecord
      SCHEMA_VERSION = 1

      JUSTIFICATIONS = %i[face_a center face_b].freeze

      attr_reader :id, :name, :chain_id, :type, :justification, :base_z,
                  :height_start, :height_mid, :height_end, :segments,
                  :openings, :tolerance, :miter_limit, :meta

      def initialize(id:, segments:, type:, name: nil, chain_id: nil, justification: :center,
                     base_z: 0.0, height: 2700.0, height_start: nil, height_mid: nil, height_end: nil,
                     openings: [], tolerance: Path::DEFAULT_TOLERANCE,
                     miter_limit: Offset::DEFAULT_MITER_LIMIT, meta: {})
        @id = id.to_s
        @name = name || "Wall #{@id}"
        @chain_id = chain_id
        @segments = Array(segments)
        @type = type
        @justification = justification.to_sym
        @base_z = base_z.to_f
        @height_start = (height_start || height).to_f
        @height_end = (height_end || height).to_f
        @height_mid = height_mid&.to_f
        @openings = Array(openings)
        @tolerance = tolerance.to_f
        @miter_limit = miter_limit.to_f
        @meta = meta || {}

        raise InvalidRecord, "wall #{@id} has no segments" if @segments.empty?
        raise InvalidRecord, "unknown justification #{@justification.inspect}" unless JUSTIFICATIONS.include?(@justification)
        raise InvalidRecord, "wall #{@id} has non-positive height" if [@height_start, @height_end].min <= 0
      end

      def total_thickness
        @type.total_thickness
      end

      def length
        Path.total_length(@segments)
      end

      def centerline_points
        Path.tessellate(@segments, @tolerance)
      end

      # Signed distance from the path to face A (the first layer's outer
      # surface). Positive is to the left of travel direction.
      def face_a_offset
        case @justification
        when :face_a then 0.0
        when :face_b then total_thickness
        else total_thickness / 2.0
        end
      end

      # Top of the wall above its own base, at normalised position t along the
      # run. A mid height turns one wall into a gable or an asymmetric pitch
      # without splitting it into two records.
      def height_at(t)
        t = t.clamp(0.0, 1.0)
        return @height_start + (@height_end - @height_start) * t if @height_mid.nil?

        if t <= 0.5
          @height_start + (@height_mid - @height_start) * (t / 0.5)
        else
          @height_mid + (@height_end - @height_mid) * ((t - 0.5) / 0.5)
        end
      end

      def max_height
        [@height_start, @height_end, @height_mid || 0.0].max
      end

      def gable?
        !@height_mid.nil? && @height_mid > [@height_start, @height_end].max + 1e-6
      end

      def flat_top?
        @height_mid.nil? && (@height_start - @height_end).abs < 1e-6
      end

      def opening(id)
        @openings.find { |o| o.id == id }
      end

      def with(**changes)
        self.class.from_h(to_h.merge(stringify(changes)))
      end

      # Non-fatal problems, as human sentences. The dialog shows these; the
      # engine still builds something sensible.
      def warnings
        out = []
        len = length
        @openings.each do |op|
          out << "#{op.name} #{op.id} starts before the wall does" if op.start_station < -1e-6
          out << "#{op.name} #{op.id} runs past the end of the wall" if op.end_station > len + 1e-6
          head = op.head_height
          min_top = [height_at((op.start_station / len).clamp(0, 1)), height_at((op.end_station / len).clamp(0, 1))].min
          # An opening whose head reaches the wall top exactly is fine -- it
          # just splits the wall into two piers, which is a real detail.
          out << "#{op.name} #{op.id} is taller than the wall above it" if head > min_top + 1e-6
        end
        overlaps.each { |(a, b)| out << "#{a.name} #{a.id} overlaps #{b.name} #{b.id}" }
        out
      end

      # Two openings clash only when they overlap horizontally *and*
      # vertically. A fanlight directly above a door shares its whole span
      # and is perfectly legal, so a purely horizontal test would cry wolf on
      # one of the most ordinary details there is.
      def overlaps
        sorted = @openings.sort_by(&:start_station)
        out = []
        sorted.combination(2) do |a, b|
          next unless b.start_station < a.end_station - 1e-6 && a.start_station < b.end_station - 1e-6
          next unless b.sill < a.head_height - 1e-6 && a.sill < b.head_height - 1e-6

          out << [a, b]
        end
        out
      end

      def to_h
        {
          'schema' => SCHEMA_VERSION,
          'id' => @id, 'name' => @name, 'chain_id' => @chain_id,
          'segments' => @segments.map(&:to_h),
          'type' => @type.to_h,
          'justification' => @justification.to_s,
          'base_z' => @base_z,
          'height_start' => @height_start, 'height_mid' => @height_mid, 'height_end' => @height_end,
          'openings' => @openings.map(&:to_h),
          'tolerance' => @tolerance, 'miter_limit' => @miter_limit,
          'meta' => @meta
        }
      end

      def to_json(*args)
        require 'json'
        to_h.to_json(*args)
      end

      def self.from_h(hash)
        version = hash['schema'] || 1
        raise UnsupportedSchema, "wall record schema #{version} is newer than this build" if version > SCHEMA_VERSION

        new(
          id: hash['id'], name: hash['name'], chain_id: hash['chain_id'],
          segments: (hash['segments'] || []).map { |s| Path.segment_from_h(s) },
          type: WallType.from_h(hash['type']),
          justification: (hash['justification'] || 'center').to_sym,
          base_z: hash['base_z'] || 0.0,
          height_start: hash['height_start'], height_mid: hash['height_mid'], height_end: hash['height_end'],
          openings: (hash['openings'] || []).map { |o| OpeningRecord.from_h(o) },
          tolerance: hash['tolerance'] || Path::DEFAULT_TOLERANCE,
          miter_limit: hash['miter_limit'] || Offset::DEFAULT_MITER_LIMIT,
          meta: hash['meta'] || {}
        )
      end

      def self.from_json(text)
        require 'json'
        from_h(JSON.parse(text))
      end

      private

      def stringify(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end
    end
  end
end
