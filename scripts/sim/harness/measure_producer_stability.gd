extends SceneTree

## Sequential five-year field producer measurement. Set STEWARD_ENABLED=false
## for the current-master control and FLAT_HEAT=true for the flat variant.
const Sim = preload("res://scripts/sim/household_economy/he_simulation.gd")
const Seeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const Needs = preload("res://scripts/sim/household_economy/data/he_needs.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SEEDS := [20260901, 7, 424242]
const PRESETS := ["small_village", "mining_village", "large_village"]
const YEARS := 5

func _init() -> void:
	var selected_presets: Array = PRESETS.duplicate()
	var selected_seeds: Array = SEEDS.duplicate()
	var steward_enabled := true
	var flat_heat := false
	var args := OS.get_cmdline_user_args()
	for index in args.size():
		if args[index] == "--preset" and index + 1 < args.size():
			selected_presets = [args[index + 1]]
		elif args[index] == "--seed" and index + 1 < args.size():
			selected_seeds = [int(args[index + 1])]
		elif args[index] == "--flat":
			flat_heat = true
		elif args[index] == "--baseline":
			steward_enabled = false
	var heat = Needs.for_commodity(Commodity.Type.TIMBER)
	var curve: Array[float] = []
	if flat_heat:
		curve = [1.0, 1.0, 1.0, 1.0]
	else:
		curve = [1.0, 0.4, 1.0, 1.8]
	heat.seasonal_curve = curve
	print("producer stability steward=%s flat_heat=%s years=%d" % [steward_enabled, flat_heat, YEARS])
	for preset in selected_presets:
		for seed_value in selected_seeds:
			print(_measure(preset, seed_value, steward_enabled))
	quit()

func _measure(preset: String, seed_value: int, steward_enabled: bool) -> String:
	var builder := Callable(Seeds, "build_preset").bind(preset)
	var sim := Sim.new(seed_value, builder)
	if not steward_enabled:
		for b in sim.businesses.values():
			if b.uses_field_model():
				b.producer_strategy = ""
	var settlement_id: int = sim.settlements.keys()[0]
	var timber_days := 0
	var grain_days := 0
	var price_days := 0
	var winter_days := 0
	var winter_short_days := 0
	var capacity_samples: Dictionary = {}
	for _tick in YEARS * Sim.DAYS_PER_YEAR:
		sim.advance_ticks(1)
		if sim.day < Sim.DAYS_PER_YEAR:
			continue
		price_days += 1
		var market = sim.markets[settlement_id]
		for commodity in [Commodity.Type.TIMBER, Commodity.Type.GRAIN]:
			var price: float = market.price[commodity]
			var base: float = Sim.BASE_PRICE[commodity]
			if price <= base * Sim.PRICE_MULTIPLIER_MIN + 0.00001 or price >= base * Sim.PRICE_MULTIPLIER_MAX - 0.00001:
				if commodity == Commodity.Type.TIMBER:
					timber_days += 1
				else:
					grain_days += 1
		if Sim.season_of_day(sim.day) == Sim.Season.WINTER:
			winter_days += 1
			var short_households := 0
			for hid in sim.settlements[settlement_id].household_ids:
				var h = sim.households[hid]
				var required: float = float(h.last_need_required.get(1, 0.0))
				var provided: float = float(h.last_need_provided.get(1, 0.0))
				if required > 0.0 and required - provided > 0.0001:
					short_households += 1
			if float(short_households) / maxf(1.0, float(sim.settlements[settlement_id].household_ids.size())) >= 0.1:
				winter_short_days += 1
		for b in sim.businesses.values():
			if not b.uses_field_model():
				continue
			var values: Array = capacity_samples.get(b.type_key, [])
			values.append(float(b.capacity))
			capacity_samples[b.type_key] = values
	var capacity_stats := {}
	for key in capacity_samples:
		var values: Array = capacity_samples[key]
		var mean := 0.0
		for x in values:
			mean += float(x)
		mean /= maxf(1.0, float(values.size()))
		var variance := 0.0
		for x in values:
			variance += pow(float(x) - mean, 2.0)
		variance /= maxf(1.0, float(values.size()))
		capacity_stats[key] = {"mean": snappedf(mean, 0.01), "cv": snappedf(sqrt(variance) / mean, 0.001) if mean > 0.0 else 0.0}
	var failures := 0
	for event in sim.get_event_log():
		if event.get("type", "") == "business_failed":
			failures += 1
	return "%s seed=%d winter_short=%.1f%% timber_boundary=%.1f%% grain_boundary=%.1f%% crew=%s failures=%d population=%d" % [
		preset, seed_value, 100.0 * winter_short_days / maxf(1.0, float(winter_days)),
		100.0 * timber_days / maxf(1.0, float(price_days)), 100.0 * grain_days / maxf(1.0, float(price_days)),
		str(capacity_stats), failures, sim._total_population(settlement_id)]
