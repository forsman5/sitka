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
const HENeed = preload("res://scripts/sim/household_economy/records/he_need.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")

const SEED := 12345

var _ok := true

func _init() -> void:
	_check_house_flags()
	_check_upgrade_in_place()
	_check_refused_without_plain_house()
	_check_heat_saving()
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

## A stone house keeps its household 25% warmer for the same fuel, whoever lives
## in it: the household's daily heat requirement drops by HEHouse.STONE_HEAT_SAVING.
func _check_heat_saving() -> void:
	var plain := HEHouse.new(1, 1)
	_assert(is_equal_approx(plain.heat_factor(), 1.0), "A plain house saves no heat")
	plain.upgrade_to_stone()
	_assert(is_equal_approx(plain.heat_factor(), 1.0 - HEHouse.STONE_HEAT_SAVING), "A stone house saves a quarter of the heat")

	var sim := _sim()
	var sid := HEScenarioSeeds.SETTLEMENT_ID
	sim.advance_ticks(2)
	var heat := HENeeds.get_need(HENeed.Id.HEAT)
	var resident: HEHousehold = null
	for household in sim.households.values():
		if household.dwelling_id != -1 and (sim.dwellings[household.dwelling_id] as HEHouse).is_plain():
			resident = household
			break
	_assert(resident != null, "A household lives in a plain house")
	var plain_ratio := float(resident.last_need_required[HENeed.Id.HEAT]) / (float(resident.headcount()) * heat.per_person_daily)
	_assert(is_equal_approx(plain_ratio, 1.0), "In a plain house heat is the full per-person figure (%.3f)" % plain_ratio)
	(sim.dwellings[resident.dwelling_id] as HEHouse).upgrade_to_stone()
	sim._reconcile_housing(sid)
	_assert(is_equal_approx(resident.home_heat_factor, 0.75), "The resident's heat factor follows the house")
	sim.advance_ticks(1)
	var stone_ratio := float(resident.last_need_required[HENeed.Id.HEAT]) / (float(resident.headcount()) * heat.per_person_daily)
	_assert(is_equal_approx(stone_ratio, 0.75), "In a stone house heat is 25%% lower (%.3f)" % stone_ratio)
	# The Needs page shows the saving beside the goods that met the need.
	var detail := sim.get_need_detail(HENeed.Id.HEAT, 5, sid)
	var expected_saving := float(resident.headcount()) * heat.per_person_daily * HEHouse.STONE_HEAT_SAVING
	_assert(float(detail["saved"]) >= expected_saving - 0.0001, "The heat need detail reports the saving (%.3f >= %.3f)" % [float(detail["saved"]), expected_saving])
	_assert((detail["saved_history"] as Array).size() > 0 and float((detail["saved_history"] as Array).back()) >= expected_saving - 0.0001, "and keeps a history of it")
	var summary := sim.get_household_summary(resident.id)
	for need in summary["needs"]:
		if need["label"] == "Heat":
			_assert(is_equal_approx(float(need["required"]) / float(resident.headcount()), heat.per_person_daily * 0.75), "The household page shows the lower requirement")

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
	_assert(not sim.build_government_building(sid, "stone_house"), "The upgrade is refused with no plain house left")
	_assert(sim.build_government_building(sid, "stone_house_new"), "A new stone house still builds")
	_assert(sim.dwellings.size() == count + 1, "A new stone house adds a dwelling")
	var newest: HEHouse = sim.dwellings[sim.dwellings.keys().max()]
	_assert(newest.is_stone, "The new dwelling is stone")
