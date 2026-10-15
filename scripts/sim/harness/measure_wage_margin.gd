extends SceneTree

## Measurement: can businesses afford paying above the subsistence wage?
## Runs each preset for DAYS with HESimulation.reference_wage_margin set to
## each value in MARGINS and reports solvency (business failures, money written
## off), employment, population, and household income against subsistence cost
## (cost measured the same way as _reference_wage_per_worker, without the margin).
## Run: Godot --headless --path . --script res://scripts/sim/harness/measure_wage_margin.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")

const SEED := 20260901
const PRESETS := ["small_village", "large_village"]
const MARGINS := [0.0, 0.1, 0.25, 0.5]
const DAYS := 720
const SAMPLE_EVERY := 30

func _init() -> void:
	for preset in PRESETS:
		print("\n##### %s, %d days" % [preset, DAYS])
		for margin in MARGINS:
			_run(preset, margin)
	quit()

func _head_cost(sim, settlement_id: int) -> float:
	var total := 0.0
	for need in HENeeds.all():
		if not sim._need_served(settlement_id, need):
			continue
		var cheapest := INF
		for c in sim._household_cascade(settlement_id, need):
			cheapest = minf(cheapest, sim._average_price_history(settlement_id, c) / need.value_of(c))
		total += cheapest * need.per_person_daily
	return total

func _run(preset: String, margin: float) -> void:
	var builder := Callable(HEScenarioSeeds, "build_preset").bind(preset)
	var sim := HESimulation.new(SEED, builder)
	sim.reference_wage_margin = margin
	var settlement_id := HEScenarioSeeds.SETTLEMENT_ID
	var seen: Dictionary = {}
	for id in sim.businesses.keys():
		seen[id] = true
	var failures := 0
	var ratio_sum := 0.0
	var samples := 0
	var employed_sum := 0.0
	var pop_sum := 0.0
	var covered_sum := 0.0
	var day := 0
	while day < DAYS:
		sim.advance_ticks(SAMPLE_EVERY)
		day += SAMPLE_EVERY
		for id in seen.keys():
			if not sim.businesses.has(id):
				failures += 1
				seen.erase(id)
		for id in sim.businesses.keys():
			seen[id] = true
		if day < 120:
			continue # settle
		var head_cost := _head_cost(sim, settlement_id)
		var income := 0.0
		var cost := 0.0
		var employed := 0
		var households := 0
		var pop := 0
		var covered := 0
		for household_id in sim.get_household_ids(settlement_id):
			var h: HEHousehold = sim.households[household_id]
			var wage := 0.0
			if h.employer_business_id != -1 and sim.businesses.has(h.employer_business_id):
				wage = float(sim.businesses[h.employer_business_id].last_wage_per_worker)
				employed += 1
			var inc := wage * h.worker_capacity()
			var c := head_cost * h.headcount()
			income += inc
			cost += c
			households += 1
			pop += h.headcount()
			if inc >= c:
				covered += 1
		if cost > 0.0:
			ratio_sum += income / cost
		employed_sum += float(employed) / maxf(households, 1)
		covered_sum += float(covered) / maxf(households, 1)
		pop_sum += pop
		samples += 1
	var n := maxf(samples, 1)
	print("margin %+.0f%%: businesses %d (failed %d, written off %.0f g) | employed %.0f%% | population %.0f | income/cost %.2f | households covered %.0f%%" % [
		margin * 100.0, sim.businesses.size(), failures, sim._money_written_off_total,
		100.0 * employed_sum / n, pop_sum / n, ratio_sum / n, 100.0 * covered_sum / n])
