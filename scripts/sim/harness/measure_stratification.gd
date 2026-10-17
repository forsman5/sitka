extends SceneTree

## Measurement: how unequal are households after a year? For each preset (mean
## of SEEDS), at day DAYS: Gini of balance and of income, income and balance at
## the mean and the 35th/50th/65th percentiles, and per income quintile the
## mean income, mean balance and meat's share of food eaten.
## Income = daily wage x workers, averaged over the last WINDOW days a
## household existed. Meat share = meat food-value / total food-value consumed
## (meat counts twice per unit, HENeeds). Uses only APIs present on master.
## Run: Godot --headless --path . --script res://scripts/sim/harness/measure_stratification.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SEEDS := [20260901, 7, 424242]
const PRESETS := ["small_village", "mining_village", "large_village"]
const DAYS := 365
const WINDOW := 360
const MEAT_FOOD_VALUE := 2.0

func _init() -> void:
	for preset in PRESETS:
		var runs: Array[Dictionary] = []
		for seed_value in SEEDS:
			runs.append(_run(preset, seed_value))
		_print_preset(preset, runs)
	quit()

func _run(preset: String, seed_value: int) -> Dictionary:
	var builder := Callable(HEScenarioSeeds, "build_preset").bind(preset)
	var sim := HESimulation.new(seed_value, builder)
	sim.advance_ticks(DAYS - WINDOW)
	var income_sum: Dictionary = {}
	var days_seen: Dictionary = {}
	var meat_value: Dictionary = {}
	var food_value: Dictionary = {}
	for i in WINDOW:
		sim.advance_ticks(1)
		for household_id in sim.households.keys():
			var h = sim.households[household_id]
			var wage := 0.0
			if h.employer_business_id != -1 and sim.businesses.has(h.employer_business_id):
				wage = float(sim.businesses[h.employer_business_id].last_wage_per_worker)
			income_sum[household_id] = float(income_sum.get(household_id, 0.0)) + wage * h.worker_capacity()
			days_seen[household_id] = int(days_seen.get(household_id, 0)) + 1
			var meat: float = h.last_consumed.get(Commodity.Type.MEAT, 0.0) * MEAT_FOOD_VALUE
			var grain: float = h.last_consumed.get(Commodity.Type.GRAIN, 0.0)
			meat_value[household_id] = float(meat_value.get(household_id, 0.0)) + meat
			food_value[household_id] = float(food_value.get(household_id, 0.0)) + meat + grain
	var rows: Array[Dictionary] = []
	for household_id in sim.households.keys():
		if not days_seen.has(household_id):
			continue
		var h = sim.households[household_id]
		rows.append({
			"income": income_sum[household_id] / days_seen[household_id],
			"balance": h.balance,
			"meat_share": (meat_value[household_id] / food_value[household_id]) if food_value[household_id] > 0.0 else 0.0,
			"food": food_value[household_id] / days_seen[household_id],
			"employed": h.employer_business_id != -1,
			"size": h.headcount(),
		})
	return {"rows": rows}

static func _gini(values: Array) -> float:
	var v := values.duplicate()
	v.sort()
	var n := v.size()
	var total := 0.0
	var weighted := 0.0
	for i in n:
		total += v[i]
		weighted += (i + 1) * v[i]
	if n == 0 or total <= 0.0:
		return 0.0
	return (2.0 * weighted) / (n * total) - float(n + 1) / n

static func _percentile(sorted_values: Array, p: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var index := p * (sorted_values.size() - 1)
	var lo := int(floor(index))
	var hi := mini(lo + 1, sorted_values.size() - 1)
	return lerpf(sorted_values[lo], sorted_values[hi], index - lo)

static func _stats(rows: Array, key: String) -> Dictionary:
	var v: Array = []
	for r in rows:
		v.append(r[key])
	v.sort()
	var total := 0.0
	for x in v:
		total += x
	return {
		"mean": total / maxf(v.size(), 1), "p35": _percentile(v, 0.35), "p50": _percentile(v, 0.5),
		"p65": _percentile(v, 0.65), "gini": _gini(v),
	}

func _print_preset(preset: String, runs: Array[Dictionary]) -> void:
	# Average every statistic across seeds.
	var keys := ["mean", "p35", "p50", "p65", "gini"]
	var income := {}
	var balance := {}
	var quint: Array[Dictionary] = []
	for q in 5:
		quint.append({"income": 0.0, "balance": 0.0, "meat": 0.0, "food": 0.0, "n": 0.0})
	for k in keys:
		income[k] = 0.0
		balance[k] = 0.0
	var households := 0.0
	var unemployed := 0.0
	var avg_meat := 0.0
	for run in runs:
		var rows: Array = run["rows"]
		households += rows.size() / float(runs.size())
		var si := _stats(rows, "income")
		var sb := _stats(rows, "balance")
		for k in keys:
			income[k] += si[k] / runs.size()
			balance[k] += sb[k] / runs.size()
		var sorted := rows.duplicate()
		sorted.sort_custom(func(a, b): return a["income"] < b["income"])
		var meat_total := 0.0
		var food_total := 0.0
		for i in sorted.size():
			var q := mini(int(5.0 * i / sorted.size()), 4)
			var r: Dictionary = sorted[i]
			quint[q]["income"] += r["income"] / runs.size()
			quint[q]["balance"] += r["balance"] / runs.size()
			quint[q]["meat"] += r["meat_share"] / runs.size()
			quint[q]["food"] += r["food"] / runs.size()
			quint[q]["n"] += 1.0 / runs.size()
			if not r["employed"]:
				unemployed += 1.0 / runs.size()
			meat_total += r["meat_share"]
		avg_meat += (meat_total / maxf(sorted.size(), 1)) / runs.size()
	print("\n##### %s, day %d, mean of %d seeds: %.0f households (%.0f%% unemployed), meat %.0f%% of food" % [
		preset, DAYS, runs.size(), households, 100.0 * unemployed / maxf(households, 1.0), 100.0 * avg_meat])
	print("  household income/day: mean %.2f | p35 %.2f | p50 %.2f | p65 %.2f | gini %.2f" % [income["mean"], income["p35"], income["p50"], income["p65"], income["gini"]])
	print("  household balance:    mean %.1f | p35 %.1f | p50 %.1f | p65 %.1f | gini %.2f" % [balance["mean"], balance["p35"], balance["p50"], balance["p65"], balance["gini"]])
	print("  by income quintile (1 = lowest):  income  balance  food/day  meat share")
	for q in 5:
		print("    Q%d (n~%.0f)   %7.2f  %8.1f  %8.2f  %9.0f%%" % [q + 1, quint[q]["n"], _per(quint[q], "income"), _per(quint[q], "balance"), _per(quint[q], "food"), 100.0 * _per(quint[q], "meat")])

## Per-household mean for a quintile: contributions and n were both divided by
## the seed count, so their ratio is the mean over households and seeds.
static func _per(q: Dictionary, key: String) -> float:
	return 0.0 if q["n"] <= 0.0 else q[key] / q["n"]
