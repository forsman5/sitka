extends SceneTree

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

## H1 labor-market acceptance check. Run with:
##   godot --headless --script res://scripts/sim/harness/run_household_economy.gd

const SEED := 4242
const EPSILON := 0.01

var _ok := true

func _init() -> void:
	_check_determinism()
	_check_conservation()
	_check_labor_self_tunes_toward_profitable_business()
	_check_starvation_actually_happens()
	_check_life_cycle_births_and_aging()

	if _ok:
		print("\nH1 acceptance: PASS")
	else:
		print("\nH1 acceptance: FAIL")
	quit(0 if _ok else 1)

func _new_sim(builder_method: String, price_adjustment_enabled: bool = true) -> HESimulation:
	return HESimulation.new(SEED, Callable(HEScenarioSeeds, builder_method), price_adjustment_enabled)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_ok = false

func _check_determinism() -> void:
	print("\n=== Determinism ===")
	var a := _new_sim("build_two_business_economy")
	var b := _new_sim("build_two_business_economy")
	a.advance_ticks(120)
	b.advance_ticks(120)
	var mismatch := false
	for household_id in a.get_household_ids():
		if a.get_household_summary(household_id) != b.get_household_summary(household_id):
			mismatch = true
	_assert(a.get_city_summary() == b.get_city_summary(), "City summaries diverged between two same-seed runs")
	_assert(a.get_business_reports() == b.get_business_reports(), "Business reports diverged between two same-seed runs")
	_assert(not mismatch, "Household summaries diverged between two same-seed runs")
	if not mismatch:
		print("  two same-seed 120-day runs produced identical household, business, and city summaries")

## Goods and money reconcile as opening + produced - consumed (goods) /
## opening - written_off (money), across BOTH households and businesses;
## wages and market trades are transfers that net to zero; nothing goes
## negative. A starvation death is the one place value legitimately leaves
## the closed system, and it's explicitly logged (money_written_off/
## goods_written_off) rather than just silently not adding up -- so the
## reconciliation formula accounts for it instead of ignoring it.
func _check_conservation() -> void:
	print("\n=== Conservation: goods and money reconcile (write-offs accounted), nothing negative ===")
	var sim := _new_sim("build_two_business_economy")
	sim.advance_ticks(365)
	var history := sim.get_daily_history(365)

	var worst_stock_gap := 0.0
	var worst_money_gap := 0.0
	for record in history:
		for c in HESimulation.SUBSISTENCE_COMMODITIES:
			var name := Commodity.name_of(c)
			var opening: float = record["opening_stock"][name]
			var produced: float = record["produced"].get(name, 0.0)
			var consumed: float = record["consumed"].get(name, 0.0)
			var written_off: float = (record["goods_written_off"] as Dictionary).get(c, 0.0)
			var closing: float = record["closing_stock"][name]
			var expected: float = opening + produced - consumed - written_off
			worst_stock_gap = max(worst_stock_gap, abs(closing - expected))
		var expected_money: float = record["opening_money"] - float(record["money_written_off"])
		worst_money_gap = max(worst_money_gap, abs(record["closing_money"] - expected_money))

	print("  worst stock reconciliation gap over 365 days: %.4f" % worst_stock_gap)
	print("  worst same-day money reconciliation gap over 365 days: %.4f" % worst_money_gap)
	_assert(worst_stock_gap < EPSILON, "Stock did not reconcile as opening + produced - consumed - written_off, worst gap %.4f" % worst_stock_gap)
	_assert(worst_money_gap < EPSILON, "Money did not reconcile as opening - written_off, worst gap %.4f" % worst_money_gap)

	var min_household_stock := INF
	var min_balance := INF
	for household_id in sim.get_household_ids():
		var h := sim.get_household_summary(household_id)
		for name in h["inventory"].keys():
			min_household_stock = min(min_household_stock, h["inventory"][name])
		min_balance = min(min_balance, h["balance"])
	for report in sim.get_business_reports():
		min_household_stock = min(min_household_stock, report["stock"])
		min_balance = min(min_balance, report["balance"])
	print("  minimum stock=%.3f, minimum balance=%.3f" % [min_household_stock, min_balance])
	_assert(min_household_stock >= -EPSILON, "Some stock went negative: %.4f" % min_household_stock)
	_assert(min_balance >= -EPSILON, "Some balance went negative: %.4f" % min_balance)

