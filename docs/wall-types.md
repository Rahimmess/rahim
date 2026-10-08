# Wall types

A wall type is an ordered list of layers across the thickness, from face A to
face B. Face A is the first layer, and by convention the exterior.

```ruby
WallType.new(id: 'cavity-300', name: 'Cavity 300', layers: [
  Layer.new(name: 'Facing brick', kind: :masonry,    thickness: 102.5, material: 'Brick'),
  Layer.new(name: 'Cavity',       kind: :cavity,     thickness: 50),
  Layer.new(name: 'PIR',          kind: :insulation, thickness: 100,   material: 'PIR'),
  Layer.new(name: 'Blockwork',    kind: :masonry,    thickness: 100,   material: 'Blockwork'),
  Layer.new(name: 'Plaster',      kind: :finish,     thickness: 13,    material: 'Plaster')
])
```

## Layer kinds

| Kind | Solid? | Typical use |
|---|---|---|
| `structure` | yes | concrete, generic structural core |
| `masonry` | yes | brick, block, stone |
| `insulation` | yes | PIR, mineral wool, EPS |
| `sheathing` | yes | OSB, ply, sheathing board |
| `finish` | yes | plaster, plasterboard, render |
| `cladding` | yes | timber, rainscreen, tile hanging |
| `cavity` | **no** | air gap — takes up thickness, generates no geometry |
| `membrane` | **no** | DPC, VCL, breather — too thin to model usefully |

Non-solid layers still occupy their thickness, so the leaves sit the right
distance apart and the overall wall measures correctly. They simply produce no
faces: a 0.5 mm vapour barrier modelled as a solid would be nothing but
z-fighting and triangle count.

A `structure` or `sheathing` layer can instead name a `framing` standard, such
as `uk-38x140-600`. That layer still occupies its place in the stack, but the
builder generates individual studs, plates, opening frames and noggings rather
than a solid sheet. Framing is reported separately as pieces and in a grouped
cut list. The included standards are schematic quantity aids, not engineering
checks; member sizes and connections must be verified for the project.

Each solid layer becomes its own closed solid, its own nested SketchUp group,
its own SketchUp tag (`OpenWalls / Masonry`, and so on) and its own row in the
takeoff.

## Built-in presets

| Id | Name | Thickness |
|---|---|---|
| `partition-100` | Partition 100 | 126 mm including plaster |
| `cavity-300` | Cavity 300 | 365.5 mm |
| `stud-140` | Timber stud 140 (solid insulation layer) | 208 mm |
| `concrete-200` | Concrete 200 | 200 mm |
| `timber-frame-140` | Timber frame 140 (UK) | 208 mm |
| `timber-frame-2x6` | Timber frame 2x6 (US) | 164 mm |
| `metal-stud-100` | Metal stud 100 (DIN) | 150 mm |

Presets are a starting point, not a constraint. Edit a stack in the Build-up
tab and save it; it is stored in the `.skp`, travels with the file, and
overrides a preset of the same id for that model.

## Justification

Where the drawn path sits relative to the stack.

| Setting | Meaning |
|---|---|
| `face_a` | the path runs along face A; the body is to the right of travel |
| `center` | the path runs up the middle |
| `face_b` | the path runs along face B; the body is to the left of travel |

Face A is always the boundary further to the left of the direction you drew,
whatever the justification — so the layer order on screen never flips
depending on which setting you picked.

## Mitering between types

Two walls miter when their **miter signature** matches: the list of layer
boundary positions across the thickness, rounded to a micron. Materials and
layer names are irrelevant.

That means a brick-faced cavity wall and a stone-faced cavity wall with the
same build-up will miter into each other cleanly, which is what you want at
the corner of a building. A 300 mm cavity wall meeting a 100 mm partition will
not, because there is no correct answer — those walls butt instead.
