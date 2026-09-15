extends SceneTree

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
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
	var a := _new_sim("build_three_business_economy")
	var b := _new_sim("build_three_business_economy")
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

## Goods and money reconcile as opening + produced - consumed - exported
## (goods) / opening - written_off + export_revenue (money), across BOTH
## households and businesses; wages and market trades are transfers that
## net to zero; nothing goes negative. A starvation death is the one place
## value legitimately leaves the closed system, and the Trader's exports
## are the one place NEW money legitimately enters it (see
## he_simulation.gd's _export_revenue_total doc comment) -- both are
## explicitly logged rather than just silently not adding up, so the
## reconciliation formula accounts for them instead of ignoring them.
func _check_conservation() -> void:
	print("\n=== Conservation: goods and money reconcile (write-offs/exports accounted), nothing negative ===")
	var sim := _new_sim("build_three_business_economy")
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
			var exported: float = (record["exported"] as Dictionary).get(name, 0.0)
			var written_off: float = (record["goods_written_off"] as Dictionary).get(c, 0.0)
			var closing: float = record["closing_stock"][name]
			var expected: float = opening + produced - consumed - exported - written_off
			worst_stock_gap = max(worst_stock_gap, abs(closing - expected))
		var expected_money: float = record["opening_money"] - float(record["money_written_off"]) + float(record["export_revenue"])
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
##
## With the Trader in the mix, Woodlot's structural timber oversupply is no
## longer a permanent wage penalty -- trade relieves it, and Woodlot's own
## wage recovers past Farm's well before day 300. So this no longer asserts
## a fixed final Farm-vs-Woodlot wage ranking (that was really a proxy for
## "Woodlot's oversupply never gets fixed," which is exactly what the
## Trader exists to fix); it only checks that employment actually moved in
## response to the ORIGINAL mis-staffing, which is the thing this scenario
## is actually testing. It separately checks that the Trader itself -- the
## one business whose entire job is being that outlet -- is still alive
## and earning a real wage this far out, a direct regression check for the
## "permanently dies and stops trading" bug fixed alongside this test
## (dead-forever looks like employed_workers==0 and wage stuck at exactly
## 0.0; a healthy business can still dip below the reference wage on any
## single snapshot day without being dead, so that's not asserted here).
func _check_labor_self_tunes_toward_profitable_business() -> void:
	print("\n=== Labor self-tunes toward the more profitable business ===")
	var sim := _new_sim("build_lopsided_start")
	var early := _business_snapshot(sim, 14)
	var late := _business_snapshot(sim, 300)

	print("  day 14:  Farm capacity=%d employed=%d wage=%.3f | Woodlot capacity=%d employed=%d wage=%.3f | Trader capacity=%d employed=%d wage=%.3f | reference=%.3f" % [
		early["farm"]["capacity"], early["farm"]["employed_workers"], early["farm"]["rolling_average_wage"],
		early["woodlot"]["capacity"], early["woodlot"]["employed_workers"], early["woodlot"]["rolling_average_wage"],
		early["trader"]["capacity"], early["trader"]["employed_workers"], early["trader"]["rolling_average_wage"],
		early["farm"]["reference_wage_per_worker"]])
	print("  day 300: Farm capacity=%d employed=%d wage=%.3f | Woodlot capacity=%d employed=%d wage=%.3f | Trader capacity=%d employed=%d wage=%.3f | reference=%.3f" % [
		late["farm"]["capacity"], late["farm"]["employed_workers"], late["farm"]["rolling_average_wage"],
		late["woodlot"]["capacity"], late["woodlot"]["employed_workers"], late["woodlot"]["rolling_average_wage"],
		late["trader"]["capacity"], late["trader"]["employed_workers"], late["trader"]["rolling_average_wage"],
		late["farm"]["reference_wage_per_worker"]])

	_assert(late["farm"]["employed_workers"] > early["farm"]["employed_workers"],
		"Farm should gain workers over time, went %d -> %d" % [early["farm"]["employed_workers"], late["farm"]["employed_workers"]])
	_assert(late["woodlot"]["employed_workers"] < early["woodlot"]["employed_workers"],
		"Woodlot should lose workers over time, went %d -> %d" % [early["woodlot"]["employed_workers"], late["woodlot"]["employed_workers"]])
	_assert(late["trader"]["employed_workers"] > 0,
		"Trader should still be trading by day 300, not permanently died out")
	_assert(late["trader"]["rolling_average_wage"] > 0.0,
		"Trader should be earning a real wage by day 300, not stuck at 0 like the permanently-dead-capacity bug this test guards against")

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
