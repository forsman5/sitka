# Household economy town view: daily village cycle

## Direction

Fill the Town view with little villagers who live the day the simulation just computed. Each household member is a visible villager. They wake at their house, walk the roads to the business that employs them, work, come home, and disappear indoors at night.

Most of the groundwork exists already:

- **Clock.** The Town view runs its own clock (`he_dashboard.gd:_advance_town_time`, `GameState.town_day_seconds`). The view's lighting follows it (`HETownView.set_time_of_day`). The sim ticks once per visual day at `TOWN_TICK_PHASE` (05:30). That is before villagers are awake, so roster changes from a tick (jobs, births, departures, new houses) happen while everyone is indoors.
- **Jobs.** `HEHousehold.employer_business_id` holds the job. A household works as one unit for one employer. `HETownLayout.site_of_business()` gives the workplace site.
- **Houses and roads.** Houses are layout sites with a `road_id` and an `access` point on the road centreline. Roads are polylines that only grow.

**Missing:**

1. **House assignment.** Housing is a pooled capacity today. Households are not assigned to a house (`TODO(housing-assignment)`). Homeless status is derived from household id order.
2. **Villager identity and a model.** Members exist only as age arrays on the household. Nothing is rendered.
3. **Movement.** There is no path network over the roads and no daily schedule.

Rule kept from the town view plan: the simulation owns economic truth, the layout owns positions, and the view only renders. Villager motion is cosmetic. It never feeds back into the economy.

## 1. Simulation: assign houses to households

### Data

- `HEHousehold.dwelling_id: int = -1`. This is the source of truth: the house this household lives in, or -1 when homeless or when housing is not modeled.
- House occupancy is **derived**, not stored twice. A house's occupants are the households whose `dwelling_id` matches. If a reverse index is ever needed for speed, rebuild it inside the same reconcile function so the two can never drift.

### Rules

All assignment goes through one function, `HESimulation._reconcile_housing(settlement_id)`:

1. **Sticky.** A housed household keeps its house for life. It loses it only when the household is removed (emigration, old age, adoption).
2. **Free slots.** A house has `capacity_households` slots: 1 for a plain house, 4 for a tenement. An upgrade in place adds 3 free slots to the same house.
3. **Fill order.** Unhoused households are taken in ascending id. Each one takes a free slot in the house with the **lowest dwelling id**, which is the innermost house because ids follow placement order. This is deterministic and keeps the town filled from the centre outward.
4. **Unmodeled housing** (`housing_modeled == false`). Everyone keeps `dwelling_id = -1`, with status `"unlimited"`.

Call it:

- at the start of `_daily_tick`, so the monthly homeless emigration pass reads current assignments;
- after household removal, splits and adoption inside the tick (or once at the end of the tick);
- from `add_dwelling()` and the tenement upgrade, so a new house is occupied the same day.

### Homelessness keeps the same numbers

- `_homeless_household_ids()` and `_housing_status_of()` switch from "id rank past capacity" to `dwelling_id == -1`. Iterate in sorted id order, as now.
- Capacity and household counts are unchanged, so homeless counts match today's. New households always have higher ids, so in practice the same households end up homeless.
- **Acceptance:** `run_household_economy.gd` produces the same populations, emigration and housing totals as on master. Any difference must be explained before merge. Master already reports 4 Trader/adoption failures; those are unrelated.

### Reports

- `get_household_summary()` gains `dwelling_id`.
- `get_dwelling_reports()` gains `occupant_household_ids` (sorted). The house info panel in the Town view can then say "Home of household 12 (4 people)".
- New lightweight query `get_villager_reports(settlement_id) -> Array`, ascending household id. It is cheap because the view calls it on every tick, and the heavy `get_household_summary` is not suitable:
  ```
  {household_id, dwelling_id, employer_business_id, housing_status,
   worker_ages: PackedInt32Array, dependent_ages: PackedInt32Array}
  ```
- Update `docs/household-housing.md`: remove "not assigned" from *Still open* and document the rules above.

### Check

New harness `scripts/sim/harness/check_housing_assignment.gd`:

- Seeded presets start with every household housed up to capacity, with no house over capacity.
- Assignments survive many ticks unchanged for surviving households.
- A removed household frees its slot, and the next unhoused household takes it.
- A new house or tenement upgrade is occupied in the same call.
- With unmodeled housing, every household is `"unlimited"` with `dwelling_id = -1`.

## 2. Villager identity

There are no persistent member ids yet. A villager's key is `(household_id, role, slot)`: role is `worker` or `dependent`, and slot is the index into that household's age array. That is enough for visuals:

