extends SceneTree

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Recipe = preload("res://scripts/sim/records/recipe.gd")

## H1 labor-market acceptance check. Run with:
##   godot --headless --script res://scripts/sim/harness/run_household_economy.gd

const SEED := 4242
const EPSILON := 0.01

var _ok := true

func _init() -> void:
	_check_determinism()
	_check_conservation()
	_check_labor_self_tunes_toward_profitable_business()
	_check_emigration_actually_happens()
	_check_life_cycle_births_and_aging()
	_check_old_age_deaths_actually_happen()
	_check_old_age_orphans_get_adopted()

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
## net to zero; nothing goes negative. An emigration is the one place
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
##
## Checks Farm/Woodlot's SHARE of total city employment rather than raw
## employed_workers counts: with life cycle now growing the total workforce
## over time (births/aging), Woodlot's raw headcount can rise even while it
## keeps losing ground relative to Farm, simply because population growth
## adds more workers than reallocation moves away -- shares stay correct
## regardless of how big the city grows in the meantime.
func _check_labor_self_tunes_toward_profitable_business() -> void:
	print("\n=== Labor self-tunes toward the more profitable business ===")
	var sim := _new_sim("build_lopsided_start")
	var early := _business_snapshot(sim, 14)
	var early_total_workers := _total_worker_capacity(sim)
	var late := _business_snapshot(sim, 300)
	var late_total_workers := _total_worker_capacity(sim)

	print("  day 14:  Farm capacity=%d employed=%d wage=%.3f | Woodlot capacity=%d employed=%d wage=%.3f | Trader capacity=%d employed=%d wage=%.3f | reference=%.3f | total workers=%d" % [
		early["farm"]["capacity"], early["farm"]["employed_workers"], early["farm"]["rolling_average_wage"],
		early["woodlot"]["capacity"], early["woodlot"]["employed_workers"], early["woodlot"]["rolling_average_wage"],
		early["trader"]["capacity"], early["trader"]["employed_workers"], early["trader"]["rolling_average_wage"],
		early["farm"]["reference_wage_per_worker"], early_total_workers])
	print("  day 300: Farm capacity=%d employed=%d wage=%.3f | Woodlot capacity=%d employed=%d wage=%.3f | Trader capacity=%d employed=%d wage=%.3f | reference=%.3f | total workers=%d" % [
		late["farm"]["capacity"], late["farm"]["employed_workers"], late["farm"]["rolling_average_wage"],
		late["woodlot"]["capacity"], late["woodlot"]["employed_workers"], late["woodlot"]["rolling_average_wage"],
		late["trader"]["capacity"], late["trader"]["employed_workers"], late["trader"]["rolling_average_wage"],
		late["farm"]["reference_wage_per_worker"], late_total_workers])

	var early_farm_share: float = float(early["farm"]["employed_workers"]) / float(early_total_workers)
	var late_farm_share: float = float(late["farm"]["employed_workers"]) / float(late_total_workers)
	var early_woodlot_share: float = float(early["woodlot"]["employed_workers"]) / float(early_total_workers)
	var late_woodlot_share: float = float(late["woodlot"]["employed_workers"]) / float(late_total_workers)
	print("  Farm share of workforce: %.1f%% -> %.1f%% | Woodlot share: %.1f%% -> %.1f%%" % [
		early_farm_share * 100.0, late_farm_share * 100.0, early_woodlot_share * 100.0, late_woodlot_share * 100.0])

	_assert(late_farm_share > early_farm_share,
		"Farm's SHARE of total employment should grow over time, went %.1f%% -> %.1f%%" % [early_farm_share * 100.0, late_farm_share * 100.0])
	_assert(late_woodlot_share < early_woodlot_share,
		"Woodlot's SHARE of total employment should shrink over time, went %.1f%% -> %.1f%%" % [early_woodlot_share * 100.0, late_woodlot_share * 100.0])
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
func _check_emigration_actually_happens() -> void:
	print("\n=== Emigration is real: sustained unemployment costs population ===")
	var sim := _new_sim("build_lopsided_start")
	for business_id in sim.businesses.keys():
		var b = sim.businesses[business_id]
		b.max_capacity = 6
		b.capacity = min(b.capacity, 6)
	sim._reconcile_employment()

	var starting_population: int = sim.get_city_summary()["population"]
	sim.advance_ticks(720)
	var city := sim.get_city_summary()

	print("  population %d -> %d over 720 days, emigrations_total=%d, money_written_off_total=%.1f, unemployed households=%d" % [
		starting_population, city["population"], city["emigrations_total"], city["money_written_off_total"], city["unemployed_household_count"]])

	_assert(city["emigrations_total"] > 0, "Sustained unemployment with no escape route should eventually cause real emigration")
	_assert(city["population"] < starting_population, "Population should actually shrink from emigration, not just report stress")
	_check_demographic_invariants(sim)

