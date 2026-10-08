# Changelog

## 0.1.1

- Added schematic timber and cold-formed steel framing layers with regional
  spacing presets, studs, plates, opening frames, gable-raking plates and
  noggings.
- Added framing member metadata, per-piece SketchUp groups, framing summaries
  and grouped cutting-list CSV output.
- Added arbitrary point-on-rail interpolation for accurately placing framing
  cuts between curve tessellation stations.
- Hardened `OpenWalls.boot`: parse SketchUp's major version explicitly, reject
  unsupported versions cleanly, make startup idempotent, and report startup
  failures instead of leaving an unhandled exception in the Ruby console.
- Fixed the test runner so an interpreter/setup failure or a zero-test run
  cannot be reported as a green test suite.
- Expanded the regression suite to 138 tests.

Framing member layouts and header rules are schematic quantity aids, not
structural engineering. Verify member sizes, bearings, connections, loads and
code compliance with a qualified designer.

## 0.1.0

First release.

- Layer-stack wall types: any number of layers, cavities and membranes take
  up thickness without generating geometry, each solid layer is its own closed
  solid and its own takeoff line.
- Paths of lines and arcs mixed freely; arcs stored as centre, radius and
  sweep and re-faceted from a sagitta tolerance on every rebuild.
- Start / mid / end heights in a single record: flat, sloped, gable,
  asymmetric pitch.
- Openings as profile functions: rectangular, segmental arch, semicircular,
  gable-headed and circular, re-cut on every rebuild.
- Automatic mitering across chains of walls by offsetting the whole run and
  slicing it; clean butt joints where the joint is not well defined.
- Quantity takeoff measured off the generated solids, exported as CSV.
- Wall type library stored inside the `.skp`.
- Drawing tool, opening tool, HtmlDialog panel, context menu, self test.
- Native Move and Rotate fold back into the record instead of breaking it.
- Headless demo and browser preview of engine output.
