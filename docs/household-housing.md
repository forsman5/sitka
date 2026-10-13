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

## Handoff prompt for the town view author

> The household economy sim now has housing (see `docs/household-housing.md` on this branch). Houses are `HEHouse` buildings in `HESimulation.dwellings`, a separate id space from `businesses`, so the town layout can no longer assume every occupant is a business id. Please: (1) extend `HETownLayout` sites to accept an occupant keyed by `(type_key, id)` -- or add a parallel dwelling occupant -- and allocate residential sites outside the civic anchor and farm zones; seeded towns start with ~41 houses, so plan for a dense residential zone and the "unplaced" counter; (2) add a house art mapping in `he_town_view.gd` (the blue `home_A/B` models are free now that farms/woodlots may get their own); (3) reconcile layout against `dwellings` after `build_government_building(..., "house")` the same way it reconciles businesses, and never vacate a house site (houses do not fail); (4) show `get_housing_report()` (houses / capacity / homeless) in the town view and dashboard, and surface the "needs a government warehouse" blocker text in the Government build menu (already automatic via `government_build_blocker`); (5) update `check_town_layout.gd` / `check_town_view.gd`, which will break on dwellings. `get_business_reports()` is unchanged, and houses never appear in it.