## Every LIVE household's dependent_ages array should always have exactly
## as many entries as demographics.dependents says, and neither dependents
## nor worker_capacity should ever go negative. This exact invariant broke
## once already (emigration's remove_member() decremented dependents
## without popping the matching age entry) and produced a household that
## silently never triggered is_empty() -- see he_household.gd's
## remove_member_for_emigration().
func _check_demographic_invariants(sim: HESimulation) -> void:
	for household_id in sim.get_household_ids():
		var h := sim.get_household_summary(household_id)
		var ages: Array = h["dependent_ages"]
		_assert(ages.size() == h["dependents"], "Household %d: dependent_ages has %d entries but dependents=%d" % [household_id, ages.size(), h["dependents"]])
		_assert(h["dependents"] >= 0, "Household %d has negative dependents: %d" % [household_id, h["dependents"]])
		_assert(h["worker_capacity"] >= 0, "Household %d has negative worker_capacity: %d" % [household_id, h["worker_capacity"]])
		var worker_ages: Array = h["worker_ages"]
		_assert(worker_ages.size() == h["worker_capacity"], "Household %d: worker_ages has %d entries but worker_capacity=%d" % [household_id, worker_ages.size(), h["worker_capacity"]])
		_assert(not (h["worker_capacity"] == 0 and h["dependents"] > 0),
			"Household %d has %d dependents but 0 workers -- should have been dissolved and adopted (see _adopt_orphaned_dependents), not left stuck" % [household_id, h["dependents"]])

## Life cycle: a reasonably healthy, evenly-staffed economy run for several
## years should show real births and real aging-into-worker promotions --
## not just reported prosperity. Also checks the MAX_PENDING_DEPENDENTS
## brake actually holds: no household should ever have more dependents
## waiting in the pipeline than that cap allows.
func _check_life_cycle_births_and_aging() -> void:
	print("\n=== Life cycle: births and aging actually happen, via splitting not ballooning ===")
	var sim := _new_sim("build_three_business_economy")
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

## Old age is a slow signal -- LIFESPAN_DAYS is 20 "years" (see
## he_household.gd) -- so this needs a much longer run than the other life-
## cycle checks to actually observe a death rather than just a promise of
## one someday. A healthy economy (same balanced scenario as the life-cycle
## check above) should still show real old-age deaths well within that
## horizon, on top of continuing births/promotions/emigrations, without the
## population collapsing to zero.
func _check_old_age_deaths_actually_happen() -> void:
	print("\n=== Old age: workers actually die of old age on a healthy, long-running economy ===")
	var sim := _new_sim("build_three_business_economy")
	var years := 15
	sim.advance_ticks(years * 360)
	var city := sim.get_city_summary()

	print("  over %d years: old_age_deaths_total=%d, emigrations_total=%d, births_total=%d, population=%d" % [
		years, city["old_age_deaths_total"], city["emigrations_total"], city["births_total"], city["population"]])

	_assert(city["old_age_deaths_total"] > 0, "A healthy economy run long enough should show at least one real old-age death, got 0")
	_assert(city["population"] > 0, "Old age should thin the population, not wipe it out entirely, got 0")
	_check_demographic_invariants(sim)

