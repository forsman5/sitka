extends SceneTree

## Treasury flow probe: godot ... -- key days step
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var sim := HESimulation.new(12345, Callable(HEScenarioSeeds, "build_preset").bind(args[0]), true)
	var sid := HEScenarioSeeds.SETTLEMENT_ID
	var days := int(args[1])
	var step := int(args[2])
	print("day treasury lastTax taxTotal lastWages govStaff pop constructionSpend")
	var d := 0
	while d <= days:
		var g := sim.get_government_summary(sid)
		var s := sim.get_settlement_summary(sid)
		print("%4d %8.1f %7.2f %9.1f %8.2f %3d %4d %6.0f" % [d, g["treasury"], g["last_tax_collected"], g["tax_collected_total"], g["last_wages_paid"], (g["administrator_household_ids"] as Array).size(), s["population"], s["construction_spend_total"]])
		sim.advance_ticks(step)
		d += step
	quit(0)
