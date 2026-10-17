extends SceneTree

## Headless check of the stone house upgrade:
##   godot --headless --path . --script res://scripts/sim/harness/check_stone_house.gd
## A stone house upgrades a plain house in place, keeps its capacity, and lifts
## the morale of the household living in it by HEHouse.STONE_MORALE_BONUS.

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEPresets = preload("res://scripts/sim/household_economy/data/he_presets.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEHouse = preload("res://scripts/sim/household_economy/records/he_house.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")

const SEED := 12345

var _ok := true

func _init() -> void:
	_check_house_flags()
	_check_upgrade_in_place()
	_check_refused_without_plain_house()
	print("STONE HOUSE %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_ok = false

func _check_house_flags() -> void:
	var house := HEHouse.new(1, 1)
	_assert(house.is_plain() and house.morale_bonus() == 0.0, "A new house is plain with no bonus")
	house.upgrade_to_stone()
	_assert(house.is_stone and not house.is_plain() and not house.is_dense(), "A stone house is neither plain nor dense")
	_assert(house.capacity_households == 1 and is_equal_approx(house.morale_bonus(), HEHouse.STONE_MORALE_BONUS), "Stone keeps capacity 1 and gives the bonus")

func _sim() -> HESimulation:
	var spec := HEPresets.spec("mining_village")
	var sim := HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_spec").bind(spec), true)
	sim.construction_days = 0
	return sim

func _fund(sim: HESimulation) -> void:
	var warehouse := sim._government_warehouse(HEScenarioSeeds.SETTLEMENT_ID)
	warehouse.add_stock(Commodity.Type.STONE, HEScenarioSeeds.STONE_HOUSE_STONE)
	warehouse.add_stock(Commodity.Type.TIMBER, HEScenarioSeeds.STONE_HOUSE_TIMBER)
	var gov: HEBusiness = sim.businesses[HEScenarioSeeds.GOVERNMENT_BUSINESS_ID]
	gov.balance += HEScenarioSeeds.STONE_HOUSE_GOLD + 100.0

func _check_upgrade_in_place() -> void:
	var sim := _sim()
	var sid := HEScenarioSeeds.SETTLEMENT_ID
	var houses_before := sim.dwellings.size()
	var target: HEHouse = sim._innermost_plain_house(sid)
	_assert(target != null, "The seeded town has a plain house")
	var resident: HEHousehold = null
	for household in sim.households.values():
		if household.dwelling_id == target.id:
			resident = household
	var morale_before := resident.morale() if resident != null else 0.0
	_fund(sim)
	_assert(sim.build_government_building(sid, "stone_house"), "A funded stone house builds")
	_assert(sim.dwellings.size() == houses_before, "The upgrade adds no new dwelling")
	_assert(target.is_stone and target.type_key == HEHouse.TYPE_KEY, "The innermost plain house became stone")
	for report in sim.get_dwelling_reports(sid):
		if report["dwelling_id"] == target.id:
			_assert(report["stone"], "The dwelling report flags it stone")
	if resident != null:
		_assert(is_equal_approx(resident.home_morale_bonus, HEHouse.STONE_MORALE_BONUS), "The resident's home bonus is set")
		var labels: Array = resident.morale_bonuses().map(func(b): return b["label"])
		_assert(labels.has("Stone house"), "The bonus is listed as 'Stone house'")
		_assert(resident.morale() > morale_before or morale_before >= HEHousehold.MORALE_MAX, "Morale rose")
	var next: HEHouse = sim._innermost_plain_house(sid)
	_assert(next == null or next.id != target.id, "The next upgrade targets a different house")

func _check_refused_without_plain_house() -> void:
	var sim := _sim()
	var sid := HEScenarioSeeds.SETTLEMENT_ID
	for house in sim.dwellings.values():
		house.upgrade_to_stone()
	_fund(sim)
	var count := sim.dwellings.size()
	var gov: HEBusiness = sim.businesses[HEScenarioSeeds.GOVERNMENT_BUSINESS_ID]
	var warehouse := sim._government_warehouse(sid)
	warehouse.add_stock(Commodity.Type.TIMBER, HEScenarioSeeds.STONE_HOUSE_BUILD_TIMBER)
	gov.balance += HEScenarioSeeds.STONE_HOUSE_BUILD_GOLD
	_assert(sim.build_government_building(sid, "stone_house"), "With no plain house left a stone house is built new")
	_assert(sim.dwellings.size() == count + 1, "A new stone house adds a dwelling")
	var newest: HEHouse = sim.dwellings[sim.dwellings.keys().max()]
	_assert(newest.is_stone, "The new dwelling is stone")
