extends SceneTree

## House assignment acceptance check (no scene needed). Run with:
##   godot --headless --script res://scripts/sim/harness/check_housing_assignment.gd
## Every household lives in one house (HEHousehold.dwelling_id); see
## HESimulation._reconcile_housing for the rules.

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEFixtures = preload("res://scripts/sim/harness/he_fixtures.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SEED := 4242
const SID := HEScenarioSeeds.SETTLEMENT_ID

var _ok := true

func _init() -> void:
	_check_presets_start_housed()
	_check_assignment_is_sticky()
	_check_freed_slot_is_refilled()
	_check_new_house_and_upgrade_fill_at_once()
	_check_homeless_follow_assignment()
	_check_unmodeled_housing()
	_check_reports()
	print("HOUSING ASSIGNMENT %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)

func _preset(key: String) -> HESimulation:
	return HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_preset").bind(key))

func _assignments(sim: HESimulation) -> Dictionary:
	var out := {}
	for household_id in sim.get_household_ids(SID):
		out[household_id] = (sim.households[household_id] as HEHousehold).dwelling_id
	return out

## No house holds more households than it shelters, every assignment points
## at a house of the same settlement, and housed + homeless add up.
func _check_invariants(sim: HESimulation, label: String) -> void:
	var occupancy := {}
	for household_id in sim.get_household_ids(SID):
		var dwelling_id: int = (sim.households[household_id] as HEHousehold).dwelling_id
		if dwelling_id == -1:
			continue
		_assert(sim.dwellings.has(dwelling_id) and (sim.settlements[SID] as HESettlement).dwelling_ids.has(dwelling_id), "%s: household %d points at a house of its settlement" % [label, household_id])
		occupancy[dwelling_id] = int(occupancy.get(dwelling_id, 0)) + 1
	for dwelling_id in occupancy:
		_assert(occupancy[dwelling_id] <= (sim.dwellings[dwelling_id] as HEHouse).capacity_households, "%s: house %d is not over capacity" % [label, dwelling_id])
	var housing := sim.get_housing_report(SID)
	var housed := 0
	for dwelling_id in occupancy:
		housed += int(occupancy[dwelling_id])
	_assert(housed + int(housing["homeless_households"]) == int(housing["households"]), "%s: housed (%d) + homeless (%d) == households (%d)" % [label, housed, housing["homeless_households"], housing["households"]])

func _check_presets_start_housed() -> void:
	for key in ["small_village", "mining_village", "large_village"]:
		var sim := _preset(key)
		_check_invariants(sim, key)
		for household_id in sim.get_household_ids(SID):
			_assert((sim.households[household_id] as HEHousehold).dwelling_id != -1, "%s: household %d starts housed" % [key, household_id])
		# Innermost first: the lowest-id house is taken.
		var houses: Array = (sim.settlements[SID] as HESettlement).dwelling_ids.duplicate()
		houses.sort()
		var first: int = (sim.households[sim.get_household_ids(SID)[0]] as HEHousehold).dwelling_id
		_assert(first == houses[0], "%s: the first household lives in the innermost house" % key)

func _check_assignment_is_sticky() -> void:
	var sim := _preset("small_village")
	var before := _assignments(sim)
	for month in 24:
		sim.advance_ticks(30)
		_check_invariants(sim, "small_village month %d" % month)
	var after := _assignments(sim)
	var survivors := 0
	for household_id in before:
		if after.has(household_id) and before[household_id] != -1:
			survivors += 1
			_assert(after[household_id] == before[household_id], "Household %d kept its house (%d -> %d)" % [household_id, before[household_id], after[household_id]])
	_assert(survivors > 0, "Some starting households survive two years")

func _check_freed_slot_is_refilled() -> void:
	var sim := HESimulation.new(SEED, Callable(HEFixtures, "build_three_business_economy"))
	var s: HESettlement = sim.settlements[SID]
	# Fill every house, then make one more household homeless.
	while sim.get_housing_report(SID)["homeless_households"] == 0:
		var extra := HEHousehold.new(sim._next_household_id, 1, 0, 0.0, SID)
		sim._next_household_id += 1
		sim.households[extra.id] = extra
		s.household_ids.append(extra.id)
		sim._reconcile_housing(SID)
	var homeless: Array[int] = sim._homeless_household_ids(SID)
	_assert(homeless.size() == 1, "Exactly one household is homeless (got %d)" % homeless.size())
	var leaver: int = sim.get_household_ids(SID)[0]
	var freed: int = (sim.households[leaver] as HEHousehold).dwelling_id
	sim._write_off_and_remove_households([leaver] as Array[int])
	sim._reconcile_housing(SID)
	_assert((sim.households[homeless[0]] as HEHousehold).dwelling_id == freed, "The homeless household moves into the freed house")
	_assert(sim.get_housing_report(SID)["homeless_households"] == 0, "Nobody is homeless after the move")
	_check_invariants(sim, "after a household left")

func _check_new_house_and_upgrade_fill_at_once() -> void:
	var sim := HESimulation.new(SEED, Callable(HEFixtures, "build_three_business_economy"))
	var s: HESettlement = sim.settlements[SID]
	while sim.get_housing_report(SID)["homeless_households"] < 5:
		var extra := HEHousehold.new(sim._next_household_id, 1, 0, 0.0, SID)
		sim._next_household_id += 1
		sim.households[extra.id] = extra
		s.household_ids.append(extra.id)
	sim._reconcile_housing(SID)
	var homeless_before: int = sim.get_housing_report(SID)["homeless_households"]
	_assert(homeless_before >= 4, "Setup leaves several homeless households (%d)" % homeless_before)
	var house := HEHouse.new(sim.next_dwelling_id(), SID)
	sim.add_dwelling(house)
	_assert(sim.get_housing_report(SID)["homeless_households"] == homeless_before - 1, "A new house is occupied at once")
	var occupants: Array = []
	for report in sim.get_dwelling_reports(SID):
		if report["dwelling_id"] == house.id:
			occupants = report["occupant_household_ids"]
	_assert(occupants.size() == 1, "The new house reports one occupant")

	# Tenement upgrade in place through the government build path.
	sim.construction_days = 0 # instant builds; construction timing is covered elsewhere
	var gov: HEBusiness = sim.businesses[HEScenarioSeeds.GOVERNMENT_BUSINESS_ID]
	gov.balance = HEScenarioSeeds.WAREHOUSE_BUILD_COST + 1000.0
	_assert(sim.build_government_building(SID, "warehouse"), "Warehouse builds")
	sim._government_warehouse(SID).add_stock(Commodity.Type.TIMBER, 500.0)
	sim._government_warehouse(SID).add_stock(Commodity.Type.STONE, 500.0)
	var innermost: int = s.dwelling_ids.min()
	var homeless_mid: int = sim.get_housing_report(SID)["homeless_households"]
	_assert(sim.build_government_building(SID, "tenement"), "A tenement upgrade builds")
	_assert(sim.get_housing_report(SID)["homeless_households"] == maxi(0, homeless_mid - 3), "The upgrade houses up to three more households at once")
	var innermost_occupants: Array = []
	for report in sim.get_dwelling_reports(SID):
		if report["dwelling_id"] == innermost:
			innermost_occupants = report["occupant_household_ids"]
	_assert(innermost_occupants.size() == mini(4, 1 + homeless_mid), "The upgraded house takes the new households (%d)" % innermost_occupants.size())
	_check_invariants(sim, "after builds")

func _check_homeless_follow_assignment() -> void:
	var sim := HESimulation.new(SEED, Callable(HEFixtures, "build_three_business_economy"))
	sim.dwellings.clear()
	(sim.settlements[SID] as HESettlement).dwelling_ids.clear()
	var first: int = sim.get_household_ids(SID)[0]
	_assert(sim.get_household_summary(first)["housing_status"] == "homeless", "A household whose house is gone reports homeless before any reconcile")
	_assert(sim._homeless_household_ids(SID).size() == sim.get_household_ids(SID).size(), "Without houses everyone is homeless")
	_assert((sim.households[first] as HEHousehold).dwelling_id == -1, "Reconcile clears the stale assignment")

func _check_unmodeled_housing() -> void:
	var sim := HESimulation.new(SEED, Callable(HEFixtures, "build_three_business_economy"))
	var s: HESettlement = sim.settlements[SID]
	sim.dwellings.clear()
	s.dwelling_ids.clear()
	s.housing_modeled = false
	sim.advance_ticks(1)
	for household_id in sim.get_household_ids(SID):
		_assert((sim.households[household_id] as HEHousehold).dwelling_id == -1, "Unmodeled housing assigns no house")
		_assert(sim.get_household_summary(household_id)["housing_status"] == "unlimited", "Unmodeled housing reports unlimited")
	_assert(sim._homeless_household_ids(SID).is_empty(), "Unmodeled housing has no homeless")

func _check_reports() -> void:
	var sim := _preset("small_village")
	var villagers := sim.get_villager_reports(SID)
	_assert(villagers.size() == sim.get_household_ids(SID).size(), "One villager report per household")
	var people := 0
	var previous := -1
	for report in villagers:
		_assert(int(report["household_id"]) > previous, "Villager reports ascend by household id")
		previous = int(report["household_id"])
		var h: HEHousehold = sim.households[report["household_id"]]
		_assert(report["dwelling_id"] == h.dwelling_id, "Villager report carries the house")
		_assert(report["employer_business_id"] == h.employer_business_id, "Villager report carries the employer")
		_assert((report["worker_ages"] as PackedInt32Array).size() == h.worker_capacity(), "One worker age per worker")
		_assert((report["dependent_ages"] as PackedInt32Array).size() == h.demographics.dependents, "One dependent age per dependent")
		_assert(sim.get_household_summary(h.id)["dwelling_id"] == h.dwelling_id, "Household summary carries the house")
		people += (report["worker_ages"] as PackedInt32Array).size() + (report["dependent_ages"] as PackedInt32Array).size()
	_assert(people == sim.get_city_summary()["population"], "Villager reports cover the whole population (%d vs %d)" % [people, sim.get_city_summary()["population"]])
	var occupied := 0
	for report in sim.get_dwelling_reports(SID):
		_assert(report.has("occupant_household_ids") and report.has("capacity"), "Dwelling reports carry occupants and capacity")
		occupied += (report["occupant_household_ids"] as Array).size()
		for household_id in report["occupant_household_ids"]:
			_assert((sim.households[household_id] as HEHousehold).dwelling_id == report["dwelling_id"], "Occupants agree with household assignments")
	_assert(occupied == sim.get_household_ids(SID).size(), "Every seeded household is an occupant somewhere")