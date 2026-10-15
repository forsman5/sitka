extends SceneTree

## Measurement (not a pass/fail check): how much slack do households have?
## For each preset, after the town settles, compares each household's daily
## wage income to its daily subsistence cost, and asks whether it could lose
## one worker's wage (a parent staying home) and still pay for its needs, now
## and over a runway of its savings.
##
## Cost uses the same expression as HESimulation._reference_wage_per_worker
## (cheapest satisfier per need at the rolling average price), per head.
## Run: Godot --headless --path . --script res://scripts/sim/harness/measure_household_slack.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")

const SEED := 20260901
const PRESETS := ["small_village", "mining_village", "large_village"]
const SNAPSHOT_DAYS := [60, 365, 720]
const RUNWAY_DAYS := 30.0

func _init() -> void:
	for preset in PRESETS:
		var builder := Callable(HEScenarioSeeds, "build_preset").bind(preset)
		var sim := HESimulation.new(SEED, builder)
		var done := 0
		for target in SNAPSHOT_DAYS:
			sim.advance_ticks(target - done)
			done = target
			_report(sim, preset, target)
	quit()

func _per_head_cost(sim, settlement_id: int) -> float:
	var total := 0.0
	for need in HENeeds.all():
		if not sim._need_served(settlement_id, need):
			continue
		var cheapest := INF
		for c in sim._household_cascade(settlement_id, need):
			cheapest = minf(cheapest, sim._average_price_history(settlement_id, c) / need.value_of(c))
		total += cheapest * need.per_person_daily
	return total

func _report(sim, preset: String, day: int) -> void:
	var settlement_id := HEScenarioSeeds.SETTLEMENT_ID
	var head_cost := _per_head_cost(sim, settlement_id)
	var rows: Array[Dictionary] = []
	for household_id in sim.get_household_ids(settlement_id):
		var h: HEHousehold = sim.households[household_id]
		var workers := h.worker_capacity()
		var wage := 0.0
		if h.employer_business_id != -1 and sim.businesses.has(h.employer_business_id):
			wage = float(sim.businesses[h.employer_business_id].last_wage_per_worker)
		var young := 0
		for age in h.dependent_ages():
			if age < HEHousehold.AGING_THRESHOLD_DAYS:
				young += 1
		rows.append({
			"workers": workers, "dependents": h.demographics.dependents, "young": young,
			"employed": h.employer_business_id != -1,
			"income": wage * workers, "cost": head_cost * h.headcount(), "wage": wage,
			"balance": h.balance,
		})

	var n := rows.size()
	var employed := 0
	var covered_now := 0
	var multi := 0 # two or more workers: one could stay home
	var sustain_one_home := 0
	var runway_one_home := 0
	var kids_multi := 0 # multi-worker with a child under the working age
	var kids_sustain := 0
	var kids_runway := 0
	var ratio_sum := 0.0
	var ratio_n := 0
	for r in rows:
		if r["employed"]:
			employed += 1
		if r["cost"] > 0.0:
			ratio_sum += r["income"] / r["cost"]
			ratio_n += 1
			if r["income"] >= r["cost"]:
				covered_now += 1
		if r["workers"] < 2:
			continue
		multi += 1
		var reduced: float = r["wage"] * (r["workers"] - 1)
		var deficit: float = r["cost"] - reduced
		var sustains: bool = deficit <= 0.0
		var runway: bool = sustains or (deficit > 0.0 and r["balance"] / deficit >= RUNWAY_DAYS)
		if sustains:
			sustain_one_home += 1
		if runway:
			runway_one_home += 1
		if r["young"] > 0:
			kids_multi += 1
			if sustains:
				kids_sustain += 1
			if runway:
				kids_runway += 1

	print("\n=== %s, day %d: %d households, per-head cost %.2f/day ===" % [preset, day, n, head_cost])
	print("  employed: %d   income >= cost today: %d   mean income/cost: %.2f" % [employed, covered_now, ratio_sum / maxf(ratio_n, 1)])
	print("  two-plus-worker households: %d" % multi)
	print("    one worker home, sustainable:          %d" % sustain_one_home)
	print("    one worker home, savings last %d days+: %d" % [int(RUNWAY_DAYS), runway_one_home])
	print("  of those with a child under working age: %d" % kids_multi)
	print("    one worker home, sustainable:          %d" % kids_sustain)
	print("    one worker home, savings last %d days+: %d" % [int(RUNWAY_DAYS), kids_runway])
	# Household shape histogram: workers x dependents -> count, ratio.
	var shapes: Dictionary = {}
	for r in rows:
		var key := "%dw+%dd" % [r["workers"], r["dependents"]]
		var s: Dictionary = shapes.get(key, {"n": 0, "ratio": 0.0, "bal": 0.0})
		s["n"] += 1
		s["ratio"] += (r["income"] / r["cost"]) if r["cost"] > 0.0 else 0.0
		s["bal"] += r["balance"]
		shapes[key] = s
	var keys := shapes.keys()
	keys.sort()
	for key in keys:
		var s: Dictionary = shapes[key]
		print("    %-8s n=%-3d income/cost %.2f  mean balance %.1f" % [key, s["n"], s["ratio"] / s["n"], s["bal"] / s["n"]])
