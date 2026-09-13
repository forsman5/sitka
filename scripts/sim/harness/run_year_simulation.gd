extends SceneTree

const Simulation = preload("res://scripts/sim/simulation.gd")
const Settlement = preload("res://scripts/sim/records/settlement.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

## Headless Milestone 0 acceptance check. Run with:
##   godot --headless --script res://scripts/sim/harness/run_year_simulation.gd
##
## Advances one simulated year, checks every day that no commodity inventory
## goes negative or blows past a generous sanity ceiling, and runs twice with
## the same seed to confirm the simulation is deterministic. Exits 1 on any
## failure so this can be scripted/CI'd later.

const SEED := 12345
const SANITY_CEILING := 200000.0

var _ok := true

func _init() -> void:
	var summary_a := _run_year(SEED)
	var summary_b := _run_year(SEED)

	if summary_a != summary_b:
		push_error("Determinism check FAILED: two runs with the same seed produced different results.")
		_ok = false
	else:
		print("Determinism check passed: two same-seed runs produced identical results.")

	_print_summary(summary_a)

	if _ok:
		print("\nMilestone 0 acceptance: PASS")
	else:
		print("\nMilestone 0 acceptance: FAIL")
	quit(0 if _ok else 1)

func _run_year(seed: int) -> Dictionary:
	var sim := Simulation.new(seed)
	for d in Simulation.DAYS_PER_YEAR:
		sim.advance_ticks(1)
		_check_invariants(sim, d)

	var summary := {}
	for settlement_id in sim.settlements.keys():
		summary[settlement_id] = sim.get_settlement_summary(settlement_id)
	return summary

func _check_invariants(sim: Simulation, on_day: int) -> void:
	for settlement_id in sim.settlements.keys():
		var s: Settlement = sim.settlements[settlement_id]
		for c in Commodity.ALL:
			var v: float = s.stock(c)
			if v < -0.001:
				push_error("Negative stock: %s %s = %f on day %d" % [s.name, Commodity.name_of(c), v, on_day])
				_ok = false
			elif v > SANITY_CEILING:
				push_error("Stock exceeded sanity ceiling: %s %s = %f on day %d" % [s.name, Commodity.name_of(c), v, on_day])
				_ok = false

func _print_summary(summary: Dictionary) -> void:
	print("\n=== Milestone 0: one simulated year, valley summary ===")
	for settlement_id in summary.keys():
		var s: Dictionary = summary[settlement_id]
		print("\n%s (population %d)" % [s["name"], s["population"]])
		for commodity_name in s["inventory"].keys():
			var stock: float = s["inventory"][commodity_name]
			var unmet: float = s["unmet_demand"][commodity_name]
			if stock > 0.01 or unmet > 0.01:
				print("  %-10s stock=%8.1f  unmet_demand=%8.1f" % [commodity_name, stock, unmet])
