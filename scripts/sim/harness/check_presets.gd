extends SceneTree

## Headless check of the starting-town presets (HEPresets):
##   godot --headless --path . --script res://scripts/sim/harness/check_presets.gd
## Each preset must validate, survive a JSON round trip (it is the save
## format), build a world whose sizes match its spec, and run two years
## without the town collapsing.

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEPresets = preload("res://scripts/sim/household_economy/data/he_presets.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")

const SEED := 12345
const RUN_DAYS := 720

var _ok := true

func _init() -> void:
	for key in HEPresets.keys():
		_check_preset(key)
	_check_large_village_densifies()
	_check_custom_roster()
	_check_rejects_bad_specs()
	print("PRESETS %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_ok = false

func _check_preset(key: String) -> void:
	var spec := HEPresets.spec(key)
	_assert(HEPresets.validate(spec).is_empty(), "%s should validate: %s" % [key, str(HEPresets.validate(spec))])
	var restored: Variant = JSON.parse_string(JSON.stringify(spec))
	_assert(restored is Dictionary and HEPresets.validate(restored).is_empty(), "%s should survive a JSON round trip" % key)
	_assert(int((restored as Dictionary)["households"]) == int(spec["households"]), "%s households survive JSON" % key)

	var builder := Callable(HEScenarioSeeds, "build_preset").bind(key)
	var sim := HESimulation.new(SEED, builder, true)
	var housing := sim.get_housing_report(HEScenarioSeeds.SETTLEMENT_ID)
	var start := sim.get_city_summary()
	_assert(sim.get_household_ids().size() == int(spec["households"]), "%s household count" % key)
	_assert(int(housing["houses"]) == int(spec["housing"]["houses"]), "%s house count" % key)
	_assert(int(housing["capacity"]) >= int(spec["households"]), "%s houses everyone to start" % key)
	_assert(sim._government_warehouse(HEScenarioSeeds.SETTLEMENT_ID) != null, "%s starts with a warehouse" % key)
	var crews: Dictionary = spec["crews"]
	_assert(sim.has_business_of_type(HEScenarioSeeds.SETTLEMENT_ID, "bloomery") == (int(crews.get("bloomery", 0)) > 0), "%s bloomery presence" % key)
	_assert(sim.has_business_of_type(HEScenarioSeeds.SETTLEMENT_ID, "toolsmith") == (int(crews.get("toolsmith", 0)) > 0), "%s toolsmith presence" % key)

	sim.advance_ticks(RUN_DAYS)
	var end := sim.get_city_summary()
	var after := sim.get_housing_report(HEScenarioSeeds.SETTLEMENT_ID)
	print("  %s: population %d -> %d, households %d -> %d, houses %d, homeless %d, treasury %.0f" % [
		key, start["population"], end["population"], housing["households"], after["households"],
		after["houses"], after["homeless_households"], _treasury(sim)])
	_assert(int(end["population"]) >= int(float(start["population"]) * 0.5), "%s population collapsed (%d -> %d)" % [key, start["population"], end["population"]])

func _treasury(sim: HESimulation) -> float:
	return (sim.businesses[HEScenarioSeeds.GOVERNMENT_BUSINESS_ID] as HEBusiness).balance

## The start-large-and-add-housing path: the seeded town is already past the
## densify threshold, so a housing build upgrades a house and the layout shows
## it as a tenement on the same site.
func _check_large_village_densifies() -> void:
	var sim := HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_preset").bind("large_village"), true)
	var settlement_id := HEScenarioSeeds.SETTLEMENT_ID
	var layout := HETownLayout.new("large_village", settlement_id, sim.get_business_reports(), sim.get_dwelling_reports())
	_assert(layout.unplaced_dwelling_ids().is_empty(), "Every seeded large-village house finds a lot")
	_assert(layout.prefers_densify(), "A large village should already prefer densifying")
	var before := sim.get_housing_report(settlement_id)
	_assert(int(before["upgradable_houses"]) == int(before["houses"]), "Every seeded house is upgradable")
	sim.construction_days = 0
	_assert(sim.build_government_building(settlement_id, "tenement"), "The seeded warehouse and treasury afford a tenement")
	var after := sim.get_housing_report(settlement_id)
	_assert(int(after["houses"]) == int(before["houses"]), "A tenement upgrades rather than adds a lot")
	_assert(int(after["capacity"]) == int(before["capacity"]) + 3, "A tenement adds three households of capacity")
	layout.reconcile(sim.get_business_reports(), sim.get_dwelling_reports())
	var tenements := 0
	for site in layout.get_sites():
		if site["type_key"] == HETownLayout.DENSE_HOUSE_TYPE_KEY:
			tenements += 1
	_assert(tenements == 1, "The layout shows one tenement site (got %d)" % tenements)

## The setup page's Custom roster: a spec with `include` builds only the ticked
## businesses at the chosen household count and runs.
func _check_custom_roster() -> void:
	var settlement_id := HEScenarioSeeds.SETTLEMENT_ID
	var roster := ["farm", "woodlot", "trader", "bloomery", "iron_mine"]
	var spec := HEPresets.custom_spec(roster, 24)
	_assert(HEPresets.validate(spec).is_empty(), "A custom spec validates: %s" % str(HEPresets.validate(spec)))
	var sim := HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_spec").bind(spec), true)
	_assert(sim.get_household_ids().size() == 24, "Custom household count is honored")
	for entry in HEScenarioSeeds.business_types():
		_assert(sim.has_business_of_type(settlement_id, entry["type_key"]) == roster.has(entry["type_key"]),
			"Custom roster presence for %s" % entry["type_key"])
	_assert(sim._government_warehouse(settlement_id) != null, "A custom town keeps its warehouse")
	sim.advance_ticks(180)
	_assert(int(sim.get_city_summary()["population"]) > 0, "A custom town runs")
	var restored: Variant = JSON.parse_string(JSON.stringify(spec))
	_assert(restored is Dictionary and (restored as Dictionary)["include"].size() == roster.size(), "A custom spec survives JSON")
	_assert(not HEPresets.custom_roster_valid(["trader", "butcher"]), "A roster with no Farm or Woodlot is invalid")
	_assert(HEPresets.custom_roster_valid(["woodlot"]), "A Woodlot alone is enough to start")
	var woodlot_only := HEPresets.custom_spec(["woodlot"], 20)
	_assert(float(woodlot_only["farm_share"]) == 0.0, "A woodlot-only roster puts everyone on the Woodlot")
	# Housing, gold and the field split are settable.
	var tuned := HEPresets.custom_spec(["farm", "woodlot"], 20, {"houses": 10, "tenements": 2, "treasury_bonus": 500.0, "farm_share": 0.75})
	_assert(HEPresets.validate(tuned).is_empty(), "A tuned custom spec validates: %s" % str(HEPresets.validate(tuned)))
	var tuned_sim := HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_spec").bind(tuned), true)
	var housing := tuned_sim.get_housing_report(settlement_id)
	_assert(int(housing["houses"]) == 12, "10 houses + 2 tenements make 12 buildings (got %d)" % int(housing["houses"]))
	_assert(int(housing["capacity"]) == 10 + 2 * 4, "Tenements shelter four households each (capacity %d)" % int(housing["capacity"]))
	_assert(int(housing["upgradable_houses"]) == 10, "Only the plain houses are upgradable")
	_assert(_treasury(tuned_sim) >= 500.0, "Starting gold lands in the treasury (%.0f)" % _treasury(tuned_sim))

func _check_rejects_bad_specs() -> void:
	var bad := HEPresets.spec("small_village")
	bad["format"] = 99
	_assert(not HEPresets.validate(bad).is_empty(), "An unknown format is rejected")
	bad = HEPresets.spec("small_village")
	bad["crews"] = {"trader": 500}
	_assert(not HEPresets.validate(bad).is_empty(), "Over-crewed specs are rejected")
	_assert(HEPresets.spec("nope").is_empty(), "An unknown key gives an empty spec")
