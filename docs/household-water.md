# Household economy: water sources

## What it is

A town needs safe drinking water. The government builds **wells** and **river intakes** (`HEBusiness.Kind.WATER`), which employ no one and cost only a yearly servicing in timber. Villagers in the Town view stop at one on their way out each morning and fill up.

Water is **reporting only** for now: it changes no health, morale, price or wage, so every existing economic result is untouched. The hook for a real effect is `get_water_summary()["coverage"]`.

## Sim

- **Kinds.** `well` (40 people) and `river_intake` (100 people), tuned in `HEScenarioSeeds` (`WELL_PEOPLE`, `RIVER_INTAKE_PEOPLE`, build and upkeep constants).
  - Scope: 150-200 people want 4-5 wells or 2 river intakes. The Large village preset (48 households, 192 people) seeds 5 wells; the Small and Mining presets seed 2 and 3.
- **Building.** Both are in `government_buildings()` (so they show in the Government build menu), repeatable, paid in treasury gold plus Government Warehouse timber, like a house. A well is 10 g + 20 timber, a river intake 25 g + 40 timber.
- **No workers.** `capacity` and `max_capacity` are 0; the capacity tuner, wage pass and hiring skip the kind.
- **Servicing.** Every `WATER_SERVICE_INTERVAL_DAYS` (365) each source costs `water_upkeep_timber` and the same of `water_upkeep_stone` (well 4 + 4, intake 6 + 6) from the warehouse, done by existing government staff (the administrator or the warehouse crew). `_run_water_maintenance` runs daily after the warehouse orders. Seeded sources are first due at staggered days in the first year; a source built mid-run is due a year after it opens.
- **Neglect.** If the timber or the staff is missing the source is `in_disrepair` and supplies nobody until the next day it can be paid for.
- **Reports.** `get_business_reports()` adds `report["water"]` (people, serving, in_disrepair, upkeep_timber, upkeep_stone, days_to_service). `get_water_summary(settlement_id)` gives sources, serving, capacity, population, coverage, upkeep and the soonest servicing.
- **Spec.** A preset spec takes `"water": {"wells": n, "river_intakes": n}` (absent = none). Custom rosters get enough wells for 4-person households.

## Town view

- **Layout.** A water source is a 4 x 4 site on the housing streets, placed at the free lot farthest from the other sources and nearest a ring 52 from the civic anchor, so wells spread through the neighbourhoods (`HETownLayout._allocate_water_site`). They never vacate.
- **Model.** KayKit Medieval Hexagon Pack `building_well_blue` (`assets/models/buildings/`). There is no river in the town view, so a river intake is the same well drawn larger.
- **Villagers.** `HEVillagerSchedule.plan` takes the working water sources and adds a stop for housed villagers who walk out for the day (work or plaza): home to the source that costs the least extra walking, `FILL_HOURS` (0.15) standing there, then on to the destination. Sources farther than `WELL_MAX_DETOUR` (90) extra are skipped. The person window shows "Filling up at the water source". Children and the homeless do not stop yet.

## Checks and open items

- `scripts/sim/harness/check_water.gd`: preset coverage, yearly servicing, neglect and recovery, the government build, layout spread, and the schedule stop.
- Open: make coverage matter (health or morale, perhaps a morale lift when everyone is covered); an evening trip and a trip for children; a real river in the town view for intakes; per-household nearest-source assignment instead of town-wide coverage.
