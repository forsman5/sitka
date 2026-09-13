extends SceneTree

const Simulation = preload("res://scripts/sim/simulation.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

## Headless Milestone 0/0.75 acceptance check. Run with:
##   godot --headless --script res://scripts/sim/harness/run_year_simulation.gd
##
## Advances one simulated year over the default five-settlement valley and
## checks:
##   - no commodity inventory goes negative or past a sanity ceiling;
##   - two same-seed runs produce identical settlement summaries AND
##     identical daily histories (determinism covers the new accounting too);
##   - every day's balance equation reconciles (opening + produced + trade_in
##     - household - industrial - trade_out = closing) within floating-point
##     tolerance;
##   - Ironbank's bloomery and Staithe's smithy report the correct limiting
##     input once their starting stockpiles are depleted (checked mid-year,
##     before population collapse -- see LIMITING_INPUT_CHECK_DAY);
##   - callers can enumerate settlements/workplaces without touching
##     Simulation's internal collections.
## Exits 1 on any failure so this can be scripted/CI'd later.

const SEED := 12345
const SANITY_CEILING := 200000.0
const BALANCE_TOLERANCE := 0.01

## By year end, three of the five valley settlements have no local grain
## production and -- correctly, per Milestone 0.76 -- starve out entirely
## within the first year with no transport yet to save them. So the
## limiting-input diagnosis (Milestone 0.75) has to be checked while those
## settlements still have a population/workforce to run their workplaces at
## all, not at year end.
const LIMITING_INPUT_CHECK_DAY := 90

var _ok := true

func _init() -> void:
	var result_a := _run_year(SEED)
	var result_b := _run_year(SEED)

	if result_a["summaries"] != result_b["summaries"]:
		push_error("Determinism check FAILED: two runs with the same seed produced different settlement summaries.")
		_ok = false
	elif result_a["histories"] != result_b["histories"]:
		push_error("Determinism check FAILED: two runs with the same seed produced different daily histories.")
		_ok = false
	else:
		print("Determinism check passed: two same-seed runs produced identical summaries and histories.")

	_check_limiting_input(result_a["checkpoint_reports"], "Ironbank", "bloomery", Commodity.Type.CHARCOAL)
	_check_limiting_input(result_a["checkpoint_reports"], "Staithe", "smithy", Commodity.Type.IRON)

	_print_summary(result_a["summaries"])

	if _ok:
		print("\nMilestone 0/0.75/1 acceptance: PASS")
	else:
		print("\nMilestone 0/0.75/1 acceptance: FAIL")
	quit(0 if _ok else 1)

func _run_year(seed: int) -> Dictionary:
	var sim := Simulation.new(seed)
	var checkpoint_reports := {}
	for d in Simulation.DAYS_PER_YEAR:
		sim.advance_ticks(1)
		_check_invariants(sim, d)
		_check_balance_reconciliation(sim, d)
		if d == LIMITING_INPUT_CHECK_DAY:
			for settlement_id in sim.get_settlement_ids():
				var name: String = sim.get_settlement_summary(settlement_id)["name"]
				checkpoint_reports[name] = sim.get_workplace_reports(settlement_id)

	var summaries := {}
	for settlement_id in sim.get_settlement_ids():
		summaries[settlement_id] = sim.get_settlement_summary(settlement_id)

	var histories := {}
	for settlement_id in sim.get_settlement_ids():
		histories[settlement_id] = sim.get_settlement_history(settlement_id, Simulation.DAYS_PER_YEAR)

	return {"summaries": summaries, "histories": histories, "checkpoint_reports": checkpoint_reports}

func _check_invariants(sim: Simulation, on_day: int) -> void:
	for settlement_id in sim.get_settlement_ids():
		var s := sim.get_settlement_summary(settlement_id)
		for c in Commodity.ALL:
			var name := Commodity.name_of(c)
			var v: float = s["inventory"][name]
			if v < -0.001:
				push_error("Negative stock: %s %s = %f on day %d" % [s["name"], name, v, on_day])
				_ok = false
			elif v > SANITY_CEILING:
				push_error("Stock exceeded sanity ceiling: %s %s = %f on day %d" % [s["name"], name, v, on_day])
				_ok = false

## opening + produced + trade_in - household_consumption -
## industrial_consumption - trade_out == closing, per commodity, per
## settlement, every day.
func _check_balance_reconciliation(sim: Simulation, on_day: int) -> void:
	for settlement_id in sim.get_settlement_ids():
		var history := sim.get_settlement_history(settlement_id, 1)
		if history.is_empty():
			continue
		var record: Dictionary = history[0]
		var opening: Dictionary = record["opening_stock"]
		var closing: Dictionary = record["closing_stock"]
		var produced: Dictionary = record["produced"]
		var household_consumption: Dictionary = record["household_consumption"]
		var industrial_consumption: Dictionary = record["industrial_consumption"]
		var trade_in: Dictionary = record["trade_in"]
		var trade_out: Dictionary = record["trade_out"]
		for c in Commodity.ALL:
			var name := Commodity.name_of(c)
			var expected: float = opening.get(name, 0.0) + produced.get(name, 0.0) + trade_in.get(name, 0.0) \
				- household_consumption.get(name, 0.0) - industrial_consumption.get(name, 0.0) - trade_out.get(name, 0.0)
			var actual: float = closing.get(name, 0.0)
			if abs(expected - actual) > BALANCE_TOLERANCE:
				push_error("Balance mismatch: settlement %d %s expected=%f actual=%f on day %d" % [settlement_id, name, expected, actual, on_day])
				_ok = false

func _check_limiting_input(checkpoint_reports: Dictionary, settlement_name: String, recipe_id: String, expected_limiting_input: Commodity.Type) -> void:
	for report in checkpoint_reports.get(settlement_name, []):
		if report["recipe_id"] != recipe_id:
			continue
		if report["limiting_input"] != expected_limiting_input:
			push_error("%s's %s should report %s as its limiting input on day %d, got %s" % [
				settlement_name, recipe_id, Commodity.name_of(expected_limiting_input), LIMITING_INPUT_CHECK_DAY, str(report["limiting_input"])])
			_ok = false
		return
	push_error("Could not find %s's %s workplace to check its limiting input" % [settlement_name, recipe_id])
	_ok = false

func _print_summary(summaries: Dictionary) -> void:
	print("\n=== Milestone 0: one simulated year, valley summary ===")
	for settlement_id in summaries.keys():
		var s: Dictionary = summaries[settlement_id]
		print("\n%s (population %d, status %s)" % [s["name"], s["population"], s["status"]])
		print("  grain fulfillment: today=%.0f%%  rolling30d=%.0f%%" % [s["grain_fulfillment_today"] * 100.0, s["grain_fulfillment_rolling_30d"] * 100.0])
		for commodity_name in s["inventory"].keys():
			var stock: float = s["inventory"][commodity_name]
			if stock > 0.01:
				print("  %-10s stock=%8.1f" % [commodity_name, stock])
