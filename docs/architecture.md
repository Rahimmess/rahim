# Architecture

## The split

```
OpenWalls::Core            pure Ruby. No Sketchup, no Geom::, no UI.
OpenWalls::SketchUpAdapter the only code that touches the SketchUp API
```

`tools/build` refuses to package a release in which the core mentions the
SketchUp API at all. That check is the whole architecture in one assertion: it
keeps the engine honest, and it keeps the test suite meaningful — if the core
could quietly reach for `Sketchup.active_model`, then passing tests outside
SketchUp would prove nothing.

What lives where:

| Layer | Responsibility |
|---|---|
| `core/vec2.rb` | 2D vector, intersection, perpendicular |
| `core/units.rb` | millimetres everywhere internally; parses `2.3m`, `9"`, `3' 6 1/2"` |
| `core/path.rb` | `Line` and `Arc`; arcs keep centre/radius/sweep and tessellate on demand |
| `core/offset.rb` | index-preserving polyline offsetting with miter limit |
| `core/stations.rb` | the spine: arc-length stations and the rails offset from them |
| `core/mesh.rb` | indexed polygon soup, welding, volume, watertightness, OBJ |
| `core/wall_type.rb` | the layer stack |
| `core/opening_record.rb` | an opening as a profile function |
| `core/wall_record.rb` | the full editable spec sheet, JSON schema v1 |
| `core/framing.rb` | wall-local member plans, regional standards, cutting lists and framing meshes |
| `core/wall_builder.rb` | the ribbon mesher and coordination of solid/framed layers |
| `core/chain.rb` | cross-wall auto-mitering |
| `core/takeoff.rb` | quantities, framing summaries and CSV |
| `startup.rb` | guarded, idempotent extension bootstrapping |

## Stations and rails

Everything the mesher does hangs off one idea.

A wall's centreline is tessellated into points. Before any surface exists,
every arc length that *matters* is inserted into that point list as a
**station**: both edges of every opening, every facet of a curved opening
head, the apex of a gable, the junctions with neighbouring walls.

Only then are the **rails** built — one offset polyline per layer boundary,
produced by `Offset.polyline`, which guarantees exactly one output point per
input point. So rail index `i` means the same distance along the wall on every
rail, at every layer boundary, on both faces.

Two consequences follow, and they are why the rest of the code is short:

1. **Every feature boundary lands exactly on a station boundary.** The mesher
   walks bands between consecutive stations and either emits a band or skips
   it. It never has to split a quad, intersect a surface, or cut a loop into a
   face.
2. **A wall can borrow another wall's rails.** `Stations#slice` returns a
   child that reads its parent's rails over an index range. That is the entire
   mitering mechanism (below).

The price of index alignment is that a corner sharper than the miter limit is
*clamped* rather than bevelled — a bevel would insert a point and break the
invariant. `Offset.clamped_corners` reports those corners so the UI can say so
out loud.

## The ribbon mesher

For each solid layer, `WallBuilder` produces:

* the two **face skins**, from the near and far rails;
* **top** and **bottom** bands between them;
* two **end caps**;
* per opening, the **reveals** — sill, head and two jambs — stitching the near
  skin's hole boundary to the far skin's.

The vertical extent of each band at a station comes from `solid_bands`: the
wall runs from `base_z` to `height_at(t)`, minus the `[z_low, z_high]`
intervals of every opening active at that station. An opening is just a
function:

```ruby
OpeningRecord#profile(u) -> [z_low, z_high]   # u in 0..1 across the width
```

* rectangle — constant, 2 stations;
* gable — `h + rise·(1 − |2u − 1|)`, one extra station at the apex;
* arch / round — `h + rise·sqrt(1 − (2u−1)²)`, semicircular when `rise = w/2`;
* circle — `z_low` varies too, and `profile` returns `nil` at the tangent
  edges where the void pinches to nothing.

Curved heads are sampled **by angle**, not by width: `u = (1 − cos θ)/2`.
Uniform steps in `u` starve the near-vertical springing of a semicircle, which
is both uglier and measurably less accurate — the porthole test catches the
difference.

### T-vertices are deliberate

Next to a jamb, the skin is one tall quad on one side and two shorter quads on
the other. That is a T-vertex: the tall quad's edge has no single twin.

It is the right output. SketchUp splits the long edge automatically where the
short ones land, so you get clean manifold geometry with no redundant edges
running across the face of a wall. The alternative — propagating the sill and
head levels across the whole wall so every edge pairs up — would litter every
elevation with lines that are not there in the building.

So `Mesh#watertight?` does not demand a one-to-one edge pairing. It groups
unmatched edges by the line they lie on and checks that each is exactly
cancelled by opposite-facing edges on that line. A real hole leaves a residual
interval; a T-vertex does not. `Mesh#closed?` keeps the strict manifold test
for cases where that is what you want.

## Auto-mitering by slicing, not trimming

The usual approach to a corner is to find the neighbour, compute a bisector,
and trim two solids against each other. It works until it does not: a boolean
fails, or one wall is edited and the other keeps a stale corner.

`Chain` does something simpler. Walls that meet end-to-start with the same
`miter_signature`, justification and base level are concatenated into **one
continuous centreline**, which is offset **once** — so every corner becomes an
ordinary interior miter, handled by the same code that miters a bend inside a
single wall. The run is then sliced back apart at the junction vertices, with
each slice reading the parent's rails.

Each wall's end cap therefore lies exactly on the bisector, and the two walls
agree on the corner to the last float. Move an endpoint and the whole run
re-miters, because there was never any per-corner state to go stale.

Where the joint is not well defined, nothing clever is attempted:

* different layer stacks → butt joint (there is no correct miter between a
  300 mm cavity wall and a 100 mm partition);
* three or more walls at a point → all butt;
* different justification or base level → butt.

## Rebuilding

A wall is a SketchUp group carrying its `WallRecord` as JSON in an attribute
dictionary. Rebuilding is always *erase the geometry and regenerate it from
the record*, never incremental patching — incremental patching is how a
parametric modeller ends up with geometry and data that disagree and no way to
tell which is right.

Two details make that safe in practice:

* **Chain-aware rebuild.** Changing one wall rebuilds every wall chained to
  it, so a corner can never be left half-mitered.
* **Transform absorption.** If the user moved or rotated a wall with
  SketchUp's own tools, the transform is folded back into the record and the
  group reset to identity *before* the rebuild. Without this, Move would
  silently break the parametric link. Scaled or mirrored groups are left
  alone rather than being quietly misread.

## Testing strategy

Two properties, asserted on every configuration:

* **watertight** — catches a mis-stitched opening, a reveal wound the wrong
  way, a band dropped at a gable apex;
* **volume against a closed-form answer** — catches everything that is
  watertight but wrong.

The useful identity: for centre justification, a mitered band around a
polyline has area exactly `thickness × centreline length`, because the
triangle gained outside each corner equals the one lost inside. So:

| Case | Expected volume |
|---|---|
| straight wall | `L · T · H` |
| sloped top | `L · T · (h₁+h₂)/2` |
| gable | `T · (L/4) · (h₁ + 2h_mid + h₂)` |
| rectangular opening | gross − `w · h · T` |
| gable-headed opening | gross − `(w·h + w·rise/2) · T` |
| curved wall | `T · H ·` tessellated centreline length |
| L of two chained walls | `T · H · (L₁ + L₂)` |
| closed room of four walls | `T · H · perimeter` |

Several of those hold *exactly*, to 1e-9 relative — which is a much sharper
instrument than eyeballing a render.
