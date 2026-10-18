extends SceneTree

## House-upkeep acceptance check. Run with:
##   godot --headless --path . --script res://scripts/sim/harness/check_house_maintenance.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")
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
	_check_households_buy_stone()
	_check_stone_shortage()
	_check_visits_reach_every_house()
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
	_assert(is_equal_approx(house.upkeep_timber(), 1.0) and house.upkeep_stone() == 0.0, "a house takes 1 timber a year")
	var stone_house := HEHouse.new(2, SID)
	stone_house.upgrade_to_stone()
	_assert(is_equal_approx(stone_house.upkeep_timber(), 4.0) and is_equal_approx(stone_house.upkeep_stone(), 10.0), "a stone house takes 4 timber and 10 stone a year")
	house.upgrade_to_dense()
	_assert(is_equal_approx(house.upkeep_timber(), 4.0) and is_equal_approx(house.upkeep_stone(), 4.0), "a tenement takes 4 timber and 4 stone, split between its households")
	var household := HEHousehold.new(1, 2, 0, 0.0, SID)
	household.home_upkeep_timber = 4.0
	household.home_upkeep_stone = 10.0
	_assert(is_equal_approx(household.upkeep_slice(Commodity.Type.TIMBER), 1.0) and is_equal_approx(household.upkeep_slice(Commodity.Type.STONE), 2.5), "a household holds a quarter of a year's goods for the next visit")
	_assert(household.upkeep_slice(Commodity.Type.GRAIN) == 0.0, "other goods are not part of upkeep")
	household.home_overdue_years = 1.0
	_assert(is_equal_approx(_disrepair_penalty(household), 0.04), "one overdue year costs 4 points")
	household.home_overdue_years = 10.0
	_assert(is_equal_approx(_disrepair_penalty(household), 0.2), "the penalty is capped at 20 points")
	household.home_morale_bonus = HEHouse.STONE_MORALE_BONUS
	household.home_overdue_years = 0.0
	_assert(_has_bonus(household, "Stone house"), "a stone house in repair lifts morale")
	household.home_overdue_years = 0.5
	_assert(not _has_bonus(household, "Stone house"), "a stone house in arrears does not")

func _has_bonus(household: HEHousehold, label: String) -> bool:
	for entry in household.morale_bonuses():
		if entry["label"] == label:
			return true
	return false

func _disrepair_penalty(household: HEHousehold) -> float:
	for entry in household.morale_penalties():
		if entry["label"] == "Home in disrepair":
			return float(entry["penalty"])
	return 0.0

func _check_healthy_town() -> void:
	var sim := _sim("small_village")
	var warehouse := _warehouse(sim)
	var warehouse_timber := warehouse.stock(Commodity.Type.TIMBER)
	var timber_traded := 0.0
	sim.advance_ticks(400)
	var summary := sim.get_house_maintenance_summary(SID)
	_assert(int(summary["houses"]) > 0, "the town has houses")
	_assert(int(summary["overdue"]) == 0, "a staffed town whose households can buy timber keeps every house current (%d overdue)" % int(summary["overdue"]))
	for household in sim.households.values():
		_assert((household as HEHousehold).home_overdue_years == 0.0, "no household carries a disrepair penalty")
	for record in sim.get_daily_history(400):
		timber_traded += float(record["traded_quantity"].get("Timber", 0.0))
	_assert(timber_traded > 0.0, "households buy timber on the market")
	# The warehouse no longer pays for dwellings: only wells and its own buy orders move its timber.
	_assert(warehouse.stock(Commodity.Type.TIMBER) >= warehouse_timber - 20.0, "house upkeep does not draw on the warehouse (%.1f -> %.1f)" % [warehouse_timber, warehouse.stock(Commodity.Type.TIMBER)])

## Households buy the repair goods themselves: stone houses put real demand on
## the stone market, which the Quarry sells into.
func _check_households_buy_stone() -> void:
	var sim := _sim("mining_village")
	sim.advance_ticks(2)
	var upgraded := 0
	for dwelling_id in sim.dwellings:
		var house: HEHouse = sim.dwellings[dwelling_id]
		if house.is_plain() and upgraded < 6:
			house.upgrade_to_stone()
			upgraded += 1
	sim._reconcile_housing(SID)
	var stone_traded := 0.0
	for day in 150:
		sim.advance_ticks(1)
	for record in sim.get_daily_history(150):
		stone_traded += float(record["traded_quantity"].get("Stone", 0.0))
	_assert(upgraded == 6, "six houses became stone")
	_assert(stone_traded > 0.0, "stone houses make households buy stone on the market (%.2f traded)" % stone_traded)
	var delivered := 0
	for record_day in 150:
		delivered += 0
	var summary := sim.get_house_maintenance_summary(SID)
	_assert(float(summary["upkeep_stone"]) >= 60.0, "six stone houses owe 60 stone a year (%.1f)" % float(summary["upkeep_stone"]))
	_assert(int(summary["overdue"]) == 0, "households that can buy stone keep their stone houses current (%d overdue)" % int(summary["overdue"]))
	# The stone came from households, not the warehouse's repair budget.
	var spenders := 0
	for household in sim.households.values():
		if (household as HEHousehold).home_upkeep_stone > 0.0:
			spenders += 1
	_assert(spenders >= 6, "the stone houses' households carry the stone bill (%d)" % spenders)

