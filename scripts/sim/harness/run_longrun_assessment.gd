extends SceneTree

## Long-run assessment: runs each preset for N years and prints a yearly table.
##   godot --headless --path . --script res://scripts/sim/harness/run_longrun_assessment.gd -- [years] [seed] [preset_key]

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEPresets = preload("res://scripts/sim/household_economy/data/he_presets.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var years := int(args[0]) if args.size() > 0 else 20
	var seed_value := int(args[1]) if args.size() > 1 else 12345
	var only := args[2] if args.size() > 2 else ""
	for key in HEPresets.keys():
		if only != "" and key != only:
			continue
		_run(key, years, seed_value)
	quit(0)

func _run(key: String, years: int, seed_value: int) -> void:
	var sim := HESimulation.new(seed_value, Callable(HEScenarioSeeds, "build_preset").bind(key), true)
	var sid := HEScenarioSeeds.SETTLEMENT_ID
	print("\n=== %s seed %d ===" % [key, seed_value])
	print("yr  pop  hh  cap homeless unemp health morale  births emig oldage  treasury  wTimb wStone  farm   wood   water  grainP  stress")
	var prev_b := 0
	var prev_e := 0
	var prev_o := 0
	_row(sim, sid, 0, 0, 0, 0)
	for y in range(1, years + 1):
		sim.advance_ticks(HESimulation.DAYS_PER_YEAR)
		var s := sim.get_settlement_summary(sid)
		var b := int(s["births_total"])
		var e := int(s["emigrations_total"])
		var o := int(s["old_age_deaths_total"])
		_row(sim, sid, y, b - prev_b, e - prev_e, o - prev_o)
		prev_b = b
		prev_e = e
		prev_o = o

func _row(sim: HESimulation, sid: int, y: int, db: int, de: int, do_: int) -> void:
	var s := sim.get_settlement_summary(sid)
	var h: Dictionary = s["housing"]
	var w := sim.get_population_wellbeing(sid)
	var treasury := 0.0
	var farm := "-"
	var wood := "-"
	for r in sim.get_business_reports(sid, false):
		if r["type_key"] == "government":
			treasury = r["balance"]
		elif r["type_key"] == "farm":
			farm = "%d/%d" % [r["employed_workers"], r["max_capacity"]]
		elif r["type_key"] == "woodlot":
			wood = "%d/%d" % [r["employed_workers"], r["max_capacity"]]
	var timber := 0.0
	var stone := 0.0
	for row in sim.get_warehouse_inventory(sid):
		if row["commodity"] == Commodity.Type.TIMBER:
			timber = row["units"]
		if row["commodity"] == Commodity.Type.STONE:
			stone = row["units"]
	var water := sim.get_water_summary(sid)
	print("%2d %4d %3d %4d %5d %6d  %.2f  %.2f   %5d %4d %5d  %8.0f %6.0f %6.0f %6s %6s  %.2f   %s  %.2f" % [
		y, s["population"], s["household_count"], h["capacity"], h["homeless_households"], w["unemployed"],
		w["avg_health"], w["avg_morale"], db, de, do_, treasury, timber, stone, farm, wood,
		water["coverage"], _grain(sim, sid), s["avg_food_stress"]])

func _grain(sim: HESimulation, sid: int) -> String:
	var r := sim.get_market_report(sid, Commodity.Type.GRAIN)
	return "%.2f" % float(r.get("price", 0.0))
