extends SceneTree

const Simulation = preload("res://scripts/sim/simulation.gd")
const ScenarioSeeds = preload("res://scripts/sim/data/scenario_seeds.gd")

## Milestone 0.76 acceptance check: four authored isolated-settlement
## scenarios that should deterministically diverge into equilibrium,
## contraction, collapse, or recovery. Run with:
##   godot --headless --script res://scripts/sim/harness/run_scenarios.gd
##
## Assertions are ranges/trends, not exact populations (the settlements are
## small and thresholds are day-granular, so exact numbers are brittle) --
## but two runs with the same seed must still produce identical results.

const SEED := 777
const TEN_YEARS := Simulation.DAYS_PER_YEAR * 10
const SETTLEMENT_ID := 1

var _ok := true

func _init() -> void:
	_check_determinism()
	_check_viable_farm()
	_check_overpopulated_farm()
	_check_no_food_settlement()
	_check_recovery_boundary()

	if _ok:
		print("\nMilestone 0.76 acceptance: PASS")
	else:
		print("\nMilestone 0.76 acceptance: FAIL")
	quit(0 if _ok else 1)

func _new_sim(builder_method: String) -> Simulation:
	return Simulation.new(SEED, Callable(ScenarioSeeds, builder_method))

func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_ok = false

func _check_determinism() -> void:
	var a := _new_sim("build_overpopulated_farm")
	var b := _new_sim("build_overpopulated_farm")
	a.advance_ticks(TEN_YEARS)
	b.advance_ticks(TEN_YEARS)
	var summary_a := a.get_settlement_summary(SETTLEMENT_ID)
	var summary_b := b.get_settlement_summary(SETTLEMENT_ID)
	_assert(summary_a == summary_b, "Determinism check FAILED: two same-seed scenario runs diverged.")
	if summary_a == summary_b:
		print("Determinism check passed: two same-seed scenario runs produced identical results.")

func _check_viable_farm() -> void:
	print("\n=== Scenario 1: viable farm ===")
	var sim := _new_sim("build_viable_farm")
	var initial_population: int = sim.get_settlement_summary(SETTLEMENT_ID)["population"]
	sim.advance_ticks(TEN_YEARS)
	var s := sim.get_settlement_summary(SETTLEMENT_ID)
	print("  population %d -> %d, status=%s, starvation_deaths_total=%d, grain stock=%.0f" % [
		initial_population, s["population"], s["status"], s["starvation_deaths_total"], s["inventory"]["Grain"]])

	_assert(s["population"] == initial_population, "Viable farm should not lose population over 10 years, got %d -> %d" % [initial_population, s["population"]])
	_assert(s["starvation_deaths_total"] == 0, "Viable farm should have zero starvation deaths, got %d" % s["starvation_deaths_total"])
	_assert(s["status"] == "stable", "Viable farm should be stable after 10 years, got %s" % s["status"])
	_assert(s["inventory"]["Grain"] > 0.0 and s["inventory"]["Grain"] < 20000.0, "Viable farm grain stock should stay bounded, got %.1f" % s["inventory"]["Grain"])

func _check_overpopulated_farm() -> void:
	print("\n=== Scenario 2: overpopulated farm ===")
	var sim := _new_sim("build_overpopulated_farm")
	var initial_population: int = sim.get_settlement_summary(SETTLEMENT_ID)["population"]

	sim.advance_ticks(TEN_YEARS - Simulation.DAYS_PER_YEAR)
	var deaths_before_final_year: int = sim.get_settlement_summary(SETTLEMENT_ID)["starvation_deaths_total"]
	var population_before_final_year: int = sim.get_settlement_summary(SETTLEMENT_ID)["population"]

	sim.advance_ticks(Simulation.DAYS_PER_YEAR)
	var s := sim.get_settlement_summary(SETTLEMENT_ID)
	print("  population %d -> %d (year 9: %d), status=%s, starvation_deaths_total=%d" % [
		initial_population, s["population"], population_before_final_year, s["status"], s["starvation_deaths_total"]])

	_assert(s["population"] < initial_population, "Overpopulated farm should contract, stayed at %d" % s["population"])
	_assert(s["population"] > 0, "Overpopulated farm should stabilize, not collapse entirely")
	_assert(s["starvation_deaths_total"] == deaths_before_final_year, "Overpopulated farm should have stopped losing population by year 10, lost more in the final year (%d -> %d deaths)" % [deaths_before_final_year, s["starvation_deaths_total"]])
	_assert(s["population"] == population_before_final_year, "Overpopulated farm population should be stable during the final year, was %d, now %d" % [population_before_final_year, s["population"]])

func _check_no_food_settlement() -> void:
	print("\n=== Scenario 3: no-food settlement ===")
	var sim := _new_sim("build_no_food_settlement")
	var max_days := Simulation.DAYS_PER_YEAR * 5
	sim.advance_ticks(max_days)
	var s := sim.get_settlement_summary(SETTLEMENT_ID)
	var game_over := sim.get_game_over_info()
	print("  population -> %d, status=%s, game_over=%s" % [s["population"], s["status"], (not game_over.is_empty())])
	if not game_over.is_empty():
		print("  %s" % game_over["summary"])

	_assert(not game_over.is_empty(), "No-food settlement should collapse (game over) within %d days" % max_days)
	_assert(s["status"] == "collapsed", "No-food settlement should end collapsed, got %s" % s["status"])
	_assert(s["household_count"] == 0, "No-food settlement should have zero households left, got %d" % s["household_count"])

func _check_recovery_boundary() -> void:
	print("\n=== Scenario 4: recovery boundary ===")
	var sim := _new_sim("build_recovery_boundary")

	sim.advance_ticks(95)
	var stress_at_shortage: float = sim.get_settlement_summary(SETTLEMENT_ID)["avg_food_stress"]

	sim.advance_ticks(150)
	var s := sim.get_settlement_summary(SETTLEMENT_ID)
	print("  food_stress: peak(day95)=%.2f -> day245=%.2f, emigration_desire=%d, starvation_deaths=%d" % [
		stress_at_shortage, s["avg_food_stress"], s["emigration_desire_count"], s["starvation_deaths_total"]])

	_assert(stress_at_shortage > 0.15, "Recovery boundary should show a real stress rise from the thin starting buffer, got %.3f" % stress_at_shortage)
	_assert(s["avg_food_stress"] < 0.05, "Recovery boundary stress should have recovered by day 245, got %.3f" % s["avg_food_stress"])
	_assert(s["emigration_desire_count"] == 0, "Recovery boundary should never cross the emigration threshold, got %d households wanting to leave" % s["emigration_desire_count"])
	_assert(s["starvation_deaths_total"] == 0, "Recovery boundary should never reach starvation, got %d deaths" % s["starvation_deaths_total"])