## With no stone to be had, a stone house falls behind and loses its morale
## bonus while plain houses (timber only) stay current; when stone is back it
## recovers.
func _check_stone_shortage() -> void:
	var sim := _sim("mining_village")
	sim.advance_ticks(2)
	var stone_id := -1
	for dwelling_id in sim.dwellings:
		if (sim.dwellings[dwelling_id] as HEHouse).is_plain():
			stone_id = dwelling_id
			break
	_assert(stone_id != -1, "the town has a plain house to upgrade")
	(sim.dwellings[stone_id] as HEHouse).upgrade_to_stone()
	sim._reconcile_housing(SID)
	# No quarry, and nobody holds stone.
	for business_id in sim.businesses.keys().duplicate():
		if (sim.businesses[business_id] as HEBusiness).type_key == "quarry":
			sim.businesses.erase(business_id)
			(sim.settlements[SID] as HESettlement).business_ids.erase(business_id)
	for business in sim.businesses.values():
		(business as HEBusiness).consume(Commodity.Type.STONE, (business as HEBusiness).stock(Commodity.Type.STONE))
	var resident: HEHousehold = null
	for household in sim.households.values():
		if (household as HEHousehold).dwelling_id == stone_id:
			resident = household
	_assert(resident != null, "a household lives in the stone house")
	sim.advance_ticks(500)
	var stone_house: HEHouse = sim.dwellings[stone_id]
	_assert(stone_house.neglect_years > 1.0, "a stone house with no stone to buy falls behind (%.2f years)" % stone_house.neglect_years)
	_assert(resident != null and resident.home_overdue_years > 0.5, "its household carries an overdue backlog")
	_assert(resident != null and _disrepair_penalty(resident) > 0.0, "and shows 'Home in disrepair'")
	_assert(resident != null and not _has_bonus(resident, "Stone house"), "and loses the stone house bonus")
	var overdue_plain := 0
	for dwelling_id in sim.dwellings:
		var house: HEHouse = sim.dwellings[dwelling_id]
		if dwelling_id != stone_id and house.neglect_years > HESimulation.HOUSE_VISIT_YEARS + 0.1:
			overdue_plain += 1
	_assert(overdue_plain == 0, "plain houses are still kept up (%d overdue)" % overdue_plain)
	# Stone arrives in the household's hands (a trader, a gift): the backlog clears.
	var before := stone_house.neglect_years
	for day in 150:
		resident.add_stock(Commodity.Type.STONE, 2.0)
		sim.advance_ticks(1)
	_assert(stone_house.neglect_years < before, "with stone back the backlog falls (%.2f -> %.2f)" % [before, stone_house.neglect_years])

## Staff visit every house that has been lived in throughout, within their daily budget.
func _check_visits_reach_every_house() -> void:
	var sim := _sim("small_village")
	sim.advance_ticks(2)
	var occupied_at_start := _occupied(sim)
	var visited := {}
	var busiest := 0
	for day in 200:
		sim.advance_ticks(1)
		busiest = maxi(busiest, sim.get_house_deliveries(SID).size())
		for dwelling_id in sim.get_house_deliveries(SID):
			visited[dwelling_id] = true
	var occupied_at_end := _occupied(sim)
	var always := 0
	var reached := 0
	for dwelling_id in occupied_at_start:
		if occupied_at_end.has(dwelling_id):
			always += 1
			if visited.has(dwelling_id):
				reached += 1
	_assert(always > 10, "enough houses stayed occupied (%d)" % always)
	_assert(reached == always, "every house lived in throughout was visited in 200 days (%d of %d)" % [reached, always])
	_assert(busiest >= 1, "staff made visits")

func _occupied(sim: HESimulation) -> Dictionary:
	var out := {}
	for household in sim.households.values():
		if (household as HEHousehold).dwelling_id != -1:
			out[(household as HEHousehold).dwelling_id] = true
	return out

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
