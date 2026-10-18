extends SceneTree

## House-upkeep acceptance check. Run with:
##   godot --headless --path . --script res://scripts/sim/harness/check_house_maintenance.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HEHouse = preload("res://scripts/sim/household_economy/records/he_house.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")
const HETownPaths = preload("res://scripts/sim/household_economy/he_town_paths.gd")
const HEVillagerSchedule = preload("res://scripts/sim/household_economy/he_villager_schedule.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SEED := 4242
const SID := HEScenarioSeeds.SETTLEMENT_ID

var _ok := true

func _init() -> void:
	_check_costs()
	_check_healthy_town()
	_check_stone_house_needs_stone()
	_check_round_robin()
	_check_shortage_and_morale()
	_check_schedule()
	print("HOUSE MAINTENANCE %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)

func _sim(preset: String) -> HESimulation:
	return HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_preset").bind(preset))

func _warehouse(sim: HESimulation) -> HEBusiness:
	for business in sim.businesses.values():
		if (business as HEBusiness).kind == HEBusiness.Kind.WAREHOUSE:
			return business
	return null

func _check_costs() -> void:
	var house := HEHouse.new(1, SID)
	_assert(is_equal_approx(house.upkeep_timber(), 0.2) and house.upkeep_stone() == 0.0, "a house takes 0.2 timber a year")
	var stone_house := HEHouse.new(2, SID)
	stone_house.upgrade_to_stone()
	_assert(is_equal_approx(stone_house.upkeep_timber(), 0.2) and is_equal_approx(stone_house.upkeep_stone(), 0.4), "a stone house takes 0.2 timber and 0.4 stone a year")
	house.upgrade_to_dense()
	_assert(is_equal_approx(house.upkeep_timber(), 0.8) and is_equal_approx(house.upkeep_stone(), 0.8), "a tenement takes 0.8 timber and 0.8 stone")
	var household := HEHousehold.new(1, 2, 0, 0.0, SID)
	household.home_overdue_years = 1.0
	_assert(is_equal_approx(_disrepair_penalty(household), 0.04), "one overdue year costs 4 points")
	household.home_overdue_years = 10.0
	_assert(is_equal_approx(_disrepair_penalty(household), 0.2), "the penalty is capped at 20 points")

func _disrepair_penalty(household: HEHousehold) -> float:
	for entry in household.morale_penalties():
		if entry["label"] == "Home in disrepair":
			return float(entry["penalty"])
	return 0.0

func _check_healthy_town() -> void:
	var sim := _sim("small_village")
	sim.advance_ticks(400)
	var summary := sim.get_house_maintenance_summary(SID)
	_assert(int(summary["houses"]) > 0, "the town has houses")
	_assert(int(summary["overdue"]) == 0, "a staffed, stocked town keeps every house current (%d overdue)" % int(summary["overdue"]))
	for household in sim.households.values():
		_assert((household as HEHousehold).home_overdue_years == 0.0, "no household carries a disrepair penalty")

## A stone house is repaired with stone: with the warehouse out of stone it
## falls behind while plain houses (timber only) stay current.
func _check_stone_house_needs_stone() -> void:
	var sim := _sim("small_village")
	sim.advance_ticks(2)
	var stone_id := -1
	var plain_id := -1
	for dwelling_id in sim.dwellings:
		var house: HEHouse = sim.dwellings[dwelling_id]
		if house.is_plain():
			if stone_id == -1:
				stone_id = dwelling_id
			elif plain_id == -1:
				plain_id = dwelling_id
	_assert(stone_id != -1 and plain_id != -1, "the town has plain houses to compare")
	(sim.dwellings[stone_id] as HEHouse).upgrade_to_stone()
	var warehouse := _warehouse(sim)
	for day in 500:
		warehouse.consume(Commodity.Type.STONE, warehouse.stock(Commodity.Type.STONE))
		sim.advance_ticks(1)
	var stone_house: HEHouse = sim.dwellings[stone_id]
	var plain_house: HEHouse = sim.dwellings[plain_id]
	_assert(stone_house.neglect_years > 1.0, "a stone house without stone falls behind (%.2f years)" % stone_house.neglect_years)
	_assert(plain_house.neglect_years < HESimulation.HOUSE_VISIT_YEARS + 0.1, "a plain house is still kept up (%.2f years)" % plain_house.neglect_years)
	# Stone arrives: the stone house is repaired again.
	warehouse.add_stock(Commodity.Type.STONE, 100.0)
	var before := stone_house.neglect_years
	sim.advance_ticks(200)
	_assert(stone_house.neglect_years < before, "with stone back the backlog falls (%.2f -> %.2f)" % [before, stone_house.neglect_years])

func _check_round_robin() -> void:
	var sim := _sim("small_village")
	sim.advance_ticks(2)
	var warehouse := _warehouse(sim)
	# Starve the warehouse of timber and let the backlog build up for most of a year.
	warehouse.consume(Commodity.Type.TIMBER, warehouse.stock(Commodity.Type.TIMBER))
	for day in 200:
		warehouse.consume(Commodity.Type.TIMBER, warehouse.stock(Commodity.Type.TIMBER))
		sim.advance_ticks(1)
	var before := sim.get_house_maintenance_summary(SID)
	_assert(int(before["overdue"]) > 0, "without timber houses fall overdue")
	# A trickle of timber: enough for only a few visits a day.
	var visited := {}
	for day in 60:
		warehouse.add_stock(Commodity.Type.TIMBER, 0.2)
		sim.advance_ticks(1)
		for dwelling_id in sim.get_house_deliveries(SID):
			visited[dwelling_id] = int(visited.get(dwelling_id, 0)) + 1
	_assert(visited.size() > 1, "scarce timber is spread over several houses (%d visited)" % visited.size())
	var most := 0
	var least := 1000
	for count in visited.values():
		most = maxi(most, count)
		least = mini(least, count)
	_assert(most - least <= 1, "round robin keeps visits even (%d..%d)" % [least, most])

func _check_shortage_and_morale() -> void:
	var sim := _sim("small_village")
	var warehouse := _warehouse(sim)
	for day in 500:
		warehouse.consume(Commodity.Type.TIMBER, warehouse.stock(Commodity.Type.TIMBER))
		sim.advance_ticks(1)
	var housed: HEHousehold = null
	for household in sim.households.values():
		if (household as HEHousehold).dwelling_id != -1:
			housed = household
			break
	_assert(housed != null, "someone is housed")
	_assert(housed.home_overdue_years > 0.5, "a long shortage builds an overdue backlog (%.2f years)" % housed.home_overdue_years)
	var penalty := _disrepair_penalty(housed)
	_assert(penalty > 0.0, "the household's morale shows 'Home in disrepair'")
	# Timber returns: the backlog is paid down and the penalty falls.
	warehouse.add_stock(Commodity.Type.TIMBER, 500.0)
	warehouse.add_stock(Commodity.Type.STONE, 500.0)
	sim.advance_ticks(5)
	_assert(_disrepair_penalty(housed) < penalty, "paying the backlog down eases the penalty")
	sim.advance_ticks(60)
	_assert(int(sim.get_house_maintenance_summary(SID)["overdue"]) == 0, "the backlog clears once timber is back")

func _check_schedule() -> void:
	var builder := Callable(HEScenarioSeeds, "build_preset").bind("large_village")
	var sim := HESimulation.new(SEED, builder)
	sim.advance_ticks(20)
	var layout := HETownLayout.new(HETownLayout.scenario_key_for(builder), SID, sim.get_business_reports(), sim.get_dwelling_reports())
	layout.reconcile(sim.get_business_reports(), sim.get_dwelling_reports(), sim.get_construction_reports())
	var paths := HETownPaths.new(layout)
	var government := layout.site_of_business(_government_id(sim))
	var home := layout.site_of_dwelling(layout.get_sites().filter(func(s): return s["dwelling_id"] != -1)[0]["dwelling_id"])
	var errands := [home]
	var plain := HEVillagerSchedule.plan(Vector2i(1, 1), HEVillagerSchedule.ROLE_EMPLOYED, 5, home, government, paths)
	var round := HEVillagerSchedule.plan(Vector2i(1, 1), HEVillagerSchedule.ROLE_EMPLOYED, 5, home, government, paths, [], errands)
	var acts := {}
	for seg in round["segs"]:
		acts[seg["act"]] = true
	for seg in plain["segs"]:
		_assert(seg["act"] != "deliver_upkeep", "no errands, no delivery stop")
	_assert(acts.has("deliver_upkeep") and acts.has("walk_errand"), "a government worker with errands walks out and delivers")
	var last: Dictionary = round["segs"][round["segs"].size() - 1]
	_assert(float(last["t1"]) == HEVillagerSchedule.DAY_END, "the day still ends at DAY_END")

func _government_id(sim: HESimulation) -> int:
	for business in sim.businesses.values():
		if (business as HEBusiness).kind == HEBusiness.Kind.GOVERNMENT:
			return (business as HEBusiness).id
	return -1
