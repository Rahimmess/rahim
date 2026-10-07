# How OpenWalls compares

OpenWalls was written as an open alternative to the commercial parametric
wall extensions for SketchUp, principally **MUZWalls** (Windows and macOS,
SketchUp 2024+, licensed per seat) and **Medeek Wall** (US stick framing).

This page is meant to be useful rather than flattering. If you need timber
framing, roofs, stairs or LayOut schedules today, the commercial tools do
those and OpenWalls does not.

## Where OpenWalls is genuinely better

### One concept instead of modes

Commercial wall tools distinguish a single wall from a double/cavity wall,
then add finishes, insulation and cladding as separate attachments with their
own dialogs. OpenWalls has a layer stack and nothing else. A partition is one
layer; a cavity wall is five; adding insulation is adding a layer. The same
structure drives geometry, materials, openings, quantities and — when it
arrives — IFC export, because it is already shaped like
`IfcMaterialLayerSet`.

### The engine runs without SketchUp

`src/openwalls/core/` is pure Ruby with no SketchUp API references, enforced
by the packaging script. You can build a whole building, measure it and export
it from a terminal:

```console
$ ruby tools/demo.rb
  7 walls, 3694 faces, 25.785 m3 of material, built in 285 ms
```

Closed-source extensions cannot be tested this way, which is why their
geometry bugs are reported by users rather than caught by a suite. OpenWalls
ships 120 tests that assert **watertightness** and **closed-form volumes** on
every wall configuration — gables, arches, portholes, curved walls, chained
corners, closed rooms. Several hold exactly, to 1e-9 relative.

### Supports four more years of SketchUp

MUZWalls requires SketchUp 2024 or newer. OpenWalls targets **2021+**, by
staying inside Ruby 2.7 syntax. CI runs the suite on 2.7, 3.2 and 3.3.

### No licence server, no activation, no expiry

MIT licensed, with nothing to activate and nothing that can stop working
because a server went away or a company changed its pricing. Your wall types
live inside your `.skp`, not in a vendor account.

### A smaller, auditable install

The whole extension is about **57 kB**. You can read every line of it. By
comparison, MUZWalls 4.4.0 is distributed as a ~137 MB signed archive whose
Ruby is protected, so nobody outside the vendor can audit it, fix it, or keep
it alive.

### Honest failure instead of plausible guesses

Where a joint is not well defined — different layer stacks meeting, three
walls at a point — OpenWalls butts cleanly and says so, rather than producing
a miter that looks right in plan and wrong in section. Openings that fall off
the end of a wall are reported and skipped, not silently clamped. The record
produces human-readable warnings ("Gable porthole w4 is taller than the wall
above it") that the panel can surface before you commit.

## Where the commercial tools are ahead

MUZWalls is a mature product with a much broader scope. As of 4.4.0 it has,
and OpenWalls 0.1 does not:

- timber framing (studs, plates, headers, blocking) with US/IRC, Canadian NBC
  and Australian AS1684 presets;
- cold-formed steel framing to DIN, EN, AISI and ASTM;
- reinforced concrete: foundations, columns, beams, slabs, rebar;
- roofs, dormers, skylights, stairs, floors, railings, lintels;
- sills, capping and trim that split at openings, with a profile editor;
- `.skp` component infills and Dynamic Component auto-resizing;
- PDF floor-plan import with scale calibration;
- LayOut output: schedules, labels, numbering, rooms, elevations;
- Excel export with dozens of sheets;
- an MCP server so an AI assistant can drive the toolset;
- six UI languages.

Medeek Wall remains the better choice for North American stick framing
specifically.

OpenWalls 0.1 deliberately does walls properly rather than everything badly.
The architecture — a headless, tested engine with a thin adapter — is chosen
precisely so that framing, lintels and schedules can be added as engine
features with closed-form tests, instead of as more code nobody can verify.

## Summary

| | OpenWalls 0.1 | Commercial parametric wall extensions |
|---|---|---|
| Licence | MIT, free | per-seat, from ~$15 |
| Activation | none, fully offline | licence key, online activation |
| SketchUp | 2021+ | 2024+ |
| Source | readable, forkable | protected |
| Testable without SketchUp | yes, 120 tests | no |
| Install size | ~57 kB | ~137 MB |
| Wall model | layer stack only | single / double modes plus attachments |
| Walls, arcs, gables, openings, miters, takeoff | yes | yes |
| Framing, roofs, stairs, LayOut, PDF import | no | yes |
