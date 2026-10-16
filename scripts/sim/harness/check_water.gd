extends SceneTree

## Water-source acceptance check (wells and river intakes). Run with:
##   godot --headless --path . --script res://scripts/sim/harness/check_water.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEPresets = preload("res://scripts/sim/household_economy/data/he_presets.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")
const HETownPaths = preload("res://scripts/sim/household_economy/he_town_paths.gd")
const HEVillagerSchedule = preload("res://scripts/sim/household_economy/he_villager_schedule.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SEED := 4242
const SID := HEScenarioSeeds.SETTLEMENT_ID

var _ok := true

func _init() -> void:
	_check_constants()
	_check_presets_cover_their_towns()
	_check_yearly_maintenance()
	_check_neglect()
	_check_government_build()
	_check_layout_and_schedule()
	print("WATER %s" % ("OK" if _ok else "FAILED"))
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

func _check_constants() -> void:
	_assert(HEPresets.CUSTOM_PEOPLE_PER_WELL == HEScenarioSeeds.WELL_PEOPLE, "custom rosters size wells like the seeds do")
	# Scope: a 150-person village wants 4-5 wells or 1-2 river intakes.
	var wells := ceili(150.0 / HEScenarioSeeds.WELL_PEOPLE)
	_assert(wells == 4 or wells == 5, "150 people need 4-5 wells (%d)" % wells)
	var intakes := ceili(150.0 / HEScenarioSeeds.RIVER_INTAKE_PEOPLE)
	_assert(intakes == 1 or intakes == 2, "150 people need 1-2 river intakes (%d)" % intakes)

func _check_presets_cover_their_towns() -> void:
	for preset in HEPresets.keys():
		var sim := _sim(preset)
		var water := sim.get_water_summary(SID)
		_assert(int(water["sources"]) > 0, "%s starts with water sources" % preset)
		_assert(float(water["coverage"]) >= 0.99, "%s: sources cover the town (%.2f, %d of %d people)" % [preset, water["coverage"], water["capacity"], water["population"]])
		_assert(float(water["capacity"]) <= float(water["population"]) * 1.5, "%s: not wildly over-provisioned (%d for %d)" % [preset, water["capacity"], water["population"]])
		for report in sim.get_business_reports(SID, false):
			if report["kind"] == "water":
				_assert(int(report["employed_workers"]) == 0 and int(report["capacity"]) == 0, "%s: %s employs no one" % [preset, report["name"]])
	var large := _sim("large_village").get_water_summary(SID)
	_assert(int(large["sources"]) >= 4 and int(large["sources"]) <= 6, "large village has 4-6 wells (%d)" % int(large["sources"]))

func _check_yearly_maintenance() -> void:
	var sim := _sim("small_village")
	var warehouse := _warehouse(sim)
	var before := warehouse.stock(Commodity.Type.TIMBER)
	var upkeep := float(sim.get_water_summary(SID)["upkeep_timber"])
	sim.advance_ticks(HESimulation.WATER_SERVICE_INTERVAL_DAYS)
	_assert(int(sim.get_water_summary(SID)["in_disrepair"]) == 0, "serviced sources stay in repair")
	# The warehouse also trades and builds, so only the lower bound is exact:
	# a year of servicing happened if it was the only drain on timber.
	var serviced := 0
	for report in sim.get_business_reports(SID, false):
		if report["kind"] == "water" and int(report["water"]["days_to_service"]) > 0:
			serviced += 1
	_assert(serviced == int(sim.get_water_summary(SID)["sources"]), "every source has a next servicing date after a year")
	_assert(before >= 0.0 and upkeep > 0.0, "upkeep is a real timber cost (%.1f)" % upkeep)

func _check_neglect() -> void:
	var sim := _sim("small_village")
	var warehouse := _warehouse(sim)
	_assert(warehouse != null, "small village has a warehouse")
	# Start with the warehouse empty and keep it empty for a year.
	for day in HESimulation.WATER_SERVICE_INTERVAL_DAYS:
		warehouse.consume(Commodity.Type.TIMBER, warehouse.stock(Commodity.Type.TIMBER))
		sim.advance_ticks(1)
	var water := sim.get_water_summary(SID)
	_assert(int(water["in_disrepair"]) == int(water["sources"]), "with no timber every source falls into disrepair")
	_assert(float(water["coverage"]) == 0.0 and int(water["capacity"]) == 0, "neglected sources supply nobody")
	# Timber arrives: the next day they are serviced again.
	warehouse.add_stock(Commodity.Type.TIMBER, 100.0)
	sim.advance_ticks(1)
	_assert(int(sim.get_water_summary(SID)["in_disrepair"]) == 0, "restocking the warehouse restores the sources")

func _check_government_build() -> void:
	var sim := _sim("small_village")
	sim.construction_days = 0
	var before := int(sim.get_water_summary(SID)["sources"])
	_assert(sim.build_government_building(SID, "well"), "government can build a well")
	_assert(sim.build_government_building(SID, "well"), "wells are repeatable")
	_assert(sim.build_government_building(SID, "river_intake"), "government can build a river intake")
	var after := sim.get_water_summary(SID)
	_assert(int(after["sources"]) == before + 3, "new sources stand (%d -> %d)" % [before, after["sources"]])
	_assert(int(after["in_disrepair"]) == 0 and int(after["capacity"]) > 0, "new sources are in repair")
	# A river intake costs 40 timber: with the warehouse emptied the build is refused.
	var warehouse := _warehouse(sim)
	warehouse.consume(Commodity.Type.TIMBER, warehouse.stock(Commodity.Type.TIMBER))
	_assert(sim.government_build_blocker(SID, _option("well")) != "", "no timber, no well")
	var count := int(sim.get_water_summary(SID)["sources"])
	_assert(not sim.build_government_building(SID, "well") and int(sim.get_water_summary(SID)["sources"]) == count, "a refused build adds nothing")

func _option(type_key: String) -> Dictionary:
	for option in HEScenarioSeeds.government_buildings():
		if option["type_key"] == type_key:
			return option
	return {}

func _check_layout_and_schedule() -> void:
	var builder := Callable(HEScenarioSeeds, "build_preset").bind("large_village")
	var sim := HESimulation.new(SEED, builder)
	sim.advance_ticks(5)
	var layout := HETownLayout.new(HETownLayout.scenario_key_for(builder), SID, sim.get_business_reports(), sim.get_dwelling_reports())
	layout.reconcile(sim.get_business_reports(), sim.get_dwelling_reports(), sim.get_construction_reports())
	var wells: Array = []
	for site in layout.get_sites():
		if HETownLayout.WATER_TYPE_KEYS.has(site["type_key"]):
			wells.append(site)
	_assert(wells.size() == int(sim.get_water_summary(SID)["sources"]), "every source has a site (%d)" % wells.size())
	_assert(layout.unplaced_business_ids().is_empty(), "no business left unplaced")
	var nearest_pair := INF
	for i in wells.size():
		_assert(bool((wells[i] as Dictionary)["built"]) and (wells[i]["access"] as Vector2).is_finite(), "well %d is built and on a road" % i)
		for j in range(i + 1, wells.size()):
			nearest_pair = minf(nearest_pair, (wells[i]["position"] as Vector2).distance_to(wells[j]["position"]))
	_assert(nearest_pair > 25.0, "wells are spread apart (closest pair %.1f)" % nearest_pair)

	var paths := HETownPaths.new(layout)
	var stops := 0
	var checked := 0
	for report in sim.get_villager_reports(SID):
		var dwelling_id := int(report["dwelling_id"])
		var employer := int(report["employer_business_id"])
		if dwelling_id == -1 or employer == -1:
			continue
		var home := layout.site_of_dwelling(dwelling_id)
		var work := layout.site_of_business(employer)
		if home.is_empty() or work.is_empty():
			continue
		var key := Vector2i(int(report["household_id"]), 1)
		var with_water := HEVillagerSchedule.plan(key, HEVillagerSchedule.ROLE_EMPLOYED, 3, home, work, paths, wells)
		var without := HEVillagerSchedule.plan(key, HEVillagerSchedule.ROLE_EMPLOYED, 3, home, work, paths)
		checked += 1
		_assert(_first_act(without, "fill_water").is_empty(), "no source, no water stop")
		var fill := _first_act(with_water, "fill_water")
		if not fill.is_empty():
			stops += 1
			var near := false
			for well in wells:
				near = near or (fill["pos"] as Vector2).distance_to(well["position"]) < 4.0
			_assert(near, "the stop is at a water source's door")
			_assert(float(fill["t1"]) - float(fill["t0"]) > 0.1, "filling up takes time")
		if checked >= 60:
			break
	_assert(checked > 20, "enough employed villagers checked (%d)" % checked)
	_assert(stops > checked / 2, "most workers pass a well on the way (%d of %d)" % [stops, checked])

func _first_act(villager_plan: Dictionary, act: String) -> Dictionary:
	for seg in villager_plan["segs"]:
		if seg["act"] == act:
			return seg
	return {}
