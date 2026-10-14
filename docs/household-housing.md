# Household economy: housing (simulation side)

## Rules

- A **house** (`HEHouse`, `type_key == "house"`) is a building, not a business: no workers, recipe, stock or balance. One house shelters one household (`capacity_households = 1`).
- Housing is a **settlement-wide pool**. Households are not assigned to a specific house (`TODO(housing-assignment)`).
- Only the **government** builds houses ("Government build" menu): 15 gold from the treasury + 50 timber from the Government Warehouse. It is blocked with `"needs a government warehouse"` until a warehouse exists, then by treasury / warehouse stock. Houses are repeatable; businesses and the warehouse stay unique.
- When no house is free (`households >= capacity`) every household's monthly **birth chance is scaled by 0.2** (`HESimulation.HOUSING_SATURATED_BIRTH_SCALE`). Coming-of-age splits are not blocked.
- Households past capacity (newest ids first) are **homeless**: each loses a member with `HOMELESS_EMIGRATION_CHANCE` (0.3) per monthly emigration pass (event `emigrate`, `cause: "homeless"`).
- A household with more than 4 adults (workers + dependents past the aging threshold) gives each extra adult 3x the monthly leave-home chance (`CROWDED_ADULT_COUNT`, `CROWDED_LEAVE_MULTIPLIER`).
- Seeded housing comes from the starting-town spec (`data/he_presets.gd`: `housing.houses`, and `housing.tenements` that start already densified): small village 24 houses for 20 households, mining village 36 for 30, large village 56 for 48 (already past `DENSIFY_HOUSE_COUNT`, so its first housing build is a tenement upgrade, and it starts with a Government Warehouse holding timber). Without an explicit count a town gets one house per household plus 35% (`HOUSING_STARTING_HEADROOM`). A world dict without a `"dwellings"` key is unlimited (`HESettlement.housing_modeled == false`).
- **Starting towns are specs.** The setup page offers Small / Mining / Large village (`HEPresets`) and a Custom roster (household count + business checkboxes, built with `HEPresets.custom_spec` and the spec's `include` list); each is a JSON-able dictionary (households, crews, housing, treasury bonus, warehouse stock, `format` version) and `HEScenarioSeeds.build_from_spec` builds the world. This is the new-game / save format to grow. The old hand-authored scenarios and the custom roster picker live only in `scripts/sim/harness/he_fixtures.gd` as test fixtures.
- **Tenement** (`HEHouse.DENSE_TYPE_KEY`, `capacity_households = 4`, government build menu): building one **upgrades the lowest-id plain house in place** (+3 capacity, no new lot, site never moves); only when every house is already dense does it add a new lot. Pricing follows the house rate (15 gold + 50 timber) per household gained: an upgrade (+3) costs 45 gold + 150 timber (`TENEMENT_UPGRADE_*`, the option's `upgrade_cost`), a new tenement (+4) 60 gold + 200 timber (`TENEMENT_BUILD_*`, `cost`). Always read a build's price through `HESimulation.build_cost_for(settlement_id, option)`, which picks the upgrade price while a plain house is left. `get_housing_report()` gains `upgradable_houses`.
- The dashboard Build button switches from House to the tenement upgrade when `HETownLayout.prefers_densify()` (roads had to grow, a house went unplaced, or 48+ houses stand) and a plain house is left, so the town densifies instead of growing outward. Art is a placeholder (`building_tavern_blue`); footprint stays 6x6.
- Pressing Build on a goods-priced item that lacks warehouse goods (with a warehouse and enough treasury gold) sets a standing warehouse buy order for the missing goods up to the build's cost (`HESimulation.request_government_build`, state via `build_goods_order_state`: `none` / `can_order` / `ordered`). The order stays standing, so the warehouse keeps restocking for the next build. The player presses again once the goods arrive (the warehouse buys up to `WAREHOUSE_DAILY_TRADE_CAP` a day, within its wage reserve).

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
- Houses (`ZONE_HOUSING`, 6x6 footprints) take lots along the road frontage, nearest the civic anchor first, rotated to face the road; the site records its `road_id`. The road network (`get_roads()`: spokes from the civic anchor plus lanes) is seeded at construction and only grows: when no lot is left, `_grow_roads()` adds lanes that avoid existing sites. Town-zone businesses front the spokes out to `MAIN_STREET_RADIUS` (houses start beyond it); field and pasture businesses keep their spiral candidates but clear the roads. Footprints can now be rotated by any yaw, so `site_rect()` is the axis-aligned bounds and `site_contains()` the exact test. Houses without room are counted with unplaced businesses (`unplaced_dwelling_ids()`).
- Art: `building_home_A_blue` / `building_home_B_blue`, alternating by site id. House labels are hidden (selection shows "Shelters one household." plus the housing line); a housing readout sits in the view's top right (`HETownView.housing_text`).
- Harness: `check_town_layout.gd` and `check_town_view.gd` cover houses.

## Still open
- Houses are not assigned to households (pooled capacity).
- No construction jobs or construction business yet; builds are instant (TODO in `HEScenarioSeeds.government_buildings()`).
- Bootstrapping a new town's timber (seeded warehouse stock, a timber tax on woodlots) is undecided.