- When a member leaves, the household's array shrinks from the back, so that villager disappears. Other villagers can shift slot but keep their household, house, job and appearance.
- Appearance is seeded from `household_id` (shared tint per household) plus slot (small hue/scale jitter). A family therefore reads as a family, and a split-off household gets its own colour.
- Dependents render as children at about 0.6 scale, the same idea as `OnFootSheep.LAMB_SCALE`. Dependents past `AGING_THRESHOLD_DAYS` who have not left home render at adult size.

Persistent member ids (the `last_promoted_member_numbers` placeholder in `he_household.gd`) are a separate, later change. Nothing here depends on them.

## 3. Road paths (layout side, pure data)

New `scripts/sim/household_economy/he_town_paths.gd` (`RefCounted`, no nodes), built from an `HETownLayout`:

- **Graph.**
  - Nodes are road polyline points. Each spoke's first point joins the civic anchor (0, 0).
  - A lane's first point lies on its parent road. Split the parent segment there and join them.
  - Each site's `access` point is projected onto its road and inserted as a node.
- **Off-road sites.** Field and pasture businesses have `access == Vector2.INF`. Connect them with a straight leg from the nearest road point to the footprint edge.
- **Path query.** `path(from_site_id, to_site_id) -> PackedVector2Array` returns door → access → graph shortest path (A*/Dijkstra) → access → door, cached per site pair.
- **Rebuild.** Roads only grow, so rebuild when `layout.road_count()` changes and keep the cache otherwise.
- A valley consumer can reuse it later through the same coordinate transform as sites.

Check `check_town_paths.gd`: every built site is reachable from the civic anchor. Paths stay on road ribbons except for door and off-road legs. A path is the same before and after unrelated sites are added.

## 4. Daily schedule (pure function of time)

New `scripts/sim/household_economy/he_villager_schedule.gd`. A villager's position is computed directly from `(villager key, day, time_of_day, roster, paths)`: no physics, no steering, no stored state. Pause, speed changes, switching views and the dashboard's fast-forward therefore can never desync or drift the crowd.

Default timeline (hours). Each villager gets seeded jitter of about ±30 min, keyed by villager key and sim day, so they do not move in lockstep:

| Time | Employed adult | Unemployed adult | Child | Homeless |
|------|----------------|------------------|-------|----------|
| 05:30 | Indoors (sim ticks) | Indoors | Indoors | Asleep at the plaza edge |
| 06:00–08:00 | Leaves the door, walks to the workplace | Leaves; walks to the civic plaza | Steps out, plays near home | Gets up |
| 08:00–17:00 | **Works.** Field/pasture/woodlot: slow wander inside the footprint. Town business: goes inside (hidden), with brief trips to the door | Loiters at the plaza | Plays near home or the plaza | Loiters at the plaza |
| 17:00–19:30 | Walks home; some stop at the trader/plaza on the way | Walks home | Heads home | Stays at the plaza |
| 19:30–21:00 | Near own door, then goes inside | Same | Inside | Plaza |
| 21:00–05:30 | Hidden indoors | Hidden | Hidden | Visible and lying at the plaza: homelessness shows on the map |

- **Walk speed.** Each walking leg gets a duration that fits its time window. Speed is path length / duration, with a cap so a long commute leaves early instead of sprinting. `town_day_seconds` changes real-time speed only, never the route.
- **Workplace slots.** Each worker gets a seeded point inside its employer's footprint. In a field, that point drifts slowly along the furrows.
- **Ticks.** `sync()` hands the view a new roster when the sim ticks at 05:30. New villagers appear at their door at their wake time. Departed villagers are simply absent. A job change shows as a different morning walk.

Check `check_villager_schedule.gd`:

- Everyone housed is hidden from 21:00 to 05:30.
- Every employed worker is inside its employer's footprint at noon.
- Positions are continuous over time, with no teleports except entering and leaving doors.
- The same inputs always produce the same positions.

## 5. Rendering and the model

New `scripts/sim/household_economy/he_villagers.gd`, a `Node3D` under the town view's `_sites_root`. `HETownView` owns it and feeds it from `sync()` and `set_time_of_day()`.

- **Model.** `assets/models/people/Casual_Male.fbx`, already used by `on_foot_player.gd`, with clips `CharacterArmature|Idle`, `|Walk` and `|Run`.
  - It is instanced visual-only, scaled to about 1.7 world units (houses are 4.5 wide).
  - A per-household tint is applied as `material_override` or a shared tinted material per household colour.
  - Walk while moving, idle while working or loitering. Playback speed follows walk speed.
