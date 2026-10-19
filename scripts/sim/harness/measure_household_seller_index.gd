extends SceneTree

## Compare seller lookup and full-tick cost as the catalog grows. Dummy
## warehouses have no stock, staff, or orders; they add catalog entries without
## introducing more sellers or changing household demand.
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SID := HEScenarioSeeds.SETTLEMENT_ID
const EXTRA_BUSINESSES := [0, 100, 500]
const LOOKUP_CALLS := 20000
const TICK_RUNS := 7

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("seller_index_benchmark engine=%s mode=headless-debug" % Engine.get_version_info().get("string", "unknown"))
	for extra_count in EXTRA_BUSINESSES:
		var lookup_sim := _new_sim(extra_count)
		if lookup_sim._business_selling(SID, Commodity.Type.STONE) != null:
			push_error("Small village benchmark must not have a Stone seller")
			quit(1)
			return
		var lookup_start := Time.get_ticks_usec()
		for _i in LOOKUP_CALLS:
			lookup_sim._business_selling(SID, Commodity.Type.STONE)
		var lookup_ms := float(Time.get_ticks_usec() - lookup_start) / 1000.0
		var tick_samples: Array[float] = []
		for _run in TICK_RUNS:
			var sim := _new_sim(extra_count)
			var tick_start := Time.get_ticks_usec()
			sim.advance_ticks(1)
			tick_samples.append(float(Time.get_ticks_usec() - tick_start) / 1000.0)
		var sorted_ticks := tick_samples.duplicate()
		sorted_ticks.sort()
		print("businesses=%d extra=%d lookups=%d lookup_ms=%.3f lookup_us_each=%.4f tick_runs=%d tick_median_ms=%.3f tick_max_ms=%.3f" % [
			lookup_sim.businesses.size(), extra_count, LOOKUP_CALLS, lookup_ms,
			lookup_ms * 1000.0 / LOOKUP_CALLS, TICK_RUNS,
			sorted_ticks[int(TICK_RUNS / 2)], sorted_ticks[-1]])
	quit(0)

func _new_sim(extra_count: int) -> HESimulation:
	var sim := HESimulation.new(4242, Callable(HEScenarioSeeds, "build_preset").bind("small_village"))
	for index in extra_count:
		var dummy := HEBusiness.new(100000 + index, "Benchmark Warehouse", null, 0, 0, HEBusiness.Kind.WAREHOUSE, SID)
		sim.add_business(dummy)
	return sim
