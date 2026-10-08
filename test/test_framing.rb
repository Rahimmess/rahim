# frozen_string_literal: true

require_relative 'support'

include Fixtures # rubocop:disable Style/MixinUsage

OWF = OpenWalls::Core

def framed_layer(id = 'uk-38x140-600', thickness = 140.0)
  OWF::Layer.new(name: 'Stud zone', kind: :structure, thickness: thickness,
                 material: 'Softwood C16', framing: id)
end

def framed_type(layer = framed_layer)
  OWF::WallType.new(id: 'framed-test', name: 'Framed test', layers: [layer])
end

group 'Framing: layer records' do
  test 'a framed layer is measured by pieces and round trips through a hash' do
    layer = framed_layer
    assert layer.framed?
    refute layer.solid?
    assert_equal :pieces, layer.measure
    restored = OWF::Layer.from_h(layer.to_h)
    assert_equal layer.to_h, restored.to_h
  end

  test 'older layer records without a framing key remain solid' do
    layer = OWF::Layer.from_h('name' => 'Concrete', 'kind' => 'structure', 'thickness' => 200)
    refute layer.framed?
    assert layer.solid?
    assert_equal :volume, layer.measure
  end

  test 'the catalogue includes timber and cold-formed steel standards' do
    ids = OWF::Framing.standards.map(&:id)
    assert ids.include?('uk-38x140-600')
    assert ids.include?('us-2x6-16')
    assert ids.include?('din-cw100-625')
    assert_raises(OWF::InvalidRecord) { OWF::Framing.standard('not-a-standard') }
  end
end

group 'Framing: plans' do
  test 'a straight wall gets end studs, repeated studs, plates and noggings' do
    record = straight_wall(length: 3600, height: 2400, type: framed_type)
    plan = OWF::Framing.plan(record, record.type.layers.first)

    assert_equal 1, plan.count(:sole_plate)
    assert_equal 1, plan.count(:top_plate)
    assert_equal 7, plan.count(:stud)
    assert_equal 6, plan.count(:nogging)
    assert plan.volume > 0
    assert_empty plan.warnings
  end

  test 'a window receives kings, jacks, header, sill and cripple studs' do
    record = straight_wall(length: 5000, height: 2700, type: framed_type,
                           openings: [window(station: 2500)])
    plan = OWF::Framing.plan(record, record.type.layers.first)

    assert_equal 2, plan.count(:king_stud)
    assert_equal 6, plan.count(:jack_stud)
    assert_equal 1, plan.count(:header)
    assert_equal 1, plan.count(:sill)
    assert plan.count(:cripple) >= 2
    assert_empty plan.warnings
  end

  test 'a framing standard deeper than its layer is rejected instead of mislabeled' do
    layer = framed_layer('us-2x6-16', 100.0)
    record = straight_wall(length: 5000, height: 2700, type: framed_type(layer))

    error = assert_raises(OWF::InvalidRecord) { OWF::Framing.plan(record, layer) }
    assert error.message.include?('only 100.0 mm thick')
  end

  test 'a gable breaks the top plate into two raking members' do
    record = OWF::WallRecord.new(
      id: 'gable-frame', segments: [line(0, 0, 5000, 0)], type: framed_type,
      height_start: 2400, height_mid: 3500, height_end: 2400
    )
    plan = OWF::Framing.plan(record, record.type.layers.first)
    plates = plan.members.select { |member| member.role == :top_plate }

    assert_equal 2, plates.size
    assert plates.all?(&:raking?)
    assert plates.all? { |member| member.cut_length > member.s1 - member.s0 }
  end

  test 'an opening too near an end reports a warning instead of extending framing outside the wall' do
    record = straight_wall(length: 3000, height: 2700, type: framed_type,
                           openings: [window(station: 550, width: 1000)])
    plan = OWF::Framing.plan(record, record.type.layers.first)

    assert plan.warnings.any? { |warning| warning.include?('too close to a wall end') }
    refute plan.members.any? { |member| member.role == :king_stud && (member.s0 < 0 || member.s1 > 3000) }
  end

  test 'a wall too short to frame still builds its other solid layers' do
    layer = framed_layer
    type = OWF::WallType.new(
      id: 'mixed-frame', name: 'Mixed frame',
      layers: [OWF::Layer.new(name: 'Board', kind: :finish, thickness: 12.5), layer]
    )
    record = straight_wall(length: 3000, height: 50, type: type)
    result = OWF.build(record)

    assert_equal 1, result.layers.size
    assert result.framing_warnings.any? { |warning| warning.include?('too short') }
    assert result.volume > 0
  end

  test 'builder exposes framed pieces separately from solid volume' do
    record = straight_wall(length: 3600, height: 2400, type: framed_type)
    result = OWF.build(record)

    assert_empty result.layers
    assert result.framed?
    assert result.members.size > 0
    assert result.closed?
    assert_equal 0.0, result.volume
    assert result.framing_volume > 0
    assert result.mesh.face_count > 0
    pieces = OWF::Framing.member_meshes(result.framing.first[:plan], record, result.stations)
    pieces.each do |member, mesh|
      assert mesh.watertight?, "#{member.role} mesh should be watertight"
      assert_close member.volume, mesh.volume, 1e-9
    end
  end

  test 'every framing piece is a closed mesh and can be built on an arc' do
    arc = OWF::Path::Arc.through(v(0, 0), v(2500, 2500), v(5000, 0))
    record = OWF::WallRecord.new(id: 'curved-frame', segments: [arc], type: framed_type,
                                 height: 2400, tolerance: 10.0)
    result = OWF.build(record)
    pieces = OWF::Framing.member_meshes(result.framing.first[:plan], record, result.stations)

    assert pieces.size > 0
    assert pieces.all? { |_member, mesh| mesh.watertight? }
    assert pieces.all? { |_member, mesh| mesh.volume.positive? }
  end

  test 'cutting list groups identical lengths by section, role and material' do
    record = straight_wall(length: 3600, height: 2400, type: framed_type)
    plan = OWF::Framing.plan(record, record.type.layers.first)
    rows = plan.cutting_list

    assert rows.any? { |row| row['Role'] == 'stud' && row['Count'] == 7 }
    assert rows.all? { |row| row.key?('Material') && row.key?('Total length (m)') }
  end
end
