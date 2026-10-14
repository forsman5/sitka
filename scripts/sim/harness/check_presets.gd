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
	_check_large_village_houses_and_builds()
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
	_assert(int(end["population"]) >= int(float(start["population"]) * 0.6), "%s population collapsed (%d -> %d)" % [key, start["population"], end["population"]])

func _treasury(sim: HESimulation) -> float:
	return (sim.businesses[HEScenarioSeeds.GOVERNMENT_BUSINESS_ID] as HEBusiness).balance

## Start large and add housing: every seeded house finds a lot in the town
## layout, and the seeded warehouse and treasury afford a new house.
func _check_large_village_houses_and_builds() -> void:
	var sim := HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_preset").bind("large_village"), true)
	var settlement_id := HEScenarioSeeds.SETTLEMENT_ID
	var layout := HETownLayout.new("large_village", settlement_id, sim.get_business_reports(), sim.get_dwelling_reports())
	_assert(layout.unplaced_dwelling_ids().is_empty(), "Every seeded large-village house finds a lot")
	var before := sim.get_housing_report(settlement_id)
	_assert(sim.build_government_building(settlement_id, "house"), "The seeded warehouse and treasury afford a house")
	_assert(int(sim.get_housing_report(settlement_id)["houses"]) == int(before["houses"]) + 1, "A house was added")
	layout.reconcile(sim.get_business_reports(), sim.get_dwelling_reports())
	_assert(layout.unplaced_dwelling_ids().is_empty(), "The new house finds a lot")

func _check_rejects_bad_specs() -> void:
	var bad := HEPresets.spec("small_village")
	bad["format"] = 99
	_assert(not HEPresets.validate(bad).is_empty(), "An unknown format is rejected")
	bad = HEPresets.spec("small_village")
	bad["crews"] = {"trader": 500}
	_assert(not HEPresets.validate(bad).is_empty(), "Over-crewed specs are rejected")
	_assert(HEPresets.spec("nope").is_empty(), "An unknown key gives an empty spec")
