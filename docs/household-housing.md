# Household economy: housing (simulation side)

## Rules

- A **house** (`HEHouse`, `type_key == "house"`) is a building, not a business: no workers, recipe, stock or balance. One house shelters one household (`capacity_households = 1`).
- Housing is a **settlement-wide pool**. Households are not assigned to a specific house (`TODO(housing-assignment)`).
- Only the **government** builds houses ("Government build" menu): 50 gold from the treasury + 50 timber from the Government Warehouse. It is blocked with `"needs a government warehouse"` until a warehouse exists, then by treasury / warehouse stock. Houses are repeatable; businesses and the warehouse stay unique.
- When no house is free (`households >= capacity`) every household's monthly **birth chance is scaled by 0.2** (`HESimulation.HOUSING_SATURATED_BIRTH_SCALE`). Coming-of-age splits are not blocked.
- Households past capacity (newest ids first) are **homeless**: each loses a member with `HOMELESS_EMIGRATION_CHANCE` (0.3) per monthly emigration pass (event `emigrate`, `cause: "homeless"`).
- A household with more than 4 adults (workers + dependents past the aging threshold) gives each extra adult 3x the monthly leave-home chance (`CROWDED_ADULT_COUNT`, `CROWDED_LEAVE_MULTIPLIER`).
- Seeded towns (all presets and custom rosters) get one house per starting household plus 35% (`HOUSING_STARTING_HEADROOM`): 41 houses for 30 households. A world dict without a `"dwellings"` key is unlimited (`HESettlement.housing_modeled == false`).
- Warehouse timber still arrives only via manual standing buy orders. TODO in `government_buildings()`: building a goods-priced item should create that order; and construction jobs / a construction business.

## API a UI needs

| What | Where |
|------|-------|
| `HEBuilding` base (`id`, `settlement_id`, `name`, `type_key`) | `records/he_building.gd`; `HEBusiness` and `HEHouse` extend it |
| Houses | `HESimulation.dwellings: Dictionary[int, HEHouse]` -- **separate id space from `businesses`**; key by `("house", id)` |
| Per-settlement ids | `HESettlement.dwelling_ids` |
| Housing summary | `HESimulation.get_housing_report(settlement_id)` -> `modeled, houses, capacity, households, homeless_households, saturated`; also `get_settlement_summary()["housing"]` |
| Build menu | `HEScenarioSeeds.government_buildings()` now has a `"house"` entry (`category: "housing"`, `repeatable: true`); `make` returns an `HEHouse`. `build_government_building(sid, "house")` / `government_build_blocker()` work as before |
| New house | `HESimulation.add_dwelling()`, `next_dwelling_id()` |

## Where housing shows up

**Dashboard** (`he_dashboard.gd`)
- Top bar: a second line under Health/Morale, `Housing  41 houses / 30 households`, yellow with "(full)" and red with "(N homeless)". "unlimited" when housing is not modeled.
- Housing tab (after Goods): large Houses / Households / Free houses / Homeless households readouts, the rules in one line, and a "Build house" button that reuses the government build path and shows the blocker (e.g. "needs a government warehouse").
- The Government build menu also lists House.

**Town view** (`he_town_layout.gd`, `he_town_view.gd`)
- Houses are a second occupant kind. A site holds a business (`business_id`) or a house (`dwelling_id`), never both; key an occupant by `(type_key, id)`. Houses never fail, so a house site is never vacated or reused.
- `HESimulation.get_dwelling_reports(settlement_id)` returns `{dwelling_id, settlement_id, name, type_key}` per house, ascending id; it is what the layout reconciles against (`HETownLayout.reconcile(reports, dwellings)`). `get_business_reports()` never includes houses.
- Houses are allocated in a residential zone (`ZONE_HOUSING`: a 9-unit lattice, 6x6 footprints, 30-74 units from the civic anchor), filled outward from a seeded point. Houses without room are counted with unplaced businesses (`unplaced_dwelling_ids()`).
- Art: `building_home_A_blue` / `building_home_B_blue`, alternating by site id. House labels are hidden (selection shows "Shelters one household." plus the housing line); a housing readout sits in the view's top right (`HETownView.housing_text`).
- Harness: `check_town_layout.gd` and `check_town_view.gd` cover houses.

## Still open
- Houses are not assigned to households (pooled capacity).
- Building a goods-priced item should create the warehouse buy order; there are no construction jobs or construction business yet (TODOs in `HEScenarioSeeds.government_buildings()`).
