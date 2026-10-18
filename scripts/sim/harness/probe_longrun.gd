extends SceneTree

## Fine-grained probe of one preset: godot ... --script res://scripts/sim/harness/probe_longrun.gd -- key days step [seed]

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var key := args[0]
	var days := int(args[1])
	var step := int(args[2])
	var seed_value := int(args[3]) if args.size() > 3 else 12345
	var sim := HESimulation.new(seed_value, Callable(HEScenarioSeeds, "build_preset").bind(key), true)
	var sid := HEScenarioSeeds.SETTLEMENT_ID
	print("day  pop  hh unemp | grainStore grainPx farm(emp/cap bal) wood(emp/cap) | stress short$ shortGoods emig births | traderG")
	var d := 0
	while d <= days:
		var s := sim.get_settlement_summary(sid)
		var m: Dictionary = s["market"]
		var grain: Dictionary = m.get("Grain", {})
		var farm := ""
		var wood := ""
		for r in sim.get_business_reports(sid, false):
			if r["type_key"] == "farm":
				farm = "%d/%d %.0f w%.1f" % [r["employed_workers"], r["capacity"], r["balance"], r["last_wage_per_worker"]]
			elif r["type_key"] == "woodlot":
				wood = "%d/%d" % [r["employed_workers"], r["capacity"]]
		print("%4d %4d %3d %4d | %8.0f %6.2f  %-18s %-8s | %.2f %3d %3d %4d %4d" % [
			d, s["population"], s["household_count"], s["unemployed_household_count"],
			float(grain.get("stored", 0.0)), float(grain.get("price", 0.0)), farm, wood,
			s["avg_food_stress"], s["households_short_of_funds"], s["households_short_of_goods"],
			s["emigrations_total"], s["births_total"]])
		sim.advance_ticks(step)
		d += step
	quit(0)