## The core "let it tune itself" claim: starting from a deliberately
## mis-staffed split (Woodlot overstaffed, Farm understaffed), the business
## paying the better wage should gain capacity/employment over time and the
## worse-paying one should lose it, with NO manual retuning of either
## recipe's output rate.
func _check_labor_self_tunes_toward_profitable_business() -> void:
	print("\n=== Labor self-tunes toward the more profitable business ===")
	var sim := _new_sim("build_lopsided_start")
	var early := _business_snapshot(sim, 14)
	var late := _business_snapshot(sim, 300)

	print("  day 14:  Farm capacity=%d employed=%d wage=%.3f | Woodlot capacity=%d employed=%d wage=%.3f | reference=%.3f" % [
		early["farm"]["capacity"], early["farm"]["employed_workers"], early["farm"]["rolling_average_wage"],
		early["woodlot"]["capacity"], early["woodlot"]["employed_workers"], early["woodlot"]["rolling_average_wage"],
		early["farm"]["reference_wage_per_worker"]])
	print("  day 300: Farm capacity=%d employed=%d wage=%.3f | Woodlot capacity=%d employed=%d wage=%.3f | reference=%.3f" % [
		late["farm"]["capacity"], late["farm"]["employed_workers"], late["farm"]["rolling_average_wage"],
		late["woodlot"]["capacity"], late["woodlot"]["employed_workers"], late["woodlot"]["rolling_average_wage"],
		late["farm"]["reference_wage_per_worker"]])

	_assert(late["farm"]["employed_workers"] > early["farm"]["employed_workers"],
		"Farm should gain workers over time, went %d -> %d" % [early["farm"]["employed_workers"], late["farm"]["employed_workers"]])
	_assert(late["woodlot"]["employed_workers"] < early["woodlot"]["employed_workers"],
		"Woodlot should lose workers over time, went %d -> %d" % [early["woodlot"]["employed_workers"], late["woodlot"]["employed_workers"]])
	_assert(late["farm"]["rolling_average_wage"] > late["woodlot"]["rolling_average_wage"],
		"Farm's wage should end up above Woodlot's, got %.3f vs %.3f" % [late["farm"]["rolling_average_wage"], late["woodlot"]["rolling_average_wage"]])

func _business_snapshot(sim: HESimulation, day: int) -> Dictionary:
	sim.advance_ticks(day - sim.day)
	var out := {}
	for report in sim.get_business_reports():
		out[report["name"].to_lower()] = report
	return out

## Starvation is no longer just a reported signal -- a business that can
## never pay enough to cover subsistence should, over a long enough run,
## actually cost the city population and (if unresolved) whole households.
## Force this by capping BOTH businesses' max_capacity well below the
## population's total labor supply, guaranteeing sustained unemployment
## with no possible reallocation escape route.
func _check_starvation_actually_happens() -> void:
	print("\n=== Starvation is real: sustained unemployment costs population ===")
	var sim := _new_sim("build_lopsided_start")
	for business_id in sim.businesses.keys():
		var b = sim.businesses[business_id]
		b.max_capacity = 6
		b.capacity = min(b.capacity, 6)
	sim._reconcile_employment()

	var starting_population: int = sim.get_city_summary()["population"]
	sim.advance_ticks(720)
	var city := sim.get_city_summary()

	print("  population %d -> %d over 720 days, starvation_deaths_total=%d, money_written_off_total=%.1f, unemployed households=%d" % [
		starting_population, city["population"], city["starvation_deaths_total"], city["money_written_off_total"], city["unemployed_household_count"]])

	_assert(city["starvation_deaths_total"] > 0, "Sustained unemployment with no escape route should eventually cause real starvation deaths")
	_assert(city["population"] < starting_population, "Population should actually shrink from starvation, not just report stress")
	_check_demographic_invariants(sim)

