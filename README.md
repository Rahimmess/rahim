# OpenWalls

**Parametric walls for SketchUp.** A wall is a layer stack with a path — one
concept, not a menu of modes. Draw it, keep editing it, and read the
quantities straight off the geometry.

Free, MIT licensed, no licence server, no account, works offline. Supports
SketchUp 2021 and newer.

```
./tools/bootstrap               # only if you have no ruby -- fetches one
./tools/demo                    # builds a whole building, no SketchUp needed
./tools/test                    # 138 tests against closed-form geometry
./tools/build                   # dist/openwalls-0.1.1.rbz
```

---

## The idea

Most wall plugins model a wall as *a box you can bolt things onto*: a single
wall, or a "double wall", plus separate finishes, plus separate insulation,
each with its own dialog and its own rules.

OpenWalls has exactly one structure:

```ruby
WallType.new(id: 'cavity-300', name: 'Cavity 300', layers: [
  Layer.new(name: 'Facing brick', kind: :masonry,    thickness: 102.5, material: 'Brick'),
  Layer.new(name: 'Cavity',       kind: :cavity,     thickness: 50),
  Layer.new(name: 'PIR',          kind: :insulation, thickness: 100,   material: 'PIR'),
  Layer.new(name: 'Blockwork',    kind: :masonry,    thickness: 100,   material: 'Blockwork'),
  Layer.new(name: 'Plaster',      kind: :finish,     thickness: 13,    material: 'Plaster')
])
```

A partition is a one-layer stack. A cavity wall is a five-layer stack. Adding
insulation is adding a layer, not switching mode. Each solid layer becomes its
own closed solid; cavities and membranes preserve spacing without fake
geometry; a framed structural layer becomes individually selectable members
and a cut list. The same stack is what IFC calls an `IfcMaterialLayerSet`, so
it is the right shape for export later rather than a convenient fiction now.

## What it does

| | |
|---|---|
| **Paths** | Straight, arc, or mixed in a single run. Arcs are stored as centre/radius/sweep and re-faceted on every rebuild from a sagitta tolerance — the facets are never the truth. |
| **Tops** | Start, mid and end heights in one record: flat, sloped, symmetric gable, asymmetric pitch. No splitting a wall to get a gable. |
| **Corners** | Walls that meet end-to-start with a compatible stack are mitered automatically. Walls with different stacks butt cleanly instead of guessing. |
| **Openings** | Rectangular, arched, segmental, gable-headed and circular. Stored as records and re-cut on every rebuild, so they heal themselves when the wall moves, lengthens or changes type. |
| **Justification** | Face A, centre, or face B on the path. |
| **Framing** | Optional timber or cold-formed steel layers with regional spacing presets, studs, plates, opening frames, gable-raking plates and noggings. Produces a schematic cut list; it is not structural design. |
| **Takeoff** | Volume, elevational area, framing summary, cutting list and opening schedule — measured from generated geometry and framing members. CSV out. |
| **Library** | Wall types, including framing choices, are saved inside the `.skp`. Send the model, send the library. |
| **Native tools** | Move and Rotate a wall with SketchUp's own tools; the transform is folded back into the record instead of breaking the parametric link. |

## Two decisions worth reading about

### 1. The geometry engine knows nothing about SketchUp

`src/openwalls/core/` is plain Ruby. No `Sketchup`, no `Geom::`, no `UI.` —
the build script [refuses to package a release that leaks any of
them](tools/build). Everything hard lives there: offsetting, mitering, arc
tessellation, opening profiles, framing plans, meshing and quantities.

`src/openwalls/sketchup/` is the only code that touches the API, and all it
does is turn meshes into groups and faces and JSON into attributes.

That is why this repository can do something most SketchUp extensions cannot:

```console
$ ./tools/demo

  OpenWalls demo building
  --------------------------------------------------------------
  Front wall               9.00 m   4 layers    5.031 m3  watertight
  Gable east               6.00 m   4 layers    5.939 m3  watertight
  Back wall                9.00 m   4 layers    5.163 m3  watertight
  Gable west               6.00 m   4 layers    6.000 m3  watertight
  Hall partition           6.00 m   3 layers    1.747 m3  watertight
  Garden wall (curved)     8.05 m   1 layers    1.274 m3  watertight
  Garden wall (return)     3.50 m   1 layers    0.630 m3  watertight
  --------------------------------------------------------------
  7 walls, 3694 faces, 25.785 m3 of material, built in 285 ms
```