## Regression test for the "a household orphaned by old age gets stuck
## forever, its dependents slowly lost to starvation instead of aging up"
## bug: in a healthy, normally-seeded economy this path is too rare to
## reliably exercise (dependents almost always promote and split off long
## before a household's ORIGINAL workers ever reach LIFESPAN_DAYS -- see
## _check_old_age_deaths_actually_happen above, which sees 0 adoptions over
## 15 years despite plenty of old-age deaths). So it's forced directly
## here via a hand-built two-household world: household 1 has exactly one
## worker a single day from dying of old age, holding a freshly-born
## dependent; household 2 is a second, healthy one-worker household and
## the only possible adopter. Confirms household 1 is dissolved (not left
## orphaned), household 2 gains its dependent with age preserved, and that
## dependent keeps aging normally afterward -- eventually promoting into
## its own new household, exactly like any other dependent.
func _check_old_age_orphans_get_adopted() -> void:
	print("\n=== Old age: a household orphaned by its last worker's death is dissolved and adopted, not stuck ===")
	var sim := HESimulation.new(SEED, Callable(self, "_build_orphan_world"), true)

	sim.advance_ticks(30)
	var ids := sim.get_household_ids()
	_assert(not ids.has(1), "Household 1 (orphaned by its only worker's old-age death) should have been dissolved, still exists")
	_assert(ids.has(2), "Household 2 (the adopter) should still exist")
	if ids.has(2):
		var h2 := sim.get_household_summary(2)
		_assert(h2["dependents"] == 1, "Adopting household should have gained the orphan's 1 dependent, has %d" % h2["dependents"])

	var adopted_events := 0
	for e in sim.get_event_log(-1):
		if e["type"] == "adopted":
			adopted_events += 1
	_assert(adopted_events == 1, "Expected exactly one 'adopted' event, saw %d" % adopted_events)

	sim.advance_ticks(360)
	var city := sim.get_city_summary()
	print("  adopted dependent's fate a year later: worker_promotions_total=%d (expected >= 1 -- it should have aged up and split off)" % city["worker_promotions_total"])
	_assert(city["worker_promotions_total"] >= 1, "Adopted dependent should keep aging normally and eventually promote to worker, got 0 promotions")
	_check_demographic_invariants(sim)

func _build_orphan_world(_rng: RandomNumberGenerator) -> Dictionary:
	var settlement := HESettlement.new(1, "Testholm")
	var farm_recipe := Recipe.new("farm", {}, {Commodity.Type.GRAIN: 1.6})
	var businesses: Dictionary[int, HEBusiness] = {1: HEBusiness.new(1, "Farm", farm_recipe, 50, 2)}
	settlement.business_ids.append(1)

	var h1 := HEHousehold.new(1, 1, 1, 100.0)
	h1.seed_worker_ages([HEHousehold.LIFESPAN_DAYS - 1])
	h1.seed_dependent_ages([0])
	h1.add_stock(Commodity.Type.GRAIN, 100.0)
	h1.add_stock(Commodity.Type.TIMBER, 100.0)
	h1.employer_business_id = 1

	var h2 := HEHousehold.new(2, 1, 0, 100.0)
	h2.seed_worker_ages([HEHousehold.AGING_THRESHOLD_DAYS])
	h2.add_stock(Commodity.Type.GRAIN, 100.0)
	h2.add_stock(Commodity.Type.TIMBER, 100.0)
	h2.employer_business_id = 1

	var households: Dictionary[int, HEHousehold] = {1: h1, 2: h2}
	settlement.household_ids.append(1)
	settlement.household_ids.append(2)
	return {"settlement": settlement, "households": households, "businesses": businesses}

func _total_worker_capacity(sim: HESimulation) -> int:
	var total := 0
	for household_id in sim.get_household_ids():
		total += sim.get_household_summary(household_id)["worker_capacity"]
	return total