- **Pooling.** Villager nodes are pooled by key. A roster change adds and removes the difference and never rebuilds the crowd.
- **Budget.** Starting populations are about 80 (small), 120 (mining) and 192 (large village; 4 per household). Plan for about 300 skinned characters. Measure with the large village first.
  - If frame time suffers: drop animation (pose only) beyond a camera-zoom threshold.
  - Then hide children when zoomed out.
  - Last resort: a `MultiMeshInstance3D` capsule impostor at far zoom.
  - Decide from the measurement, not ahead of it.
- **Labels and selection.** No villager labels, matching houses. Clicking a villager selects it. The info panel shows its household, home and employer and links to business details through the existing `details_requested` signal. Site clicks keep priority when the click lands on a footprint with no villager under it.
- **House panel.** It shows occupants from `occupant_household_ids` instead of the generic "Shelters one household".

Checks:

- Extend `check_town_view.gd`. The villager count matches the roster headcount (housed plus homeless). Everyone is hidden at midnight. Nodes are reused across a tick.
- Extend `capture_town_view.gd` with captures at 07:00 (commute) and 12:00 (work), at default zoom.

## Delivery slices

Each slice is its own PR against `master`:

1. **House assignment in the sim:** `dwelling_id`, `_reconcile_housing`, homeless via assignment, reports, `check_housing_assignment.gd`, housing doc update. No visual change except the house info panel. Acceptance is matching `run_household_economy` totals.
2. **Road paths:** `he_town_paths.gd` plus its check. There is no visual change, but a debug toggle can draw a sample path.
3. **Schedule:** `he_villager_schedule.gd` plus its check, pure data.
4. **Villagers on screen:** `he_villagers.gd`, model, tint, animation, pooling, view and capture checks, performance pass on the large village.
5. **Polish:** villager selection and info, homeless camp at the plaza, house occupants panel, evening market stop.

Slices 1–3 are independent and can be built in parallel. Slice 4 needs all three.

## Questions to settle

1. **One model for everyone?** The repo has only `Casual_Male.fbx`. Proposed: use it for all villagers with per-household tints and child scale now, and add a female or child model later if one is sourced.
2. **Should children walk around?** Proposed: yes, they stay near home or the plaza. That roughly doubles the visible crowd.
3. **Where do split-off households live?** Proposed: the innermost free house (simple, deterministic). Alternative: the free house nearest the parent's house, so families cluster. This could be the first step toward the household compounds noted as open in the town view plan.
4. **Inside or outside at work?** Proposed: workers at town businesses (trader, bloomery and similar) go inside. Field, pasture and woodlot workers stay visible.

## Current-code anchors

- `scripts/sim/household_economy/he_simulation.gd`: `_homeless_household_ids`, `_housing_status_of`, `add_dwelling`, `_daily_tick`, `_write_off_and_remove_households`, `_split_off_new_household`, `get_household_summary`, `get_dwelling_reports`
- `scripts/sim/household_economy/records/he_household.gd`: `employer_business_id`, `_worker_ages`, `_dependent_ages`, `AGING_THRESHOLD_DAYS`
- `scripts/sim/household_economy/records/he_house.gd`: `capacity_households`, `upgrade_to_dense`
- `scripts/sim/household_economy/he_town_layout.gd`: sites (`access`, `road_id`, `footprint`), `get_roads()`, `site_of_business`, `site_of_dwelling`
- `scripts/sim/household_economy/he_town_view.gd`: `sync()`, `set_time_of_day()`, selection and info panel
- `scripts/sim/household_economy/he_dashboard.gd`: `_advance_town_time`, `TOWN_TICK_PHASE`, the town view `sync` call sites
- `scripts/on_foot/on_foot_player.gd`: the `Casual_Male.fbx` instancing and animation clip names to reuse

## Implementation status (slice 2: road paths)

Done: `scripts/sim/household_economy/he_town_paths.gd` (`HETownPaths`, `RefCounted`) with `scripts/sim/harness/check_town_paths.gd`.

- `HETownPaths.new(layout: HETownLayout)`
- `path(from_site_id, to_site_id) -> PackedVector2Array`: door, road graph vertices, door. Empty if a site is unknown or unreachable. Cached per pair; computed in canonical order (lower id first) so a return trip is the exact reverse. Collinear vertices are dropped so a route is unchanged when unrelated sites are inserted into its road segments.
- `refresh() -> bool`: rebuilds the graph and clears the cache when `layout.revision` changed. `path()` calls it automatically.
- `static path_length(points) -> float`.
- Off-road sites remember their road attach point, so later lanes never reroute them. The road graph is a tree (lanes are dead-end branches), so existing routes survive road growth.
