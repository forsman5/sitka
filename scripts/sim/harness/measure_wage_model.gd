extends SceneTree

## A/B for the wage model: subsistence (the original derived wage) against the
## productivity model at a few labour shares. Per preset, over DAYS:
## business failures, employment, population, household income against
## subsistence cost, and how much of the town's money households hold.
## Gate for phase 1 of docs/household-wage-model-plan.md: failures must not
## rise and employment must hold, while household wealth improves.
## Run: Godot --headless --path . --script res://scripts/sim/harness/measure_wage_model.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEWages = preload("res://scripts/sim/household_economy/he_wages.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")

const SEEDS := [20260901, 7, 424242]
const PRESETS := ["small_village", "mining_village", "large_village"]
## [label, wage_model, labour_share]
const VARIANTS := [
	["subsistence", HEWages.MODEL_SUBSISTENCE, 0.0],
	["productivity 0.4", HEWages.MODEL_PRODUCTIVITY, 0.4],
	["productivity 0.6", HEWages.MODEL_PRODUCTIVITY, 0.6],
	["productivity 0.8", HEWages.MODEL_PRODUCTIVITY, 0.8],
]
const DAYS := 720
const SAMPLE_EVERY := 30
const SETTLE_DAYS := 120

func _init() -> void:
	for preset in PRESETS:
		print("\n##### %s, %d days, mean of %d seeds" % [preset, DAYS, SEEDS.size()])
		for variant in VARIANTS:
			_run(preset, variant)
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

func _run(preset: String, variant: Array) -> void:
	var agg := {"failed": 0.0, "businesses": 0.0, "employed": 0.0, "pop": 0.0, "ratio": 0.0, "covered": 0.0, "hh_share": 0.0, "wage_x": 0.0, "bal": 0.0}
	for seed_value in SEEDS:
		var r := _run_one(preset, variant, seed_value)
		for key in agg.keys():
			agg[key] += r[key] / SEEDS.size()
	print("%-17s businesses %.1f (failed %.1f) | employed %.0f%% | pop %.0f | income/cost %.2f | covered %.0f%% | households hold %.0f%% of money (%.0f each) | wage %.2fx ref" % [
		variant[0], agg["businesses"], agg["failed"], 100.0 * agg["employed"], agg["pop"], agg["ratio"], 100.0 * agg["covered"], 100.0 * agg["hh_share"], agg["bal"], agg["wage_x"]])

func _run_one(preset: String, variant: Array, seed_value: int) -> Dictionary:
	var builder := Callable(HEScenarioSeeds, "build_preset").bind(preset)
	var sim := HESimulation.new(seed_value, builder)
	sim.wages.model = variant[1]
	if variant[2] > 0.0:
		sim.wages.labour_share = variant[2]
	var settlement_id := HEScenarioSeeds.SETTLEMENT_ID
	var seen: Dictionary = {}
	for id in sim.businesses.keys():
		seen[id] = true
	var failed := 0
	var samples := 0
	var out := {"failed": 0.0, "businesses": 0.0, "employed": 0.0, "pop": 0.0, "ratio": 0.0, "covered": 0.0, "hh_share": 0.0, "wage_x": 0.0, "bal": 0.0}
	var day := 0
	while day < DAYS:
		sim.advance_ticks(SAMPLE_EVERY)
		day += SAMPLE_EVERY
		for id in seen.keys():
			if not sim.businesses.has(id):
				failed += 1
				seen.erase(id)
		for id in sim.businesses.keys():
			seen[id] = true
		if day < SETTLE_DAYS:
			continue
		var head_cost := _head_cost(sim, settlement_id)
		var income := 0.0
		var cost := 0.0
		var employed := 0
		var households := 0
		var pop := 0
		var covered := 0
		var hh_money := 0.0
		var wage_sum := 0.0
		var wage_n := 0
		for household_id in sim.get_household_ids(settlement_id):
			var h: HEHousehold = sim.households[household_id]
			var wage := 0.0
			if h.employer_business_id != -1 and sim.businesses.has(h.employer_business_id):
				wage = float(sim.businesses[h.employer_business_id].last_wage_per_worker)
				employed += 1
				wage_sum += wage
				wage_n += 1
			var inc := wage * h.worker_capacity()
			var c := head_cost * h.headcount()
			income += inc
			cost += c
			households += 1
			pop += h.headcount()
			hh_money += h.balance
			if inc >= c:
				covered += 1
		var total_money: float = sim._total_money()
		var reference: float = sim.wages.reference_wage_per_worker(settlement_id)
		if cost > 0.0:
			out["ratio"] += income / cost
		out["employed"] += float(employed) / maxf(households, 1)
		out["covered"] += float(covered) / maxf(households, 1)
		out["pop"] += pop
		out["hh_share"] += hh_money / maxf(total_money, 1.0)
		out["wage_x"] += (wage_sum / maxf(wage_n, 1)) / maxf(reference, 0.0001)
		out["bal"] += hh_money / maxf(households, 1)
		samples += 1
	var n := maxf(samples, 1)
	for key in ["employed", "pop", "ratio", "covered", "hh_share", "wage_x", "bal"]:
		out[key] /= n
	out["failed"] = failed
	out["businesses"] = sim.businesses.size()
	return out
