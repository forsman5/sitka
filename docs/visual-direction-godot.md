# Direction A: Improve the landscape in Godot first

**Recommendation:** Start here. Keep the authored landform and improve how it reads in the actual game camera. This is a small visual pass, not a terrain-system rewrite.

## What the current image needs

The valley's transport structure is readable, but broad green surfaces lack scale cues. The blue river has sharp joins and awkward overlaps around Aldford; roads look like constant-width ribbons. Tiny, regularly scattered trees and similar building clusters make settlements difficult to distinguish. Terrain edges expose the rectangular scene boundary.

The code supports this diagnosis: the terrain shader blends flat biome colors, while river and road segments are built from boxes. Increasing texture resolution or adding a sharpening effect would leave those structural problems intact.

## Proposed visual direction

Aim for a restrained, illustrated landscape: muted grass and earth, darker woodland masses, pale worn paths, and calm water. Keep major shapes readable from above. Add detail that survives the ordinary play camera before adding detail visible only in close-up.

1. **Repair the river silhouette.** Plan continuous river geometry with clean junctions, consistent water level along each reach, and readable banks. The current segment orientation only follows the horizontal direction; texturing these strips will not make them conform to the land. Review channel shape, water placement, and the ford together.
2. **Give the ground three scales of detail.** Retain biome masks for broad land use; add irregular patches of worn grass, soil, and exposed rock; add subtle repeating grass/earth textures for close views. Begin with three or four shared materials. Avoid tiny high-contrast noise that sparkles or disappears at valley scale.
3. **Ground the roads and settlements.** Use terrain-following paths with softer, irregular edges, dirt around entrances, and clear connections to the landing. Fields should read as patches of cultivated land rather than raised yellow blocks.
4. **Improve light and composition.** Compare one consistent angled sun and soft ambient fill at two fixed camera distances. Seek readable roofs and slopes without crushed shadows. Reduce the visual prominence of the map boundary through framing or a simple surrounding landscape.
5. **Make vegetation form masses.** Retain existing tree assets initially. Vary cluster density and size, preserve clearings, and soften woodland edges instead of scattering evenly across a large ellipse.

## Division of work

**Godot:** terrain material blending, water appearance, lighting, path placement, vegetation distribution, camera framing, and final evaluation.

**Blender:** only revise the existing height/biome source if the landform or river channel itself needs correction. Preserve the export alignment used by height queries and collision.

## Small first deliverable

Polish the Aldford river junction and a short stretch of road with the existing building placeholders. Compare identical overview and settlement-camera screenshots before extending the treatment.

**Accept when:** the river junction looks continuous, roads sit on the ground, materials separate grass/dirt/water, and the landing is easier to understand at normal zoom.

**Scale guardrail:** reuse materials and placement rules across valleys. Do not hand-paint unique detail across all five settlements, much less 100. Leave asset-count and texture budgets provisional until measured in Godot.

This note proposes work only; no implementation accompanies it.
