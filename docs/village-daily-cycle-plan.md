# Household economy town view: daily village cycle

## Direction

Fill the Town view with little villagers who live the day the simulation just computed. Each household member is a visible villager. They wake at their house, walk the roads to the business that employs them, work, come home, and disappear indoors at night.

The groundwork this builds on:

- **Clock.** The Town view runs its own clock (`he_dashboard.gd:_advance_town_time`, `GameState.town_day_seconds`), and the lighting follows it (`HETownView.set_time_of_day`). The sim ticks once per visual day at `TOWN_TICK_PHASE` (05:30), before villagers are awake. So roster changes from a tick (jobs, births, departures, new houses) happen while everyone is indoors.
- **Jobs.** `HEHousehold.employer_business_id`. A household works as one unit for one employer, and `HETownLayout.site_of_business()` gives the workplace.
- **Layout.** Houses and businesses are layout sites with an `access` point on a road. Roads only grow, and sites never move.

Rule kept from the town view plan: the simulation owns economic truth, the layout owns positions, and the view only renders. Villager motion is cosmetic and never feeds back into the economy.

## Phases

### Done (PR #87)

**Houses assigned (sim).**
- `HEHousehold.dwelling_id` is written only by `HESimulation._reconcile_housing`. It runs:
  - at sim start;
  - at the end of every tick;
  - in `add_dwelling`;
  - in `_finish_due_constructions`, after a tenement upgrade.
- A household keeps its house for life. Unhoused households take the lowest-id house with room, so the town fills from the centre out.
- Homeless means `dwelling_id == -1`. It is the same set and the same counts as the old pooled rule; `run_household_economy.gd` output was byte-identical.
- Reports:
  - `get_household_summary()["dwelling_id"]`;
  - `get_dwelling_reports()` entries carry `capacity` and `occupant_household_ids`;
  - `get_villager_reports(settlement_id)` is the cheap per-household roster, with house, employer, status and ages.
- The full rules are in `docs/household-housing.md`.

**Villager identity.**
- A villager is `(household_id, member_number)`: 1-based, workers first, the same numbering as the dashboard's person page.
- Members have no persistent ids. When one leaves, later members shift down a number.
- Looks:
  - body model, male or female, seeded per villager;
  - skin tone seeded per household;
  - children at 0.6 scale.

**Road paths (from #88).** `he_town_paths.gd` (`HETownPaths`) is a pure-data route graph over the road polylines and every site's door and access point.
- `path(from_site, to_site)` returns door → road → door, cached, with return trips reversed.
- `refresh()` follows `layout.revision` and keeps cached routes, because routes stay valid as the town grows.
- It is not used yet.

**Villagers on screen.** `he_villagers.gd`, owned by `HETownView`.
- One visual-only `Casual_Male`/`Casual_Female` per person, milling about in the front yard of their own house. Homeless villagers mill at the plaza edge, and housemates spread out.
- They are frozen while paused or while the Town view is hidden.
- Clicking a villager opens a person window:
  - household and member, role and age, employer, household size, home;
  - **Show home** selects the house and centres the camera on it;
  - **Person details** opens the dashboard person page.
- The house panel lists its households.

**Performance.**
- Animations advance by hand: at most 64 a frame, only on screen, and none zoomed out past ortho size 50.
- Villagers cast no shadows.
- Skin materials are shared per tone.
- Results at 120 households (480 villagers, whole town in view):

  | Build | Before | After |
  |---|---|---|
  | Browser | 125 ms | 17 ms |
  | Desktop | 27 ms | 8.5 ms |

- Measure with `perf_town_villagers.gd` on desktop, or with `scenes/sim/perf_town_villagers.tscn` as the main scene of a web export.

**Checks.**
- `check_housing_assignment.gd`.
- `check_town_paths.gd`.
- `check_town_view.gd`: villagers, picking, person window, Show home, Person details, both models.
- `capture_town_view.gd` takes `--villager`, `--zoom` and `--tilt`.

### Remaining

**1. Indoors at night.**
- New `he_villager_schedule.gd`. A villager's state comes straight from `(key, sim day, time of day, roster)`, with no stored state, so pause, speed changes and fast-forward cannot drift it.
- Housed villagers go inside between about 21:00 and 05:30, each with seeded jitter, and reappear at their door in the morning.
- Homeless villagers stay visible at the plaza overnight, so homelessness shows on the map.
- Uses the existing clock. No routing yet.

**2. Commuting.** Morning and evening walks along `HETownPaths`:

| Time | Employed adult | Unemployed adult | Child |
|------|----------------|------------------|-------|
| 06:00–08:00 | Door → workplace | Door → plaza | Plays near home |
| 17:00–19:30 | Workplace → home (some via the trader/plaza) | Plaza → home | Heads home |

- Each leg's duration fits its window. Speed is path length ÷ duration, capped, so a long commute leaves earlier instead of sprinting.
- `town_day_seconds` only changes real-time speed, never the route.

**3. Work.**
- Field, pasture and woodlot workers wander slowly inside the footprint from a seeded spot.
- Town-business workers go inside (hidden) with brief trips to the door.
- Unemployed adults loiter at the plaza.
- Check: at noon, every employed worker is inside their employer's footprint.

**4. Zoomed-out detail (#93).** Drawing 480 full skinned models is most of what's left (about 7 ms in the browser). Past a zoom threshold, swap to a low-detail mesh or a batched stand-in.

**5. Polish.**
- Evening market stop.
- A visible homeless camp at the plaza.
- Persistent member ids, replacing the `last_promoted_member_numbers` placeholder, so a villager keeps its identity when a housemate leaves.

## Questions to settle

Settled in #87:
- **Models:** male and female bodies picked by seed, skin tone per household, adult models scaled down for children.
- **Children:** yes, they are drawn and mill about with their household.
- **Performance budget:** 64 animation updates a frame, no animation past zoom 50, no villager shadows.

Still open:
1. **Where do split-off households live?** Today it's the innermost free house. The alternative is the free house nearest the parents, so families cluster: a first step toward household compounds.
2. **Inside or outside at work?** Proposed: town-business workers go inside, while field, pasture and woodlot workers stay visible.
3. **Should the night rule come before commuting?** Proposed: yes, as phase 1 above. It is small, and villagers standing outside all night is the most visible gap.

## Current-code anchors

- `scripts/sim/household_economy/he_simulation.gd`: `_reconcile_housing`, `get_villager_reports`, `get_dwelling_reports`, `_finish_due_constructions`
- `scripts/sim/household_economy/he_villagers.gd`: roster sync, milling, picking, animation budget
- `scripts/sim/household_economy/he_town_paths.gd`: route graph (`path`, `refresh`, `path_length`)
- `scripts/sim/household_economy/he_town_view.gd`: `sync()`, person window, `select_villager`, `focus_on`
- `scripts/sim/household_economy/he_dashboard.gd`: `_advance_town_time`, `TOWN_TICK_PHASE`, the Town view refresh group
- `scripts/sim/harness/perf_town_villagers.gd`, `perf_town_villagers_runner.gd`: frame-time measurement
- `assets/models/people/Casual_Male.fbx`, `Casual_Female.fbx`: villager models (`CharacterArmature|Idle`/`Walk`)