## Every LIVE household's dependent_ages array should always have exactly
## as many entries as demographics.dependents says, and neither dependents
## nor worker_capacity should ever go negative. This exact invariant broke
## once already (starvation's remove_member() decremented dependents
## without popping the matching age entry) and produced a household that
## silently never triggered is_empty() -- see he_household.gd's
## remove_member_for_starvation().
func _check_demographic_invariants(sim: HESimulation) -> void:
	for household_id in sim.get_household_ids():
		var h := sim.get_household_summary(household_id)
		var ages: Array = h["dependent_ages"]
		_assert(ages.size() == h["dependents"], "Household %d: dependent_ages has %d entries but dependents=%d" % [household_id, ages.size(), h["dependents"]])
		_assert(h["dependents"] >= 0, "Household %d has negative dependents: %d" % [household_id, h["dependents"]])
		_assert(h["worker_capacity"] >= 0, "Household %d has negative worker_capacity: %d" % [household_id, h["worker_capacity"]])

## Life cycle: a reasonably healthy, evenly-staffed economy run for several
## years should show real births and real aging-into-worker promotions --
## not just reported prosperity. Also checks the MAX_PENDING_DEPENDENTS
## brake actually holds: no household should ever have more dependents
## waiting in the pipeline than that cap allows.
func _check_life_cycle_births_and_aging() -> void:
	print("\n=== Life cycle: births and aging actually happen, via splitting not ballooning ===")
	var sim := _new_sim("build_two_business_economy")
	var starting_household_count: int = sim.get_household_ids().size()
	var starting_workforce := _total_worker_capacity(sim)
	sim.advance_ticks(4 * 360)
	var city := sim.get_city_summary()
	var ending_household_count: int = sim.get_household_ids().size()
	var ending_workforce := _total_worker_capacity(sim)

	print("  over 4 years: births_total=%d worker_promotions_total=%d, households %d -> %d, total worker_capacity %d -> %d, population=%d" % [
		city["births_total"], city["worker_promotions_total"], starting_household_count, ending_household_count, starting_workforce, ending_workforce, city["population"]])

	_assert(city["births_total"] > 0, "A healthy multi-year economy should show at least one real birth, got 0")
	_assert(city["worker_promotions_total"] > 0, "A healthy multi-year economy should show at least one dependent aging into adulthood, got 0")
	_assert(ending_household_count > starting_household_count, "Aging up should create MORE households (splitting), not just bigger ones, got %d -> %d" % [starting_household_count, ending_household_count])
	_assert(ending_workforce > starting_workforce, "Total city-wide worker capacity should grow from aging, got %d -> %d" % [starting_workforce, ending_workforce])

	var max_pending := 0
	var max_worker_capacity := 0
	for household_id in sim.get_household_ids():
		var h := sim.get_household_summary(household_id)
		max_pending = max(max_pending, (h["dependent_ages"] as Array).size())
		max_worker_capacity = max(max_worker_capacity, h["worker_capacity"])
	print("  most dependents ever pending in one household's pipeline: %d (cap is %d); largest surviving worker_capacity: %d" % [max_pending, HEHousehold.MAX_PENDING_DEPENDENTS, max_worker_capacity])
	_assert(max_pending <= HEHousehold.MAX_PENDING_DEPENDENTS, "No household should exceed MAX_PENDING_DEPENDENTS pending dependents, saw %d" % max_pending)
	_assert(max_worker_capacity <= HEScenarioSeeds.WORKER_CAPACITY, "No household's worker_capacity should ever exceed what it was seeded with -- aged-up workers must split off, not join the parent's job, saw %d" % max_worker_capacity)
	_check_demographic_invariants(sim)

func _total_worker_capacity(sim: HESimulation) -> int:
	var total := 0
	for household_id in sim.get_household_ids():
		total += sim.get_household_summary(household_id)["worker_capacity"]
	return total