A complete building — cavity walls, two gables, an arched window, a porthole,
a curved garden wall, ten openings — generated, measured and exported to OBJ,
JSON and CSV with no modeller running. Serve `preview/` over HTTP
(`rake preview`) and a browser renders the result in 3D, layer by layer.

### 2. Openings are ribbons, not booleans

Cutting a hole in a wall is where parametric wall tools usually break: a
boolean against a curved surface, an inner loop on a face that will not
triangulate, a hole that survives a rebuild in the wrong place.

OpenWalls never cuts anything. Every surface is a ribbon parameterised by
distance along the centreline, and **every feature boundary is inserted as a
station before the first offset rail is built** — opening edges, head facets,
gable apex, junctions. After that the mesher only ever emits a band or skips
it. There are no inner loops, no boolean operations, and openings behave
identically on a curved wall and a straight one.

The test suite checks geometry and the new framing planner as well:

* **watertight** — every boundary edge is cancelled by opposite edges on the
  same line, so the shell has no hole in it;
* **volume** — against a closed-form answer. For centre justification a
  mitered band has area exactly `thickness × centreline length`, because the
  triangle gained outside each corner equals the one lost inside. So an L of
  two 300 mm walls, 4 m and 3 m long, must come to `0.3 × 2.7 × 7.0 m³`
  exactly — a butt joint overshoots and an overlap undershoots;
* **framing plans** — stud/member counts, opening frames, raking plates,
  cutting-list rows and the watertightness of each generated frame piece.

```console
$ ./tools/test

  ok  Chain: mitered geometry              8 tests
  ok  WallBuilder: openings                13 tests
  ok  WallBuilder: curves and corners      7 tests
  ...
  138 tests, 0 failures, 0 errors
```

## Install

Download `openwalls-<version>.rbz` from the releases page, then in SketchUp:
**Extensions → Extension Manager → Install Extension**.

Or build it yourself:

```console
$ tools/build
  dist/openwalls-0.1.1.rbz  (39 files, 67.2 kB)
```

## Using it

* **Draw wall** — click each corner, `A` for an arc, type a length to be
  exact, `Enter` to finish. Each segment becomes its own editable wall, and
  the run auto-miters.
* **Door / Window / Arched / Porthole** — hover a wall, it snaps to the centre
  of the wall and clear of existing openings, click to place. Type
  `1200x2100` to resize before placing.
* **Wall properties** — the panel edits whatever is selected. On a multiple
  selection only the fields you actually change are applied.
* **Build-up** — edit the layer stack, see it to scale, and save it into the model. Choose a regional framing standard on a structure or sheathing layer to generate individual studs, plates, opening framing and a cutting list.
* **Quantities** — recalculate, then export one CSV per sheet, including a framing summary and grouped cut list where framing is present.

## Honest limitations in 0.1.1

* Thickness is constant along a wall (heights are not).
* Corners sharper than the miter limit are clamped rather than bevelled; the
  engine reports which ones so the panel can flag them.
* Walls with different layer stacks butt instead of mitering. This is
  deliberate: there is no single correct miter between a 300 mm cavity wall
  and a 100 mm partition, and a plausible-looking guess is worse than a clean
  joint.
* Three or more walls at one point all butt, for the same reason.
* Framing is a schematic takeoff aid: member spacing and opening details are
  generated from presets, but loads, connections, lintel sizing and code
  compliance are not verified. Have a qualified designer check every frame.
* No roofs, stairs or LayOut output yet; the engine is built to grow into them.

## Repository

```
src/openwalls/core/        the engine -- pure Ruby, zero SketchUp API
src/openwalls/sketchup/    the adapter -- the only code that imports SketchUp
src/openwalls/ui/          HtmlDialog panel
test/                      138 tests, hand-rolled harness, no gems
tools/bootstrap            fetches a Ruby if the machine has none
tools/ruby                 native ruby, else CRuby 3.3 on ruby.wasm
tools/test                 test runner
tools/syntax               parse-checks the adapter too
tools/demo                 builds a building headlessly
tools/build                packages the .rbz
preview/                   browser viewer for the headless output
docs/                      architecture, wall types, comparison, development
```

Further reading: [architecture](docs/architecture.md) ·
[wall types](docs/wall-types.md) ·
[how this compares](docs/comparison.md) ·
[development](docs/development.md)

## Licence

MIT. See [LICENSE](LICENSE).
