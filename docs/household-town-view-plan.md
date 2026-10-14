# Household economy town view: implementation plan

## Direction

Build a single-town visual view inside the household economy experience. It reads the **same live `HESimulation` instance** as the dashboard. A top-level Dashboard / Town switch should give the town view enough space for a camera and selection; the existing 250-pixel Town statistics tab remains a statistics tab. The first version does not modify the single-valley scene or the integration work in #19.

Treat town layout as stable runtime data, separate from 3D nodes and from the economy rules. Regenerate the starting layout on launch from a stable scenario seed and ordered business IDs. During a run, reuse a vacant building for a new business before allocating a new site. Rebuilding the view, advancing days, or adding a business must not move existing sites. A restart may produce small visual differences, provided the seeded town remains recognizably the same.

## First visible slice

- One government town center, one farm, a cattle ranch, and a sheep ranch when those businesses exist in the selected scenario. The setup page can omit the farm; the view must reflect that choice rather than invent an economic business.
- Reuse the RTS start game's building art: the castle model for government and the existing blue building models for farm and ranch structures. These are 3D models, not sprite files. Use visual-only instances so the RTS building scripts do not run in the household economy. Add field and pasture ground treatment to distinguish the farm and ranches; the repo has no dedicated farm or ranch building model.
- Show the live business name and a small amount of useful state on selection, linked to the existing business detail panel where practical. Camera framing, zoom, and pan should work at town scale.
- Other current business kinds may receive simple labeled placeholders in this slice, or be deliberately deferred behind a clear indicator of unplaced businesses. Decide this before implementation so the view does not silently omit economic activity.

## Data and placement contract

1. Add a town-layout record with stable `site_id`, `settlement_id`, 2D local position, rotation, footprint, and optional occupying `business_id`. Include a civic anchor for government. A site survives when its business fails; its occupancy changes from that business ID to vacant. Expose `type_key` in a read-only business report or a small dedicated layout query instead of reading `HESimulation.businesses` from the view.
2. Define a bounded, flat local town footprint and semantic zones: civic center, nearby farm fields, and outer pasture. Placement uses stable seed and ordered candidates, checks existing footprints and spacing, and reserves room for later additions. Do not rerun a full packing pass when the roster changes.
3. Reconcile layout against live business reports after business creation or government construction, and after failures. A failed business vacates its site but leaves the building visible. Assign the next new business to a vacant site in a stable order; allocate a new site only when none is vacant. Keep all other sites unchanged. For this phase, any vacant non-civic building is reusable regardless of business type or size; visual conversion and fit rules come later. Keep the town center reserved for government.
4. Derive the initial layout from a stable seed, town ID, scenario identity, and sorted starting business IDs. The current simulation itself has no save/load path, so a restart recreates the seeded economy and its layout. Newly built businesses from a previous run do not reappear until the economy gains save/load. Avoid dependence on global random state or report iteration order. A scenario identity must distinguish presets and custom rosters; `pending_builder` alone is not a durable identity. A later economy save can store layout coordinates as part of its save format if exact continuity becomes important.
5. Keep the renderer separate from the layout record. It maps `type_key` to art and builds visual-only models, labels, fields, and pasture. The layout record should be usable later by the valley renderer with a coordinate transform and terrain-height sampling, without bringing the household dashboard UI into the valley scene.

## Delivery slices

1. **Layout model and tests:** scenario identity, deterministic first generation, vacant-site reuse, incremental allocation, collision checks, and regeneration behavior.
2. **Town presentation:** full-size dashboard Town view, RTS art mapping, camera controls, labels, and selection. Verify it follows the same running economy and preserves positions when a business is built or fails.
3. **Valley handoff:** document the layout API and coordinate/footprint assumptions for #19. Integrating several towns into the valley is a later change.

## Acceptance checks

- The default scenario opens with a government center, farm, cattle ranch, and sheep ranch at distinct stable locations; a custom scenario shows only its actual businesses.
- Pause/advance/switch views without changing any placement. Creating a business fills a vacant building first; if none is vacant, it adds one site without moving existing ones.
- Reopen the same scenario and town: seeded sites regenerate in the same places under the same code and seed. Opening a different scenario produces a layout for its own live businesses. Minor differences after algorithm changes are acceptable.
- A business failure leaves an empty building on the ground and does not scramble survivors. The next new business occupies that building. A newly placed site cannot overlap an existing footprint.
- The household simulation harness and a Godot headless scene load still pass; a visual capture verifies camera framing and art scale.

## Questions to settle

1. For the first slice, should the Town view show simple labeled sites for all other active business types, or focus only on government, farm, and ranches with a visible count of the rest?
2. Which existing model should stand in for each farm/ranch building until dedicated art exists? Proposed: blue home/tavern variants, with fields and pasture doing most of the identification.

## Current-code anchors

- `scripts/sim/household_economy/he_dashboard.gd`: owns the simulation, constructs dashboard tabs, and handles business creation and government construction.
- `scripts/sim/household_economy/he_config.gd`: owns preset/custom setup; needs a durable scenario key.
- `scripts/sim/household_economy/he_simulation.gd`: exposes `get_business_reports()` and owns live business identity and failures.
- `scripts/sim/household_economy/data/he_scenario_seeds.gd`: registers farm, cattle ranch, sheep farm, and government.
- `scripts/valley/river_valley.gd`: current town clusters and visual-only model pattern; future consumer, not part of this slice.
- `assets/models/buildings/`: castle and blue home/tavern art used by the RTS/valley views.

## Implementation status (slice 1 and 2)

- `he_town_layout.gd`: layout record and allocation. Site coordinates are town-local 2D (x, y), centred on the civic anchor (site 0), bounded by +/-80 units; `footprint` is the unrotated size, `rotation` a multiple of PI/2. A valley consumer maps (x, y) to (x, height(x, y), y). Scenario identity is `scenario_key_for(builder)`: builder method plus order-insensitive bound arguments.
- `he_town_view.gd`: renderer, camera, selection. Fed by `sync(layout, reports)` from `he_dashboard.gd`; owns no positions.
- Business reports now carry `type_key` (the government's is `"government"`).
- Decisions: every business kind is placed (none deferred); ranches use a visual-only copy of the RTS barn box, farm/woodlot/trader/others use the blue home/tavern models, government the castle. Unplaced businesses (no room) are counted in the view.
- Checks: `scripts/sim/harness/check_town_layout.gd`, `check_town_view.gd` (headless); `capture_town_view.gd` (needs a renderer).
- Housing: houses are a second occupant kind (`dwelling_id`) in a residential zone, from `get_dwelling_reports()`; see `docs/household-housing.md`.
- `run_household_economy.gd` currently reports 4 failures (Trader/adoption) on master as well; unrelated to this change.
