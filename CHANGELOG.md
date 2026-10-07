# Changelog

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
- 120-test suite asserting watertightness and closed-form volumes, runnable
  with no SketchUp and no gems.
- Headless demo and browser preview of engine output.
