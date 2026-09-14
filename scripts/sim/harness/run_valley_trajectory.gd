extends SceneTree

const Simulation = preload("res://scripts/sim/simulation.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

## Long-horizon diagnostic for the full five-settlement valley -- unlike
## run_year_simulation.gd (one year, pass/fail), this just runs for
## YEARS_TO_RUN and prints a per-settlement snapshot every CHECKPOINT_DAYS,
## so a slow multi-year decline (or a fix for one) is actually visible
## instead of hiding behind a single end-of-run number. No assertions --
## this is for reading, not gating. Run with:
##   godot --headless --script res://scripts/sim/harness/run_valley_trajectory.gd

const SEED := 12345
const YEARS_TO_RUN := 5
const CHECKPOINT_DAYS := 90 # one season

func _init() -> void:
	var sim := Simulation.new(SEED)
	var total_days := Simulation.DAYS_PER_YEAR * YEARS_TO_RUN
	var day := 0
	while day < total_days:
		sim.advance_ticks(CHECKPOINT_DAYS)
		day += CHECKPOINT_DAYS
		_print_checkpoint(sim, day)
	quit()

func _print_checkpoint(sim: Simulation, day: int) -> void:
	var clock := sim.get_clock_summary()
	print("\n--- Day %d (Year %d, %s) ---" % [day, clock["year"], clock["season_name"]])
	for settlement_id in sim.get_settlement_ids():
		var s := sim.get_settlement_summary(settlement_id)
		var grain: float = s["inventory"]["Grain"]
		print("  %-10s pop=%4d  status=%-14s  grain_stock=%8.1f  fulfillment30d=%4.0f%%  shipments_recv=%3d  starved=%3d" % [
			s["name"], s["population"], s["status"], grain,
			s["grain_fulfillment_rolling_30d"] * 100.0,
			s["shipments_received_total"], s["starvation_deaths_total"]])
