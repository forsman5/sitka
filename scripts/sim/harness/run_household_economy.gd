extends SceneTree

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEFixtures = preload("res://scripts/sim/harness/he_fixtures.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HEField = preload("res://scripts/sim/household_economy/records/he_field.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")
const HEMarket = preload("res://scripts/sim/household_economy/records/he_market.gd")
const Commodity =preload("res://scripts/sim/records/commodity.gd")
const Recipe = preload("res://scripts/sim/records/recipe.gd")
const HENeed = preload("res://scripts/sim/household_economy/records/he_need.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")
const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")

## H1 labor-market acceptance check. Run with:
##   godot --headless --script res://scripts/sim/harness/run_household_economy.gd

const SEED := 4242
const EPSILON := 0.01

var _ok := true

func _init() -> void:
	_check_determinism()
	_check_employment_index_matches_scan()
	_check_multi_settlement_locality()
	_check_conservation()
	_check_bloomery_smelting()
	_check_charcoal_burner_heats_households()
	_check_every_business_kind_is_buildable()
	_check_businesses_share_wood_with_households()
	_check_input_purchases_on_credit()
	_check_goods_flow_history_reconciles_with_stock()
	_check_market_supply_demand_history()
	_check_need_vs_funded_demand()
	_check_price_signal()
	_check_business_ledger_reconciles()
	_check_butcher_ledger_values_animals()
	_check_staffing_decisions()
	_check_staffing_outcomes()
	_check_trader_stays_solvent()
	_check_seller_trade_offers()
	_check_trader_bids()
	_check_trade_allocation_and_cash()
	_check_herd_export_path()
	_check_no_export_reserve_left()
	_check_local_iron_mine_supplies_bloomery_first()
	_check_trader_export_settings()
	_check_export_settings_derived_from_commodities()
	_check_bloomery_stays_off_when_not_seeded()
	_check_firing_is_logged_with_reason()
	_check_event_history_survives_busy_categories()
	_check_field_model_dynamics()
	_check_labor_self_tunes_toward_profitable_business()
	_check_trader_employment_does_not_churn_between_harvests()
	_check_emigration_actually_happens()
	_check_life_cycle_births_and_aging()
	_check_old_age_deaths_actually_happen()
	_check_old_age_orphans_get_adopted()
	_check_herds_grow_and_cull()
	_check_herd_cull_target_is_configurable()
	_check_herd_dynamic_cull()
	_check_herd_collateral_finances_wages()
	_check_herd_staffing_matters()
	_check_herd_monetization()
	_check_hardship_butchery_makes_local_meat()
	_check_cull_without_outlet_is_butchered_at_home()
	_check_livestock_goods()
	_check_livestock_export_toggle()
	_check_butcher_processes_livestock()
	_check_toolsmith_supplies_tools()
	_check_industrial_tools_model()
	_check_needs_catalog()
	_check_need_substitutes()
	_check_fuel_fallback()
	_check_government_taxes()
	_check_government_warehouse()
	_check_government_build_costs()
	_check_housing()
	_check_government_construction()
	_check_business_fails_at_credit_limit()
	_check_person_health_and_morale()
	_check_season_calendar()
	_check_seasonal_production()
	_check_winter_fodder_and_herd_outcomes()
	_check_seasons_conserve_and_stay_viable()

	if _ok:
		print("\nH1 acceptance: PASS")
	else:
		print("\nH1 acceptance: FAIL")
	quit(0 if _ok else 1)

## A business past its credit line is deleted (debt written off, staff laid
## off, no revival); one at zero workers is NOT, and stays at zero.
func _check_business_fails_at_credit_limit() -> void:
	print("\n=== Business failure: credit limit exhausted -> deleted, debt written off ===")
	var sim := _new_sim("build_three_business_economy")
	sim.advance_ticks(5)
	var woodlot_id := HEScenarioSeeds.WOODLOT_BUSINESS_ID
	var woodlot: HEBusiness = sim.businesses[woodlot_id]
	var employed := 0
	for h in sim.households.values():
		if (h as HEHousehold).employer_business_id == woodlot_id:
			employed += 1
	_assert(employed > 0, "Woodlot should have staff before failing")
	woodlot.balance = -1000000.0
	var debt := woodlot.balance
	sim.advance_ticks(1)
	_assert(not sim.businesses.has(woodlot_id), "A business past its credit limit should be deleted")
	_assert(not (sim.settlements[HEScenarioSeeds.SETTLEMENT_ID] as HESettlement).business_ids.has(woodlot_id), "Failed business should leave its settlement")
	for h in sim.households.values():
		_assert((h as HEHousehold).employer_business_id != woodlot_id, "No household should keep a deleted employer")
	var record: Dictionary = sim.get_daily_history(1)[0]
	_assert(absf(float(record["money_written_off"]) - debt) < EPSILON, "The debt should be written off (got %.1f)" % float(record["money_written_off"]))
	var expected: float = record["opening_money"] - float(record["money_written_off"]) + float(record["export_revenue"]) - float(record["import_cost"])
	_assert(absf(record["closing_money"] - expected) < EPSILON, "Money should still reconcile through a business failure")
	var failed_events := 0
	for event in sim.get_event_log_days(1):
		if event["type"] == "business_failed" and event["business_id"] == woodlot_id:
			failed_events += 1
	_assert(failed_events == 1, "A business failure should be logged exactly once")

	# A business recreated after closing gets a startup allowance (crew, cash,
	# grace) and must make it through its first harvest and keep staff.
	for kind in ["farm", "woodlot"]:
		var recreate := _new_sim("build_three_business_economy")
		recreate.advance_ticks(30)
		var old_id: int = HEScenarioSeeds.FARM_BUSINESS_ID if kind == "farm" else HEScenarioSeeds.WOODLOT_BUSINESS_ID
		(recreate.businesses[old_id] as HEBusiness).balance = -1000000.0
		recreate.advance_ticks(1)
		_assert(not recreate.businesses.has(old_id), "%s should have closed" % kind)
		var new_id := recreate.next_business_id()
		var fresh: HEBusiness = HEScenarioSeeds.make_farm(new_id, HEScenarioSeeds.SETTLEMENT_ID) if kind == "farm" else HEScenarioSeeds.make_woodlot(new_id, HEScenarioSeeds.SETTLEMENT_ID)
		recreate.add_new_business(fresh)
		recreate.advance_ticks(fresh.growth_days + 150)
		_assert(recreate.businesses.has(new_id), "A recreated %s should survive to and past its first harvest" % kind)
		if recreate.businesses.has(new_id):
			_assert(recreate._business_employed_worker_count(new_id) > 0, "A recreated %s should be staffed" % kind)
		print("  recreated %s: alive=%s employed=%d" % [kind, recreate.businesses.has(new_id), recreate._business_employed_worker_count(new_id) if recreate.businesses.has(new_id) else 0])

	# No zombies: the tuner never cuts a surviving business to zero (it keeps
	# its last worker until credit runs out), including the recreate-after-
	# closure case that used to strand a Woodlot at 0 forever.
	for builder in ["build_three_business_economy", "build_lopsided_start"]:
		var zombie := _new_sim(builder)
		zombie.advance_ticks(20)
		zombie.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID].balance = -1000000.0
		zombie.advance_ticks(1)
		var again: HEBusiness = HEScenarioSeeds.make_woodlot(zombie.next_business_id(), HEScenarioSeeds.SETTLEMENT_ID)
		zombie.add_new_business(again)
		var zero_days := 0
		for d in 700:
			zombie.advance_ticks(1)
			for id in zombie.businesses.keys():
				var zb: HEBusiness = zombie.businesses[id]
				# A livestock processor's crew follows its work (_livestock_crew_target)
				# and is legitimately zero while no ranch has anything to cull.
				if zb.kind != HEBusiness.Kind.GOVERNMENT and not zb.processes_livestock and zb.max_capacity > 0 and zb.capacity < 1:
					zero_days += 1
		_assert(zero_days == 0, "%s: a surviving business sat at zero capacity on %d business-days" % [builder, zero_days])

	# Zero workers alone never kills a business or brings staff back.
	var idle := _new_sim("build_three_business_economy")
	var idle_trader: HEBusiness = idle.businesses[HEScenarioSeeds.TRADER_BUSINESS_ID]
	idle_trader.capacity = 0
	idle_trader.max_capacity = 0
	idle.advance_ticks(120)
	_assert(idle.businesses.has(HEScenarioSeeds.TRADER_BUSINESS_ID), "A zero-worker business should not fail without debt")
	_assert(idle_trader.capacity == 0, "A zero-capacity business should not get a trial hire")
	print("  woodlot deleted at the credit limit with %.0f written off; a zero-worker Trader stayed at zero" % -debt)

func _new_sim(builder_method: String, price_adjustment_enabled: bool = true) -> HESimulation:
	var source = HEScenarioSeeds if builder_method == "build_two_settlement_economy" else HEFixtures
	return HESimulation.new(SEED, Callable(source, builder_method), price_adjustment_enabled)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_ok = false

func _check_person_health_and_morale() -> void:
	print("
=== Person health and morale ===")
	var sim := _new_sim("build_three_business_economy")
	sim.advance_ticks(200)
	var stressed_seen := false
	var child_seen := false
	for household_id in sim.get_household_ids():
		var h := sim.get_household_summary(household_id)
		_assert(h["health"] >= 0.0 and h["health"] <= 1.0 and h["morale"] >= 0.0 and h["morale"] <= HEHousehold.MORALE_MAX,
			"Household %d health/morale out of range" % household_id)
		if h["food_stress"] > 0.001:
			stressed_seen = true
			_assert(h["health"] < 1.0, "Household %d is food-stressed but at full health" % household_id)
		for member in range(1, h["headcount"] + 1):
			var p := sim.get_person_summary(household_id, member)
			_assert(not p.is_empty(), "Household %d member %d should exist" % [household_id, member])
			_assert(p["health"] <= h["health"] + 0.0001 or p["vulnerability"] <= 1.0,
				"A vulnerable member should not be healthier than their household")
			if p["life_stage"] == "Child":
				child_seen = true
	var any_id: int = sim.get_household_ids()[0]
	_assert(sim.get_person_summary(any_id, 0).is_empty(), "Member 0 should not exist")
	_assert(sim.get_person_summary(any_id, 9999).is_empty(), "Out-of-range member should not exist")
	print("  stressed household seen: %s, child seen: %s" % [stressed_seen, child_seen])

	# The business page reports the crew's morale and the output it earns.
	var crew_seen := false
	for report in sim.get_business_reports():
		if report["kind"] != "production" or not report.has("crew_morale"):
			continue
		var crew: Dictionary = report["crew_morale"]
		_assert(crew["multiplier"] >= 1.0 and crew["avg_morale"] >= 0.0 and crew["avg_morale"] <= HEHousehold.MORALE_MAX,
			"Business %s crew morale out of range" % report["name"])
		crew_seen = crew_seen or crew["workers"] > 0
	_assert(crew_seen, "A staffed production business should report its crew's morale")

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

## The lazily rebuilt employment index must equal an independent full scan
## after every mutation boundary: ordinary days, lifecycle churn (deaths,
## emigration, orphan adoption), a direct fixture write, and a failure.
func _check_employment_index_matches_scan() -> void:
	print("
=== Employment index ===")
	for builder in ["build_three_business_economy", "build_lopsided_start"]:
		var sim := _new_sim(builder)
		var mismatches := 0
		for day in range(400):
			sim.advance_ticks(1)
			if not sim.employment_index_matches_scan():
				mismatches += 1
		_assert(mismatches == 0, "%s: employment index diverged from scan on %d days" % [builder, mismatches])
		# Direct fixture write must be observed through the setter hook.
		var employed_id := -1
		for household_id in sim.get_household_ids():
			if sim.households[household_id].employer_business_id != -1:
				employed_id = household_id
				break
		if employed_id != -1:
			sim.employment_index_matches_scan()
			sim.households[employed_id].employer_business_id = -1
			_assert(sim.employment_index_matches_scan(), "%s: index stale after direct employer write" % builder)
		print("  %s: index matched scan every day for 400 days (%d rebuilds)" % [builder, sim._employment_rebuild_count])

func _check_multi_settlement_locality() -> void:
	print("\n=== Multi-settlement identity and locality ===")
	var sim := _new_sim("build_two_settlement_economy")
	_assert(sim.get_settlement_ids() == [1, 2], "Settlement IDs should enumerate in stable order")
	_assert(sim.get_household_ids(1) == [1001], "Northbank should expose only its own household")
	_assert(sim.get_household_ids(2) == [2001], "Southbank should expose only its own household")
	_assert(sim.get_business_reports(1).size() == 1 and sim.get_business_reports(1)[0]["business_id"] == 101,
		"Northbank should expose only its own business")
	_assert(sim.get_business_reports(2).size() == 1 and sim.get_business_reports(2)[0]["business_id"] == 201,
		"Southbank should expose only its own business")
	sim.advance_ticks(14)
	var north := sim.get_settlement_summary(1)
	var south := sim.get_settlement_summary(2)
	_assert(north["population"] == 4 and south["population"] == 4, "Each settlement summary should derive its own population")
	_assert(north["market"]["Grain"]["price"] != south["market"]["Grain"]["price"],
		"Disconnected settlements with different supply should develop independent prices")
	_assert(sim.get_household_summary(1001)["settlement_id"] == 1 and sim.get_household_summary(2001)["settlement_id"] == 2,
		"Every household summary should retain authoritative settlement identity")
	# Need history is per town, not valley-wide.
	var food: int = HENeed.Id.FOOD
	for town in [1, 2]:
		var household: HEHousehold = sim.households[sim.get_household_ids(town)[0]]
		var town_need: Dictionary = sim.get_market_report(town, Commodity.Type.GRAIN)["need"]
		var valley_total: float = sim.get_daily_history(1)[0]["needs"][food]["required"]
		_assert(absf(town_need["required_history"].back() - household.last_need_required[food]) < EPSILON, "Town %d need history should hold only its own households' requirement" % town)
		_assert(town_need["required_history"].back() < valley_total - EPSILON, "Town %d need history must not equal the valley-wide total" % town)
	print("  two settlements enumerate, hire, clear markets, and report independently")

## Goods and money reconcile as opening + produced - consumed - exported
## (goods) / opening - written_off + export_revenue - import_cost (money),
## across BOTH households and businesses; wages and market trades (and a
## Bloomery buying wood from the Woodlot -- still business-to-business) are
## transfers that net to zero; nothing goes negative. An emigration is one
## place value legitimately leaves the closed system, the Trader's exports
## are one place NEW money legitimately enters it, and the Trader importing
## a good like iron ore is the mirror-image place money legitimately LEAVES
## it (see he_simulation.gd's _export_revenue_total/_import_cost_total doc
## comments) -- all are explicitly logged rather than just silently not
## adding up, so the reconciliation formula accounts for them instead of
## ignoring them. This particular check's scenario has no Bloomery, so
## import_cost is always 0 here -- see _check_bloomery_smelting for the
## version of this same invariant with importing/smelting actually active.
func _check_conservation() -> void:
	print("\n=== Conservation: goods and money reconcile (write-offs/exports accounted), nothing negative ===")
	var sim := _new_sim("build_three_business_economy")
	sim.advance_ticks(365)
	var history := sim.get_daily_history(365)

	## Herds' culled animal stock (CATTLE/SHEEP) is produced (culling) and
	## exported (the Trader) exactly like a subsistence commodity, just with
	## no local consumption or write-off channel -- see he_simulation.gd's
	## HERD_EXPORT_PRICE doc comment for why it never joins
	## SUBSISTENCE_COMMODITIES itself. Checked here too so the new Trader
	## export pass is held to the same reconciliation bar as everything else.
	var reconciled_commodities := HESimulation.SUBSISTENCE_COMMODITIES.duplicate()
	reconciled_commodities.append_array(HESimulation.LIVESTOCK_GOODS)

	var worst_stock_gap := 0.0
	var worst_money_gap := 0.0
	for record in history:
		for c in reconciled_commodities:
			var name := Commodity.name_of(c)
			var opening: float = record["opening_stock"][name]
			var produced: float = record["produced"].get(name, 0.0)
			var consumed: float = record["consumed"].get(name, 0.0)
			var exported: float = (record["exported"] as Dictionary).get(name, 0.0)
			var written_off: float = (record["goods_written_off"] as Dictionary).get(c, 0.0)
			var closing: float = record["closing_stock"][name]
			var expected: float = opening + produced - consumed - exported - written_off
			worst_stock_gap = max(worst_stock_gap, abs(closing - expected))
		var expected_money: float = record["opening_money"] - float(record["money_written_off"]) + float(record["export_revenue"]) - float(record["import_cost"])
		worst_money_gap = max(worst_money_gap, abs(record["closing_money"] - expected_money))

	print("  worst stock reconciliation gap over 365 days: %.4f" % worst_stock_gap)
	print("  worst same-day money reconciliation gap over 365 days: %.4f" % worst_money_gap)
	_assert(worst_stock_gap < EPSILON, "Stock did not reconcile as opening + produced - consumed - written_off, worst gap %.4f" % worst_stock_gap)
	_assert(worst_money_gap < EPSILON, "Money did not reconcile as opening - written_off, worst gap %.4f" % worst_money_gap)

	# Households never carry the businesses' overdraft allowance -- their
	# balance must still never go negative. A business, though, is allowed
	# to run down to its own WAGE_NEGATIVE_BALANCE_FLOOR_DAYS floor (see
	# he_simulation.gd's HEWages.pay_wages) before wages get rationed, so its floor
	# -- not zero -- is the right bound to check here, same formula
	# _check_field_model_dynamics already uses.
	var min_stock := INF
	var min_household_balance := INF
	var worst_business_floor_breach := 0.0
	for household_id in sim.get_household_ids():
		var h := sim.get_household_summary(household_id)
		for name in h["inventory"].keys():
			min_stock = min(min_stock, h["inventory"][name])
		min_household_balance = min(min_household_balance, h["balance"])
	for report in sim.get_business_reports():
		min_stock = min(min_stock, report["stock"])
		# The floor scales with CURRENT employees, so a business that laid
		# everyone off still carrying a little debt from wages it legally
		# paid while staffed would read as a breach (floor 0). There is
		# nobody left to ration, so only check businesses that employ people.
		if report["employed_workers"] <= 0:
			continue
		# The business's ACTUAL overdraft limit (a ranch's is backed by its herd),
		# not the generic 60-day floor.
		var business: HEBusiness = sim.businesses[report["business_id"]]
		var floor: float = -sim.wages.overdraft_limit(business, report["reference_wage_per_worker"] * report["employed_workers"])
		worst_business_floor_breach = max(worst_business_floor_breach, floor - report["balance"])
	print("  minimum stock=%.3f, minimum household balance=%.3f, worst business wage-floor breach=%.4f" % [min_stock, min_household_balance, worst_business_floor_breach])
	_assert(min_stock >= -EPSILON, "Some stock went negative: %.4f" % min_stock)
	_assert(min_household_balance >= -EPSILON, "Some household balance went negative: %.4f" % min_household_balance)
	_assert(worst_business_floor_breach < EPSILON, "A business balance dropped below its own generous wage floor by %.4f" % worst_business_floor_breach)

## No woodlot reserve for households: the Bloomery buys wood as a market
## participant alongside them. Households may go short while the Woodlot's
## workforce and price catch up, but over the long run both are served.
func _check_businesses_share_wood_with_households() -> void:
	print("\n=== Wood: businesses and households share the Woodlot's offer, no household reserve ===")
	var sim := _new_sim("build_three_business_economy_with_bloomery")
	var early_demand := 0.0
	var early_got := 0.0
	var late_demand := 0.0
	var late_got := 0.0
	var bloomery_wood_bought := 0.0
	for day in 600:
		sim.advance_ticks(1)
		for household_id in sim.households.keys():
			var h = sim.households[household_id]
			var demand: float = h.last_need_required.get(HENeed.Id.HEAT, 0.0)
			var got: float = h.last_need_provided.get(HENeed.Id.HEAT, 0.0)
			if day < 120:
				early_demand += demand
				early_got += got
			elif day >= 360:
				late_demand += demand
				late_got += got
	for record in sim.get_daily_history(600):
		bloomery_wood_bought += (record["consumed"] as Dictionary).get("Timber", 0.0)
	print("  household wood fulfilment: days 0-120=%.0f%%, days 360-600=%.0f%% (Bloomery + households consumed %.1f timber)" % [
		100.0 * early_got / maxf(early_demand, EPSILON), 100.0 * late_got / maxf(late_demand, EPSILON), bloomery_wood_bought])
	_assert(late_got >= late_demand * 0.9,
		"Households should get >=90%% of their wood in the long run without a reserve -- got %.1f of %.1f" % [late_got, late_demand])
	_assert(early_got > 0.0, "Households should buy some wood even in the first 120 days")

## Wages run on credit down to a floor, so inputs must too: a staffed business
## whose balance dipped below zero used to be unable to buy anything, so it
## produced nothing and never earned its way back. Credit stops at the same
## wage floor, so a business at the floor is still locked out.
func _check_input_purchases_on_credit() -> void:
	print("\n=== Inputs on credit: a business in debt can restock, but not past its wage floor ===")
	var timber := Commodity.Type.TIMBER
	var in_debt := _new_sim("build_economy_with_bloomery_and_iron_mine")
	var bloomery: HEBusiness = in_debt.businesses[HEScenarioSeeds.BLOOMERY_BUSINESS_ID]
	var settlement_id: int = in_debt.get_settlement_ids()[0]
	var employed := in_debt._business_employed_worker_count(bloomery.id)
	var wage_floor: float = -HESimulation.WAGE_NEGATIVE_BALANCE_FLOOR_DAYS * in_debt.wages.reference_wage_per_worker(settlement_id) * employed
	in_debt.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID].inventory = {timber: 5000.0}
	in_debt.businesses[HEScenarioSeeds.IRON_MINE_BUSINESS_ID].inventory = {Commodity.Type.IRON_ORE: 5000.0}
	bloomery.inventory = {}
	bloomery.balance = -10.0
	in_debt._run_input_purchasing(in_debt._new_daily_record())
	print("  in debt (-10, floor %.0f): bought %.1f timber, balance now %.1f, input fulfilment %.2f" % [wage_floor, bloomery.stock(timber), bloomery.balance, bloomery.last_input_fulfillment_ratio])
	_assert(bloomery.stock(timber) > 0.0, "A staffed business in debt should still be able to buy inputs on credit")
	_assert(bloomery.last_input_fulfillment_ratio > 0.0, "A business restocked on credit should be able to produce")
	_assert(bloomery.balance >= wage_floor - EPSILON, "Credit must stop at the wage floor %.1f, balance reached %.1f" % [wage_floor, bloomery.balance])

	var at_floor := _new_sim("build_economy_with_bloomery_and_iron_mine")
	var stuck: HEBusiness = at_floor.businesses[HEScenarioSeeds.BLOOMERY_BUSINESS_ID]
	at_floor.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID].inventory = {timber: 5000.0}
	at_floor.businesses[HEScenarioSeeds.IRON_MINE_BUSINESS_ID].inventory = {Commodity.Type.IRON_ORE: 5000.0}
	stuck.inventory = {}
	stuck.balance = wage_floor
	at_floor._run_input_purchasing(at_floor._new_daily_record())
	print("  at the floor: bought %.2f timber" % stuck.stock(timber))
	_assert(stuck.stock(timber) <= 0.0001, "A business at its wage floor has no credit left to buy inputs with")

## The detail tab's goods-flow charts: every production business reports a
## history per flow, and those histories must reconcile with its own storage
## -- end stock = start stock + produced - sold for its output, and
## + bought - consumed for each input. Run shorter than the history window
## so nothing has been trimmed off the front yet.
func _check_goods_flow_history_reconciles_with_stock() -> void:
	print("\n=== Production business goods-flow histories reconcile with storage ===")
	var sim := _new_sim("build_three_business_economy_with_bloomery")
	var start_stock := {}
	for business_id in sim.businesses.keys():
		var b: HEBusiness = sim.businesses[business_id]
		if b.kind != HEBusiness.Kind.PRODUCTION:
			continue
		start_stock[business_id] = {}
		for commodity in b.recipe.outputs.keys() + b.recipe.inputs.keys():
			start_stock[business_id][Commodity.name_of(commodity)] = b.stock(commodity)
	var days := 60
	sim.advance_ticks(days)

	var checked := 0
	for report in sim.get_business_reports():
		if report["kind"] != "production":
			_assert(not report.has("flow_history"), "%s is not a production business and should report no flow_history" % report["name"])
			continue
		# This check assumes one output good and recipe inputs; the Butcher has
		# two outputs and live-animal inputs, and is checked in
		# _check_butcher_processes_livestock.
		if (sim.businesses[report["business_id"]] as HEBusiness).processes_livestock:
			continue
		var flows: Dictionary = report["flow_history"]
		var output_name: String = report["output_commodity"]
		_assert(flows[HEBusiness.FLOW_PRODUCED].size() == 1, "%s has one output good, expected 1 produced series" % report["name"])
		_assert(flows[HEBusiness.FLOW_PRODUCED][0]["commodity"] == output_name, "%s produced series should be its output commodity" % report["name"])
		_assert((flows[HEBusiness.FLOW_PRODUCED][0]["values"] as Array).size() == days, "%s produced series should have one entry per day" % report["name"])

		# The inventory chart is the running total of the other two output
		# lines: each day's change in stock is produced minus sold.
		var stock_series: Array = flows[HEBusiness.LEVEL_STOCK]
		_assert(stock_series.size() == 1 and stock_series[0]["commodity"] == output_name, "%s should report one stock series, its output good" % report["name"])
		var stock_values: Array = stock_series[0]["values"]
		_assert(stock_values.size() == days, "%s stock series should have one entry per day" % report["name"])
		_assert(absf(stock_values[days - 1] - float(report["stock"])) < EPSILON, "%s last stock point %.3f should equal reported stock %.3f" % [report["name"], stock_values[days - 1], report["stock"]])
		var sold_values: Array = flows[HEBusiness.FLOW_SOLD][0]["values"] if not (flows[HEBusiness.FLOW_SOLD] as Array).is_empty() else []
		var worst_delta_gap := 0.0
		for i in range(1, days):
			var sold_today: float = sold_values[i] if i < sold_values.size() else 0.0
			var delta: float = stock_values[i] - stock_values[i - 1]
			worst_delta_gap = maxf(worst_delta_gap, absf(delta - (flows[HEBusiness.FLOW_PRODUCED][0]["values"][i] - sold_today)))
		_assert(worst_delta_gap < EPSILON, "%s daily stock change should equal produced - sold, worst gap %.4f" % [report["name"], worst_delta_gap])

		var closing := {output_name: report["stock"]}
		for input_name in (report["input_inventory"] as Dictionary).keys():
			closing[input_name] = report["input_inventory"][input_name]
		var net := {}
		for flow in HEBusiness.ALL_FLOWS:
			var direction := 1.0 if flow in [HEBusiness.FLOW_PRODUCED, HEBusiness.FLOW_BOUGHT] else -1.0
			for entry in flows[flow]:
				_assert((entry["values"] as Array).size() == days, "%s %s/%s series should have one entry per day" % [report["name"], flow, entry["commodity"]])
				for v in entry["values"]:
					net[entry["commodity"]] = net.get(entry["commodity"], 0.0) + direction * v
		for good in closing.keys():
			var expected: float = start_stock[report["business_id"]][good] + net.get(good, 0.0)
			_assert(absf(closing[good] - expected) < EPSILON, "%s %s stock %.3f should equal start + flows %.3f" % [report["name"], good, closing[good], expected])
		_assert((flows[HEBusiness.FLOW_SOLD] as Array).size() > 0, "%s should have sold some %s in %d days" % [report["name"], output_name, days])
		if not (report["input_inventory"] as Dictionary).is_empty():
			_assert((flows[HEBusiness.FLOW_CONSUMED] as Array).size() > 0 and (flows[HEBusiness.FLOW_BOUGHT] as Array).size() > 0, "%s has inputs and should show both consumed and bought series" % report["name"])
		checked += 1
	_assert(checked > 0, "Scenario should contain at least one production business")

## Charcoal enters as a second heat satisfier: the burner must actually
## produce, households and the Bloomery must burn it, and goods/money must
## still reconcile with it in play.
func _check_charcoal_burner_heats_households() -> void:
	print("\n=== Charcoal Burner: timber becomes charcoal, households and the Bloomery heat with it ===")
	var sim := _new_sim("build_economy_with_charcoal_burner")
	sim.advance_ticks(365)
	var history := sim.get_daily_history(365)

	var charcoal_produced := 0.0
	var charcoal_burned := 0.0
	var timber_burned := 0.0
	var worst_stock_gap := 0.0
	var worst_money_gap := 0.0
	for record in history:
		charcoal_produced += (record["produced"] as Dictionary).get("Charcoal", 0.0)
		charcoal_burned += (record["consumed"] as Dictionary).get("Charcoal", 0.0)
		timber_burned += (record["consumed"] as Dictionary).get("Timber", 0.0)
		for c in HESimulation.SUBSISTENCE_COMMODITIES:
			var name := Commodity.name_of(c)
			var expected: float = record["opening_stock"][name] + (record["produced"] as Dictionary).get(name, 0.0) \
				- (record["consumed"] as Dictionary).get(name, 0.0) - (record["exported"] as Dictionary).get(name, 0.0) \
				- (record["goods_written_off"] as Dictionary).get(c, 0.0)
			worst_stock_gap = max(worst_stock_gap, abs(record["closing_stock"][name] - expected))
		var expected_money: float = record["opening_money"] - float(record["money_written_off"]) + float(record["export_revenue"]) - float(record["import_cost"])
		worst_money_gap = max(worst_money_gap, abs(record["closing_money"] - expected_money))

	print("  over 365 days: charcoal produced=%.1f, charcoal burned=%.1f, timber burned/used=%.1f" % [charcoal_produced, charcoal_burned, timber_burned])
	print("  worst stock reconciliation gap: %.4f, worst money gap: %.4f" % [worst_stock_gap, worst_money_gap])
	_assert(charcoal_produced > 0.0, "Charcoal Burner should have produced charcoal")
	_assert(charcoal_burned > 0.0, "Households or the Bloomery should have burned charcoal as fuel")
	_assert(worst_stock_gap < EPSILON, "Goods did not reconcile with charcoal in play, worst gap %.4f" % worst_stock_gap)
	_assert(worst_money_gap < EPSILON, "Money did not reconcile with charcoal in play, worst gap %.4f" % worst_money_gap)

	# Households start with weeks of timber in hand, so check the first
	# couple of months of a fresh run for the switch rather than year-end.
	var fresh := _new_sim("build_economy_with_charcoal_burner")
	var household_charcoal := 0.0
	for day in 60:
		fresh.advance_ticks(1)
		for household_id in fresh.get_household_ids():
			household_charcoal += _household_satisfier_used(fresh.get_household_summary(household_id), "Heat", "Charcoal")
	print("  charcoal burned by households over the first 60 days: %.2f" % household_charcoal)
	_assert(household_charcoal > 0.0, "Households should be heating with charcoal once the burner is selling")

## Every kind of business the sim can seed must be registered in
## HEScenarioSeeds.business_types() -- the one list the dashboard's Create menu
## and the setup page are built from -- so a new business kind cannot be added
## to the world but silently left out of either. Also builds each registered
## kind mid-run, the way the Create menu does, to prove its factory works.
func _check_every_business_kind_is_buildable() -> void:
	print("\n=== Every business kind is in the Create menu / setup registry ===")
	var types := HEScenarioSeeds.business_types()
	var ids: Array = []
	var type_keys := {}
	for entry in types:
		ids.append(entry["id"])
		_assert(not type_keys.has(entry["type_key"]), "Duplicate business type_key '%s' in the registry" % entry["type_key"])
		type_keys[entry["type_key"]] = entry["id"]

	# A world seeded with every registered kind: whatever it contains beyond
	# the Government must be in the registry, under the id it was seeded with.
	var full := HESimulation.new(SEED, Callable(HEFixtures, "build_custom").bind(ids), true)
	var unregistered: Array[String] = []
	for business_id in full.businesses.keys():
		var b: HEBusiness = full.businesses[business_id]
		if b.kind == HEBusiness.Kind.GOVERNMENT:
			continue
		if not type_keys.has(b.type_key) or type_keys[b.type_key] != business_id:
			unregistered.append("%s (id %d, type_key '%s')" % [b.name, business_id, b.type_key])
	_assert(unregistered.is_empty(), "Seeded businesses missing from HEScenarioSeeds.business_types(): %s" % ", ".join(unregistered))
	_assert(full.businesses.size() - 1 == types.size(), "Seeding every registered kind should create exactly one business each (plus the Government)")

	# Each kind, built mid-run into a town that has none of the optional ones.
	var sim := HESimulation.new(SEED, Callable(HEFixtures, "build_custom").bind([HEScenarioSeeds.FARM_BUSINESS_ID, HEScenarioSeeds.WOODLOT_BUSINESS_ID]), true)
	var settlement_id: int = sim.get_settlement_ids()[0]
	var created := 0
	for entry in types:
		if sim.has_business_of_type(settlement_id, entry["type_key"]):
			continue
		var business: HEBusiness = entry["make"].call(sim.next_business_id(), settlement_id)
		_assert(business != null and business.type_key == entry["type_key"], "%s's factory should build a business carrying its own type_key" % entry["label"])
		sim.add_new_business(business)
		_assert(sim.has_business_of_type(settlement_id, entry["type_key"]), "%s should exist after being created" % entry["label"])
		created += 1
	sim.advance_ticks(60)
	print("  %d kinds registered; %d built mid-run and the sim ran 60 days" % [types.size(), created])
	_assert(created == types.size() - 2, "Every kind except the seeded Farm and Woodlot should have been creatable")

## How much of `satisfier` a household spent today on the need labelled
## `need_label`, read from the summary's per-need list.
func _household_satisfier_used(summary: Dictionary, need_label: String, satisfier: String) -> float:
	for need in summary["needs"]:
		if need["label"] == need_label:
			for entry in need["satisfiers"]:
				if entry["name"] == satisfier:
					return entry["consumed"]
	return 0.0

func _check_market_supply_demand_history() -> void:
	print("\n=== Market detail carries a rolling supplied/requested history ===")
	var sim := _new_sim("build_three_business_economy_with_bloomery")
	sim.advance_ticks(100)
	var settlement_id: int = sim.get_settlement_ids()[0]
	var window := HEMarket.SUPPLY_DEMAND_HISTORY_WINDOW_DAYS
	var any_activity := false
	for commodity in sim.markets[settlement_id].price.keys():
		var report := sim.get_market_detail(settlement_id, commodity)
		var supplied: Array = report["supplied_history"]
		var demanded: Array = report["demanded_history"]
		# One point per simulated day, capped at the window: 100 days in, 100 points.
		var expected_days := mini(window, 100)
		_assert(supplied.size() == expected_days and demanded.size() == expected_days, "%s history should hold one point per day (%d), got %d/%d" % [Commodity.name_of(commodity), expected_days, supplied.size(), demanded.size()])
		for v in supplied + demanded:
			if v > 0.0:
				any_activity = true
	_assert(any_activity, "At least one market should show nonzero supply or demand over 100 days")

	# Ore moves Iron Mine -> Bloomery directly (no Trader import), and that
	# local business-to-business sale must still show up in the ore market.
	var mine_sim := _new_sim("build_economy_with_bloomery_and_iron_mine")
	mine_sim.advance_ticks(60)
	var mine_settlement_id: int = mine_sim.get_settlement_ids()[0]
	var ore_report := mine_sim.get_market_detail(mine_settlement_id, Commodity.Type.IRON_ORE)
	var ore_supplied := 0.0
	var ore_requested := 0.0
	for v in ore_report["supplied_history"]:
		ore_supplied += v
	for v in ore_report["demanded_history"]:
		ore_requested += v
	_assert(ore_supplied > 0.0, "Iron Mine -> Bloomery ore sales should appear as supplied in the ore market")
	_assert(ore_requested > 0.0, "Bloomery ore purchases should appear as requested in the ore market")

	# Export appetite: the Trader's remaining capacity, not the amount shipped.
	var export_sim := _new_sim("build_economy_with_bloomery_and_iron_mine")
	export_sim.set_trader_export_enabled(HEScenarioSeeds.TRADER_BUSINESS_ID, Commodity.Type.IRON_ORE, true)
	export_sim.advance_ticks(60)
	var export_report := export_sim.get_market_detail(export_sim.get_settlement_ids()[0], Commodity.Type.IRON_ORE)
	var plain: Array = export_report["demanded_history"]
	var with_appetite: Array = export_report["demanded_with_export_history"]
	_assert(plain.size() == with_appetite.size(), "Both demand series should cover the same days")
	var appetite_higher_somewhere := false
	for i in plain.size():
		_assert(with_appetite[i] >= plain[i] - EPSILON, "Export appetite series should never fall below executed demand (day index %d)" % i)
		if with_appetite[i] > plain[i] + EPSILON:
			appetite_higher_somewhere = true
	_assert(appetite_higher_somewhere, "With ore export enabled, appetite should exceed shipped quantity on some day")
	var off_report := mine_sim.get_market_detail(mine_settlement_id, Commodity.Type.IRON_ORE)
	_assert(off_report["demanded_with_export_history"] == off_report["demanded_history"], "With export disabled, both demand series should match")

## Need, wanted-for-stock, affordable and bought are four different numbers.
## Each case sets every household into one state, clears one day's market, and
## checks how the household-only signals diverge.
func _check_need_vs_funded_demand() -> void:
	print("\n=== Household demand signals: wanted vs affordable vs bought ===")
	var grain := Commodity.Type.GRAIN
	var cases := {
		"no cash": {"balance": 0.0, "household_stock": 0.0, "seller_stock": 1000.0},
		"cash but no supply": {"balance": 1000.0, "household_stock": 0.0, "seller_stock": 0.0},
		"already stocked": {"balance": 1000.0, "household_stock": 1000.0, "seller_stock": 1000.0},
		"cash and supply": {"balance": 1000.0, "household_stock": 0.0, "seller_stock": 1000.0},
	}
	for label in cases.keys():
		var c: Dictionary = cases[label]
		var sim := _new_sim("build_three_business_economy")
		var settlement_id: int = sim.get_settlement_ids()[0]
		for household_id in sim.get_household_ids():
			var h: HEHousehold = sim.households[household_id]
			h.inventory.clear()
			if c["household_stock"] > 0.0:
				h.add_stock(grain, c["household_stock"])
			h.balance = c["balance"]
		var seller := sim._business_selling(settlement_id, grain)
		seller.inventory.clear()
		if c["seller_stock"] > 0.0:
			seller.add_stock(grain, c["seller_stock"])
		var market: HEMarket = sim.markets[settlement_id]
		var offer: float = sim._household_offer(settlement_id, grain)
		sim._run_market(sim._new_daily_record())
		var d := market.household_demand(grain)
		print("  %-20s wanted=%.1f affordable=%.1f bought=%.1f" % [label, d["wanted"], d["funded"], d["bought"]])
		_assert(d["funded"] <= d["wanted"] + EPSILON, "%s: affordable cannot exceed wanted" % label)
		_assert(d["bought"] <= d["funded"] + EPSILON, "%s: bought cannot exceed affordable" % label)
		match label:
			"no cash":
				_assert(d["wanted"] > 1.0 and d["funded"] < EPSILON and d["bought"] < EPSILON, "No cash: wanted but nothing affordable or bought")
			"cash but no supply":
				_assert(d["wanted"] > 1.0 and absf(d["funded"] - d["wanted"]) < EPSILON and d["bought"] < EPSILON, "No supply: fully affordable but nothing bought")
			"already stocked":
				_assert(d["wanted"] < EPSILON and d["funded"] < EPSILON and d["bought"] < EPSILON, "Stocked households want nothing")
			"cash and supply":
				_assert(d["bought"] > 1.0 and absf(d["bought"] - minf(offer, d["funded"])) < EPSILON, "Cash and supply: bought is the funded request capped by the (paced) offer")
		# A stocked household still NEEDS grain; need is independent of wanting.
		sim._run_consumption(sim._new_daily_record())
		var any_household: HEHousehold = sim.households[sim.get_household_ids()[0]]
		_assert(any_household.last_need_required.get(HENeed.Id.FOOD, 0.0) > 0.0, "%s: food is still required regardless of cash or stock" % label)
		_assert(not sim._market_need_report(settlement_id, grain).is_empty(), "%s: grain should map to the food need" % label)

	# Histories align by day, and a shared need is reported once, not per good.
	var run := _new_sim("build_economy_with_charcoal_burner")
	run.advance_ticks(60)
	var settlement: int = run.get_settlement_ids()[0]
	var report := run.get_market_report(settlement, Commodity.Type.TIMBER)
	var wanted: Array = report["household_wanted_history"]
	var funded: Array = report["household_funded_history"]
	var bought: Array = report["household_bought_history"]
	var plain: Array = report["demanded_history"]
	_assert(wanted.size() == plain.size() and funded.size() == plain.size() and bought.size() == plain.size(), "Household series should have one point per day like the existing ones")
	for i in wanted.size():
		_assert(funded[i] <= wanted[i] + EPSILON and bought[i] <= funded[i] + EPSILON, "Day %d: wanted >= affordable >= bought" % i)
		_assert(bought[i] <= plain[i] + EPSILON, "Day %d: household purchases fit within all-buyer affordable requests" % i)
	var timber_need: Dictionary = report["need"]
	var charcoal_need: Dictionary = run.get_market_report(settlement, Commodity.Type.CHARCOAL)["need"]
	_assert(timber_need["id"] == charcoal_need["id"] and timber_need["required_history"] == charcoal_need["required_history"], "Timber and charcoal should report the same heat requirement")
	_assert(timber_need["required_history"].size() == plain.size(), "Need history should cover the same days as market history")
	var record: Dictionary = run.get_daily_history(1)[0]
	_assert(absf(timber_need["required_history"].back() - record["needs"][timber_need["id"]]["required"]) < EPSILON, "Need history's last point is the latest day's requirement")
	print("  histories align over %d days; heat need reported once for timber and charcoal" % plain.size())

## One controlled grain market day: every household has this balance and no
## stock, the grain seller holds exactly this much, then clear and price.
func _run_grain_day(sim: HESimulation, settlement_id: int, balance: float, seller_stock: float) -> void:
	for household_id in sim.get_household_ids():
		var h: HEHousehold = sim.households[household_id]
		h.inventory.clear()
		h.balance = balance
	var seller := sim._business_selling(settlement_id, Commodity.Type.GRAIN)
	seller.inventory.clear()
	seller.add_stock(Commodity.Type.GRAIN, seller_stock)
	sim._run_market(sim._new_daily_record())
	sim._apply_price_signals()

## One price move per good per day: funded shortage up, unsold offer down,
## need without purchasing power neither, exports outside the signal.
func _check_price_signal() -> void:
	print("\n=== Price signal: funded shortage up, unsold down, unfunded need neutral ===")
	var grain := Commodity.Type.GRAIN
	var cases := {
		"funded shortage": {"balance": 1000.0, "seller_stock": 10.0},
		"unsold offer": {"balance": 1000.0, "seller_stock": 100000.0},
		"unfunded households": {"balance": 0.0, "seller_stock": 1000.0},
		"no supply, no cash": {"balance": 0.0, "seller_stock": 0.0},
	}
	for label in cases.keys():
		var c: Dictionary = cases[label]
		var sim := _new_sim("build_three_business_economy")
		var settlement_id: int = sim.get_settlement_ids()[0]
		var market: HEMarket = sim.markets[settlement_id]
		for household_id in sim.get_household_ids():
			var h: HEHousehold = sim.households[household_id]
			h.inventory.clear()
			h.balance = c["balance"]
		var seller := sim._business_selling(settlement_id, grain)
		seller.inventory.clear()
		if c["seller_stock"] > 0.0:
			seller.add_stock(grain, c["seller_stock"])
		var opening: float = market.price[grain]
		sim._run_market(sim._new_daily_record())
		_assert(market.price[grain] == opening, "%s: price must not move during clearing" % label)
		sim._apply_price_signals()
		var closing: float = market.price[grain]
		var s: Dictionary = market.last_price_signal.get(grain, {})
		_assert(not s.is_empty() and s["opening_price"] == opening and s["closing_price"] == closing, "%s: signal records opening and closing price" % label)
		print("  %-20s %.3f -> %.3f  %s (shortage %.1f, unsold %.1f, unfunded household %.1f)" % [label, opening, closing, s.get("reason", "?"), s.get("shortage", 0.0), s.get("unsold", 0.0), s.get("unfunded_household", 0.0)])
		_assert(absf(closing / opening - 1.0) <= HESimulation.PRICE_ADJUST_STEP + 0.00001, "%s: one day's move is capped" % label)
		match label:
			"funded shortage":
				_assert(closing > opening and s["shortage"] > 1.0 and s["reason"] == "funded shortage", "A funded shortage should raise the price")
			"unsold offer":
				_assert(closing < opening and s["unsold"] > 1.0 and s["reason"] == "unsold offer", "Unsold offer should lower the price")
			"unfunded households":
				_assert(closing < opening and s["unfunded_household"] > 1.0 and s["shortage"] < EPSILON, "Households that want but cannot pay leave offer unsold: price falls, never rises")
			"no supply, no cash":
				_assert(closing == opening and s["reason"] == "no activity", "Need without purchasing power or supply should not move the price")

	# Smoothing: a persistent shortage keeps raising the price, but a single
	# shortage day in the middle of a glut trend does not reverse it.
	var persistent := _new_sim("build_three_business_economy")
	var p_settlement: int = persistent.get_settlement_ids()[0]
	var p_market: HEMarket = persistent.markets[p_settlement]
	var start: float = p_market.price[grain]
	for d in 3:
		_run_grain_day(persistent, p_settlement, 1000.0, 10.0)
	var after_three: float = p_market.price[grain]
	_assert(after_three > start, "A persistent funded shortage keeps raising the price")
	var trend := _new_sim("build_three_business_economy")
	var t_settlement: int = trend.get_settlement_ids()[0]
	for d in 5:
		_run_grain_day(trend, t_settlement, 1000.0, 100000.0)
	var before_blip: float = trend.markets[t_settlement].price[grain]
	_run_grain_day(trend, t_settlement, 1000.0, 10.0)
	_assert(trend.markets[t_settlement].price[grain] < before_blip, "One shortage day should not reverse a falling trend")

	# A business's 14-day buffer refill is a planning figure; only its 3-day
	# claim competes for today's offer and counts toward the price signal.
	var biz := _new_sim("build_economy_with_charcoal_burner")
	var b_settlement: int = biz.get_settlement_ids()[0]
	# No household demand: businesses may take the whole offer, and the signal
	# must agree with what they actually bought.
	for household_id in biz.get_household_ids():
		biz.households[household_id].balance = 0.0
	var timber_before: float = biz.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID].stock(Commodity.Type.TIMBER)
	biz._run_input_purchasing(biz._new_daily_record())
	var timber_sold: float = timber_before - biz.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID].stock(Commodity.Type.TIMBER)
	biz._run_market(biz._new_daily_record())
	var timber_signal: Dictionary = biz._price_signal_today[b_settlement][Commodity.Type.TIMBER]
	_assert(timber_signal["funded_business"] >= timber_sold - EPSILON, "Signal demand (%.1f) must cover what businesses actually bought (%.1f)" % [timber_signal["funded_business"], timber_sold])
	_assert(timber_sold < timber_signal["funded_business"] + EPSILON, "Businesses cannot buy more than their capped request")
	# Timber starts at zero in every buyer's hands, so the claim is exactly
	# TARGET_BUFFER_DAYS of the PRODUCTION_INPUT_BUFFER_DAYS refill.
	var claim_share: float = HESimulation.TARGET_BUFFER_DAYS / HESimulation.PRODUCTION_INPUT_BUFFER_DAYS
	_assert(timber_signal["funded_business"] > EPSILON, "Test setup: businesses should be asking for timber")
	_assert(absf(timber_signal["funded_business"] - timber_signal["business_buffer_request"] * claim_share) < 0.01 * timber_signal["business_buffer_request"], "Signal demand (%.1f) should be the %.0f-day claim, not the full buffer refill (%.1f)" % [timber_signal["funded_business"], HESimulation.TARGET_BUFFER_DAYS, timber_signal["business_buffer_request"]])

	# Import capacity is not unsold local supply: the Trader's unused capacity
	# must never push the ore price down, and imports that met the request
	# create no pressure.
	var imp := _new_sim("build_three_business_economy_with_bloomery")
	var imp_market: HEMarket = imp.markets[imp.get_settlement_ids()[0]]
	var ore_signal: Dictionary = {}
	# The Bloomery buys ore on the days its buffer needs topping up, so wait for one.
	for day in 80:
		imp.advance_ticks(1)
		ore_signal = imp_market.last_price_signal.get(Commodity.Type.IRON_ORE, {})
		if not ore_signal.is_empty() and ore_signal["funded_business"] > EPSILON:
			break
	print("  ore signal: %s" % [ore_signal])
	_assert(not ore_signal.is_empty() and ore_signal["import_capacity"] > ore_signal["funded_business"], "Test setup: ore should be imported with spare Trader capacity")
	_assert(ore_signal.get("unsold", 1.0) < EPSILON, "Spare import capacity must not read as unsold supply")

	# Exports are not local demand: iron (only the Trader buys it) has no
	# signal and keeps its posted price while exporting.
	var iron_sim := _new_sim("build_three_business_economy_with_bloomery")
	iron_sim.advance_ticks(60)
	var iron_market: HEMarket = iron_sim.markets[iron_sim.get_settlement_ids()[0]]
	_assert(iron_market.price[Commodity.Type.IRON] == HESimulation.BASE_PRICE[Commodity.Type.IRON], "Export appetite must not move iron's local price")

	# Price bounds: a long glut hits the floor and the day count is recorded.
	var glut := _new_sim("build_three_business_economy")
	var g_settlement: int = glut.get_settlement_ids()[0]
	for d in 120:
		for household_id in glut.get_household_ids():
			glut.households[household_id].balance = 0.0
		glut._business_selling(g_settlement, grain).add_stock(grain, 100000.0)
		glut._run_market(glut._new_daily_record())
		glut._apply_price_signals()
	_assert(glut.markets[g_settlement].floor_days.get(grain, 0) > 0, "A persistent glut should record days at the price floor")
	print("  persistent shortage 3 days: %.3f -> %.3f; glut floor days: %d" % [start, after_three, glut.markets[g_settlement].floor_days.get(grain, 0)])

## Operating ledger: every cash movement of a business lands under its own
## heading, the day's cash profit reconciles to the balance change (less any
## startup cash), and stock accumulation is a separate figure that moves on its
## own -- so a business's books can be read without inferring costs from its
## balance.
func _check_business_ledger_reconciles() -> void:
	print("\n=== Operating ledger: cash profit reconciles to balance; stock change kept apart ===")
	var sim := _new_sim("build_economy_with_charcoal_burner")
	sim.advance_ticks(150)
	var worst_gap := 0.0
	var rows_checked := 0
	var stock_moved := false
	var cash_and_stock_differ := false
	var kinds_with_sales := {}
	for business_id in sim.businesses.keys():
		var b: HEBusiness = sim.businesses[business_id]
		var rows := b.ledger_history()
		for i in range(1, rows.size()):
			var balance_change: float = rows[i]["balance"] - rows[i - 1]["balance"]
			worst_gap = maxf(worst_gap, absf(balance_change - (rows[i]["cash_profit"] + rows[i]["injection"])))
			rows_checked += 1
			if absf(rows[i]["stock_change_value"]) > 0.01:
				stock_moved = true
				if absf(rows[i]["stock_change_value"] - rows[i]["cash_profit"]) > 0.01:
					cash_and_stock_differ = true
			for key in ["sales_household", "sales_business", "sales_export", "input_local", "input_import", "wages", "taxes", "trade_margin", "tax_income"]:
				if rows[i][key] > 0.0:
					kinds_with_sales[key] = true
	print("  %d business-days reconciled, worst gap %.4f; headings used: %s" % [rows_checked, worst_gap, kinds_with_sales.keys()])
	_assert(rows_checked > 500, "Expected many ledger rows, got %d" % rows_checked)
	_assert(worst_gap < EPSILON, "Ledger cash profit should equal the balance change, worst gap %.4f" % worst_gap)
	_assert(stock_moved and cash_and_stock_differ, "Stock accumulation should be its own figure, not folded into cash profit")
	for key in ["sales_household", "sales_business", "sales_export", "input_local", "wages", "taxes", "trade_margin", "tax_income"]:
		_assert(kinds_with_sales.has(key), "Ledger heading %s never recorded anything in 150 days" % key)

## A Butcher that really processes head: the animals it uses up are costed at
## what it pays a ranch (the livestock quote), not at zero, and the ledger row of
## the day it works includes a review's wool and culls when one lands that day.
func _check_butcher_ledger_values_animals() -> void:
	print("\n=== Ledger: a Butcher's animals are valued at what it paid ===")
	var sim := _new_sim("build_economy_with_charcoal_burner")
	var butcher: HEBusiness = null
	for business_id in sim.businesses.keys():
		if (sim.businesses[business_id] as HEBusiness).processes_livestock:
			butcher = sim.businesses[business_id]
	_assert(butcher != null, "Test setup: the scenario should include a Butcher")
	if butcher == null:
		return
	var seated := 0
	for household_id in sim.get_household_ids():
		if seated >= 4:
			break
		var h: HEHousehold = sim.households[household_id]
		h.employer_business_id = butcher.id
		seated += h.worker_capacity()
	var cattle := Commodity.Type.CATTLE
	butcher.add_stock(cattle, 5.0)
	sim.advance_ticks(1)
	var consumed: float = float((butcher.todays_flows.get(HEBusiness.FLOW_CONSUMED, {}) as Dictionary).get(cattle, 0.0))
	var row: Dictionary = butcher.ledger_history(1)[0]
	var price := HESimulation.livestock_quote(HEBusiness.Species.CATTLE, HESimulation.LivestockQuote.BUTCHER_PURCHASE)
	print("  Butcher used %.1f head at %.1f each: ledger input cost %.1f, output stock %.1f, input stock %.1f" % [consumed, price, row["input_consumed_value"], row["output_stock_value"], row["input_stock_value"]])
	_assert(consumed > 0.0, "Test setup: the staffed Butcher should process some of its head")
	_assert(absf(row["input_consumed_value"] - consumed * price) < EPSILON, "Consumed animals should be costed at the Butcher's purchase price, got %.2f for %.1f head at %.1f" % [row["input_consumed_value"], consumed, price])

## A throwaway workshop with a crew and a synthetic ledger, so the staffing
## decision can be judged on stated books instead of on a scenario's luck.
func _synthetic_workshop(sim: HESimulation, crew: int, row: Dictionary, held_output: float = 0.0) -> HEBusiness:
	var b: HEBusiness = HEScenarioSeeds.make_charcoal_burner(900, HEScenarioSeeds.SETTLEMENT_ID)
	var seated := 0
	for household_id in sim.get_household_ids():
		if seated >= crew:
			break
		var h: HEHousehold = sim.households[household_id]
		h.employer_business_id = 900
		seated += h.worker_capacity()
	var defaults := {
		"employed": float(seated), "reference_wage": 1.0, "sales_household": 0.0, "sales_business": 0.0, "sales_export": 0.0,
		"sales_other": 0.0, "trade_margin": 0.0, "input_consumed_value": 0.0, "taxes": 0.0, "units_sold": 0.0,
		"units_produced": 0.0, "unmet_demand": 0.0, "unfunded_demand": 0.0, "cash_profit": 0.0, "balance": 0.0}
	for i in 21:
		b._ledger_history.append(defaults.merged(row, true))
	if held_output > 0.0:
		b.add_stock(Commodity.Type.CHARCOAL, held_output)
	return b

## The staffing decision, explained from the books: a workshop whose sales
## cover its inputs and wages keeps (or adds to) its crew; one whose inputs cost
## more than it sells shrinks; output with no buyer is cut toward what sells;
## shortage and unfunded need call for hands; sales that are only old stock
## leaving do not.
func _check_staffing_decisions() -> void:
	print("\n=== Staffing: decisions follow operating return and saleable volume ===")
	var sim := _new_sim("build_economy_with_charcoal_burner")
	var wage := 1.0
	# 6 charcoal a day, sold at 3.8 each; inputs 2.5 timber per unit at timber price t.
	var sold_all := {"units_produced": 6.0, "units_sold": 6.0, "sales_household": 22.8, "taxes": 0.5}

	var viable := _synthetic_workshop(sim, 4, sold_all.merged({"input_consumed_value": 15.0}, true))
	var viable_d := sim._staffing_decision(viable, wage)
	print("  viable (inputs 15/day):        return/worker %.2f vs wage %.2f -> delta %d %s" % [viable_d["return_per_worker"], wage, viable_d["delta"], viable_d["reason"]])
	_assert(viable_d["return_per_worker"] > wage, "Viable workshop should clear the wage")
	_assert(viable_d["delta"] >= 0, "A workshop whose sales cover inputs and wages should not shrink")

	var unviable := _synthetic_workshop(sim, 4, sold_all.merged({"input_consumed_value": 30.0}, true))
	var unviable_d := sim._staffing_decision(unviable, wage)
	print("  unviable (inputs 30/day):      return/worker %.2f vs wage %.2f -> delta %d %s" % [unviable_d["return_per_worker"], wage, unviable_d["delta"], unviable_d["reason"]])
	_assert(unviable_d["return_per_worker"] < 0.0 and unviable_d["delta"] < 0 and unviable_d["reason"] == "low_return", "Inputs dearer than sales should shrink the crew for low return")

	var oversupplied := _synthetic_workshop(sim, 4, {"units_produced": 6.0, "units_sold": 3.0, "sales_household": 11.4, "input_consumed_value": 3.0, "taxes": 0.25})
	var oversupplied_d := sim._staffing_decision(oversupplied, wage)
	print("  oversupplied (sells half):     target crew %.1f of %d -> delta %d %s" % [oversupplied_d["target_workers"], sim._business_employed_worker_count(900), oversupplied_d["delta"], oversupplied_d["reason"]])
	_assert(oversupplied_d["return_per_worker"] > wage, "Test setup: the units that do sell should look profitable")
	_assert(oversupplied_d["delta"] < 0 and oversupplied_d["reason"] == "unsold_output", "Output with no buyer should be cut even while the units that sell are profitable")

	var short := _synthetic_workshop(sim, 4, sold_all.merged({"input_consumed_value": 3.0, "unmet_demand": 3.0}, true))
	var short_d := sim._staffing_decision(short, wage)
	print("  supply-limited (3/day unmet):  target crew %.1f -> delta %d %s" % [short_d["target_workers"], short_d["delta"], short_d["reason"]])
	_assert(short_d["delta"] > 0, "Funded demand the crew could not fill, at a clearing return, should add workers")

	var drawn := _synthetic_workshop(sim, 4, sold_all.merged({"input_consumed_value": 3.0}, true), 500.0)
	var drawn_d := sim._staffing_decision(drawn, wage)
	print("  sales from a pile of stock:    delta %d" % drawn_d["delta"])
	_assert(drawn_d["delta"] == 0, "Sales that are only old stock leaving are not demand for more workers")

	var broke := _synthetic_workshop(sim, 4, {"units_produced": 6.0, "units_sold": 3.0, "sales_household": 11.4, "input_consumed_value": 3.0, "taxes": 0.25, "unfunded_demand": 3.0})
	var broke_d := sim._staffing_decision(broke, wage)
	print("  unsold but households broke:   delta %d %s" % [broke_d["delta"], broke_d["reason"]])
	_assert(broke_d["delta"] >= 0 and broke_d["reason"] != "unsold_output", "Output unsold because households lack money is a wage gap, not a reason to cut jobs")

## Three businesses, each with an explicit expected outcome and the books that
## explain it. Operating return and staffing are asserted BEFORE survival, so a
## failure says which constraint broke rather than just "business missing".
func _check_staffing_outcomes() -> void:
	print("\n=== Staffing outcomes: oversupplied Woodlot sheds, viable workshop keeps its crew, unviable one closes ===")
	var wood := HEScenarioSeeds.WOODLOT_BUSINESS_ID
	var burner_id := HEScenarioSeeds.CHARCOAL_BURNER_BUSINESS_ID

	# 1. An oversupplied Woodlot sheds workers before debt destroys it.
	var town := _new_sim("build_three_business_economy_with_bloomery")
	var woodlot: HEBusiness = town.businesses[wood]
	var start_crew: int = woodlot.capacity
	var smallest_crew := start_crew
	var lowest_balance := woodlot.balance
	var shed_events := 0
	var unexplained_sheds := 0
	for day in 450:
		town.advance_ticks(1)
		if not town.businesses.has(wood):
			break
		smallest_crew = mini(smallest_crew, woodlot.capacity)
		lowest_balance = minf(lowest_balance, woodlot.balance)
		var change: Dictionary = town.get_daily_history(1)[0]["capacity_changes"].get(wood, {})
		if not change.is_empty() and change["new_capacity"] < change["old_capacity"]:
			shed_events += 1
			var why: Dictionary = change.get("staffing", {})
			var explained: bool = change["reason"] == "cash_runway" \
				or (change["reason"] == "low_return" and why.get("return_per_worker", 0.0) < why.get("wage", 0.0)) \
				or (change["reason"] == "unsold_output" and why.get("target_workers", 0.0) < why.get("employed", 0.0))
			if not explained:
				unexplained_sheds += 1
	print("  Woodlot crew %d -> %d at its smallest, %d shed decisions (%d unexplained by the books), lowest balance %.0f" % [start_crew, smallest_crew, shed_events, unexplained_sheds, lowest_balance])
	_assert(shed_events > 0 and smallest_crew <= start_crew - 3, "An oversupplied Woodlot should shed workers (start %d, smallest %d)" % [start_crew, smallest_crew])
	_assert(unexplained_sheds == 0, "Every Woodlot shed should be explained by its ledger (%d were not)" % unexplained_sheds)
	_assert(town.businesses.has(wood) and lowest_balance > 0.0, "The Woodlot should shed before debt: survived=%s lowest balance %.0f" % [town.businesses.has(wood), lowest_balance])

	# 2. A workshop with affordable inputs and buyers retains a crew. Prices held
	# at their intended base values are those conditions.
	var intended := _new_sim("build_economy_with_charcoal_burner", false)
	intended.advance_ticks(300)
	for id in [burner_id, HEScenarioSeeds.BLOOMERY_BUSINESS_ID]:
		var workshop: HEBusiness = intended.businesses.get(id)
		_assert(workshop != null, "Workshop %d should survive 300 days at intended prices" % id)
		if workshop == null:
			continue
		var profit: float = workshop.ledger_average("cash_profit", 100)
		var workers := intended._business_employed_worker_count(id)
		var wage := intended.wages.reference_wage_per_worker(workshop.settlement_id)
		var books := intended._staffing_decision(workshop, wage)
		print("  %s at intended prices: crew %d, cash profit %.2f/day over 100 days, return/worker %.2f vs wage %.2f" % [workshop.name, workers, profit, books["return_per_worker"], wage])
		_assert(profit > 0.0, "%s at intended prices should make a cash profit, got %.2f/day" % [workshop.name, profit])
		_assert(workers >= 1 and workshop.capacity >= 1, "%s should keep a crew when its sales cover its costs" % workshop.name)

	# 3. A workshop whose inputs cost more than it can sell for shrinks, then closes.
	var starved := _new_sim("build_economy_with_charcoal_burner", false)
	(starved.markets[starved.get_settlement_ids()[0]] as HEMarket).price[Commodity.Type.TIMBER] = 6.0
	var closed_day := -1
	var crew_floor_day := -1
	for day in 200:
		starved.advance_ticks(1)
		var failing: HEBusiness = starved.businesses.get(burner_id)
		if failing == null:
			closed_day = day
			break
		if crew_floor_day < 0 and failing.capacity <= 1:
			crew_floor_day = day
			_assert(failing.ledger_average("cash_profit", 14) < 0.0, "A crew cut to the floor should be losing money on the books")
	print("  burner with timber at 6.0: crew at the floor by day %d, closed on day %d" % [crew_floor_day, closed_day])
	_assert(crew_floor_day >= 0, "A workshop losing money on every unit should shrink its crew")
	_assert(closed_day >= 0, "A workshop that cannot cover its inputs should close once its credit is gone")

## A Trader earns a spread on the units it moves, and what it can move is set by
## the goods on offer, not by its crew. Its crew therefore follows throughput
## (one worker moves TRADER_CAPACITY_PER_WORKER units a day): through years in
## which grain and timber swing between floor and ceiling and exports dry up for
## months, it must stay solvent instead of carrying a crew its volume cannot pay.
func _check_trader_stays_solvent() -> void:
	print("\n=== Trader: crew follows throughput, stays solvent through price swings ===")
	var sim := _new_sim("build_economy_with_charcoal_burner")
	var trader_id := HEScenarioSeeds.TRADER_BUSINESS_ID
	var lowest_balance := INF
	var most_workers_idle := 0.0
	for day in 1200:
		sim.advance_ticks(1)
		var trader: HEBusiness = sim.businesses.get(trader_id)
		if trader == null:
			break
		lowest_balance = minf(lowest_balance, trader.balance)
		if day >= 60 and day % 30 == 0:
			var moved := trader.ledger_average("units_sold", 30)
			var workers := float(sim._business_employed_worker_count(trader_id))
			most_workers_idle = maxf(most_workers_idle, workers - moved / HESimulation.TRADER_CAPACITY_PER_WORKER)
	var alive := sim.businesses.has(trader_id)
	print("  Trader alive after 1200 days: %s, lowest balance %.0f, most workers beyond what its volume needed: %.1f" % [alive, lowest_balance, most_workers_idle])
	_assert(alive, "The Trader should stay in business for 1200 days")
	_assert(lowest_balance > 0.0, "The Trader should never run into debt, lowest balance %.0f" % lowest_balance)
	_assert(most_workers_idle <= 8.0, "The Trader's crew should follow its throughput, but carried %.1f workers beyond it" % most_workers_idle)

## A throwaway business with `rows` days of synthetic ledger, each carrying the
## given row plus per-good units, so a seller's cost and forecast can be judged
## on stated books.
func _workshop_with_rows(sim: HESimulation, business: HEBusiness, rows: int, row: Dictionary, goods: Dictionary) -> HEBusiness:
	var defaults := {
		"employed": 2.0, "reference_wage": 1.0, "sales_household": 0.0, "sales_business": 0.0, "sales_export": 0.0,
		"sales_other": 0.0, "trade_margin": 0.0, "input_consumed_value": 0.0, "taxes": 0.0, "units_sold": 0.0,
		"units_produced": 0.0, "unmet_demand": 0.0, "unfunded_demand": 0.0, "cash_profit": 0.0, "balance": 0.0,
		"wages": 0.0, "goods": goods}
	for i in rows:
		business._ledger_history.append(defaults.merged(row, true))
	return business

## A seller's export decision, before any Trader is involved: what it can spare
## (its own forecast of local use until its next supply, plus a backlog counted
## once, plus workshops' known input needs tomorrow) and the least it will take
## (cost per unit of output value over its production cycle, shared costs split by
## value, a documented starting quote until a cycle has been seen).
func _check_seller_trade_offers() -> void:
	print("\n=== Seller offers: forecast of local use, backlog counted once, cost-based floor ===")
	var sim := _new_sim("build_economy_with_charcoal_burner")
	var settlement_id: int = sim.get_settlement_ids()[0]
	var timber := Commodity.Type.TIMBER
	var woodlot: HEBusiness = sim.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID]
	woodlot.inventory.clear()
	woodlot.add_stock(timber, 2000.0)

	var offer := sim._seller_trade_offer(woodlot, timber)
	var known := sim._known_daily_local_use(woodlot, timber)
	print("  Woodlot, 2000 timber: routine use %.1f/day x %.0f days + next-day input %.1f -> reserve %.1f, offers %.1f (salvage %.1f), floor %.2f" % [
		offer["routine_use"], offer["horizon"], offer["next_day_need"], offer["reserve"], offer["quantity"], offer["salvage_quantity"], offer["min_price"]])
	_assert(known > 0.0 and offer["next_day_need"] > 0.0, "Households and staffed workshops should give the Woodlot local use to protect")
	_assert(absf(offer["reserve"] - (known * offer["horizon"] + offer["outstanding"] + offer["next_day_need"])) < EPSILON, "Reserve should be routine use x horizon + backlog + next-day input")
	_assert(absf(offer["quantity"] - (2000.0 - offer["reserve"])) < EPSILON, "The seller offers what is left above its reserve")
	_assert(offer["salvage_quantity"] <= offer["quantity"] + EPSILON, "Salvage units are part of what the seller can spare, never more")
	_assert(absf(offer["min_price"] - HESimulation.SELLER_STARTING_COST_RATIO * HESimulation.BASE_PRICE[timber]) < EPSILON, "Before a cycle is observed the floor is the documented starting quote")

	# Today's unfilled funded requests are a backlog, counted once: the reserve
	# rises by the backlog and not by backlog x days to the next harvest.
	sim._price_signal_today = {settlement_id: {timber: {"funded_household": 50.0, "funded_business": 0.0, "offer": 10.0}}}
	var with_backlog := sim._seller_trade_offer(woodlot, timber)
	sim._price_signal_today = {}
	_assert(absf(with_backlog["outstanding"] - 40.0) < EPSILON and absf((with_backlog["reserve"] - offer["reserve"]) - 40.0) < EPSILON,
		"A 40-unit backlog should add exactly 40 to the reserve, not 40 x %.0f days" % offer["horizon"])

	# Floor from the books: (wages + inputs) / (units produced x value), over a cycle.
	var burner := HEScenarioSeeds.make_charcoal_burner(900, HEScenarioSeeds.SETTLEMENT_ID)
	var charcoal := Commodity.Type.CHARCOAL
	_workshop_with_rows(sim, burner, 40, {"wages": 2.0, "input_consumed_value": 6.0}, {"produced": {charcoal: 3.0}})
	var expected_ratio := 8.0 / (3.0 * HESimulation.BASE_PRICE[charcoal])
	var ratio := sim._seller_cost_ratio(burner)
	print("  Burner books: cost 8.0/day for 3 charcoal -> cost ratio %.3f, floor %.2f per charcoal" % [ratio, sim._seller_min_price(burner, charcoal)])
	_assert(absf(ratio - expected_ratio) < 0.001, "Cost ratio should be cost / (units produced x value), got %.3f vs %.3f" % [ratio, expected_ratio])
	var young := HEScenarioSeeds.make_charcoal_burner(901, HEScenarioSeeds.SETTLEMENT_ID)
	_workshop_with_rows(sim, young, 10, {"wages": 2.0, "input_consumed_value": 6.0}, {"produced": {charcoal: 3.0}})
	_assert(sim._seller_cost_ratio(young) == HESimulation.SELLER_STARTING_COST_RATIO, "Fewer rows than a cycle should use the starting quote, not zero or infinity")

	# Shared costs: a Butcher's meat and leather carry the same cost-to-value ratio.
	var butcher := HEScenarioSeeds.make_butcher(902, HEScenarioSeeds.SETTLEMENT_ID)
	_workshop_with_rows(sim, butcher, maxi(40, butcher.rolling_window_days()), {"wages": 3.0, "input_consumed_value": 3.0}, {"produced": {Commodity.Type.MEAT: 2.0, Commodity.Type.LEATHER: 1.0}})
	var meat_ratio: float = sim._seller_min_price(butcher, Commodity.Type.MEAT) / HESimulation.BASE_PRICE[Commodity.Type.MEAT]
	var leather_ratio: float = sim._seller_min_price(butcher, Commodity.Type.LEATHER) / HESimulation.BASE_PRICE[Commodity.Type.LEATHER]
	_assert(absf(meat_ratio - leather_ratio) < 0.0001 and absf(meat_ratio - 6.0 / (2.0 * 1.6 + 1.0 * 1.6)) < 0.001, "Meat and leather should share one cost ratio (%.3f vs %.3f)" % [meat_ratio, leather_ratio])

	# What a seller will sell at a given bid: all it can spare if the bid reaches
	# its floor; otherwise only the units beyond its cover period.
	var trader: HEBusiness = sim.businesses[HEScenarioSeeds.TRADER_BUSINESS_ID]
	var market: HEMarket = sim.markets[settlement_id]
	woodlot.inventory.clear()
	woodlot.add_stock(timber, 4000.0)
	var good_view := sim._trader_offer_view(trader, woodlot, timber)
	market.price[timber] = 0.25
	var glut_view := sim._trader_offer_view(trader, woodlot, timber)
	market.price[timber] = 1.0
	print("  bid reaches the floor: sells %.1f | bid %.3f under the %.2f floor: sells only the %.1f beyond cover" % [good_view["eligible"], glut_view["bid"], glut_view["offer"]["min_price"], glut_view["eligible"]])
	_assert(absf(good_view["eligible"] - good_view["offer"]["quantity"]) < EPSILON, "A bid at or above the floor should take everything the seller can spare")
	_assert(absf(glut_view["eligible"] - glut_view["offer"]["salvage_quantity"]) < EPSILON and glut_view["eligible"] < glut_view["offer"]["quantity"], "A bid under the floor should take only the excess beyond cover")

## The Trader's bid moves by a small step toward whatever fills its capacity
## with offers it can take, and only then: capacity binding lowers the bids of
## goods it turned away, refusals with spare capacity raise them (up to a ceiling
## that still pays a wage), and nothing on offer leaves them alone.
func _check_trader_bids() -> void:
	print("\n=== Trader bids: controller behaviour at both capacity extremes ===")
	var sim := _new_sim("build_economy_with_charcoal_burner")
	var settlement_id: int = sim.get_settlement_ids()[0]
	var trader: HEBusiness = sim.businesses[HEScenarioSeeds.TRADER_BUSINESS_ID]
	var grain := Commodity.Type.GRAIN
	var reference := 1.0
	var ceiling := sim._trader_max_bid_fraction(settlement_id, reference)
	_assert(ceiling < 1.0 and ceiling > HESimulation.TRADER_BID_FRACTION_MIN, "The ceiling should leave the Trader a wage's spread, got %.3f" % ceiling)

	var run := func(eligible: float, accepted: float, offered: float, capacity: float, remaining: float, days: int) -> float:
		trader.bid_fraction.clear()
		var fraction := HESimulation.TRADER_STARTING_BID_FRACTION
		for i in days:
			var offers: Array[Dictionary] = [{"commodity": grain, "fraction": fraction, "reference": reference,
				"eligible": eligible, "accepted": accepted, "offer": {"quantity": offered}}]
			sim._adjust_trader_bids(trader, offers, capacity, remaining)
			fraction = trader.bid_fraction[grain]
		return fraction

	# Capacity binding: more offers sellers would take than the Trader can carry.
	var squeezed: float = run.call(100.0, 10.0, 100.0, 10.0, 0.0, 200)
	# Spare capacity with offers refused for being under the floor.
	var refused: float = run.call(0.0, 0.0, 50.0, 100.0, 100.0, 200)
	# Nothing on offer at all.
	var idle: float = run.call(0.0, 0.0, 0.0, 100.0, 100.0, 200)
	# Everything offered is taken with room to spare.
	var satisfied: float = run.call(40.0, 40.0, 40.0, 100.0, 60.0, 200)
	print("  capacity binding -> %.2f | refused with spare capacity -> %.2f (ceiling %.2f) | no offers -> %.2f | all taken -> %.2f" % [squeezed, refused, ceiling, idle, satisfied])
	_assert(absf(squeezed - HESimulation.TRADER_BID_FRACTION_MIN) < 0.0001, "A Trader at capacity should widen its spread down to the minimum bid")
	_assert(absf(refused - ceiling) < 0.0001, "Refused offers with spare capacity should raise the bid to, and no further than, the ceiling")
	_assert(absf(idle - HESimulation.TRADER_STARTING_BID_FRACTION) < 0.0001, "With nothing on offer the bid should not move (an idle Trader must not talk itself into a loop)")
	_assert(absf(satisfied - HESimulation.TRADER_STARTING_BID_FRACTION) < 0.0001, "When every offer is taken with room to spare the bid should stay put")

## Allocation and cash: capacity goes to the widest Trader margin per unit, and
## the cash entering the economy is the reference value whatever the bid, so the
## bid only splits it between the seller and the Trader.
func _check_trade_allocation_and_cash() -> void:
	print("\n=== Trade: widest margin first; export cash independent of the bid ===")
	var sim := _new_sim("build_economy_with_charcoal_burner")
	var settlement_id: int = sim.get_settlement_ids()[0]
	var trader_id := HEScenarioSeeds.TRADER_BUSINESS_ID
	var trader: HEBusiness = sim.businesses[trader_id]
	# One worker's worth of capacity.
	var kept := false
	for household_id in sim.get_household_ids():
		var h: HEHousehold = sim.households[household_id]
		if h.employer_business_id == trader_id:
			if kept:
				h.employer_business_id = -1
			kept = true
	var capacity: float = float(sim._business_employed_worker_count(trader_id)) * HESimulation.TRADER_CAPACITY_PER_WORKER
	var bloomery: HEBusiness = sim.businesses[HEScenarioSeeds.BLOOMERY_BUSINESS_ID]
	var woodlot: HEBusiness = sim.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID]
	bloomery.inventory.clear()
	bloomery.add_stock(Commodity.Type.IRON, 500.0)
	woodlot.inventory.clear()
	woodlot.add_stock(Commodity.Type.TIMBER, 5000.0)
	var record := sim._new_daily_record()
	sim._run_trade(record)
	var iron_shipped: float = record["exported"].get("Iron", 0.0)
	var timber_shipped: float = record["exported"].get("Timber", 0.0)
	print("  capacity %.0f units: iron (margin %.2f/unit) shipped %.1f, timber (margin %.2f/unit) shipped %.1f" % [
		capacity, 15.0 * 0.5, iron_shipped, 1.0 * 0.5, timber_shipped])
	_assert(capacity > 0.0 and absf(iron_shipped - capacity) < EPSILON and timber_shipped < EPSILON, "Capacity should go to the widest margin per unit (iron) before cheaper goods")

	# Same shipment at two different bids: identical cash entering, different split.
	var results: Array = []
	for bid in [0.4, 0.7]:
		var fresh := _new_sim("build_economy_with_charcoal_burner")
		var seller: HEBusiness = fresh.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID]
		var fresh_trader: HEBusiness = fresh.businesses[trader_id]
		var seller_before := seller.balance
		var trader_before := fresh_trader.balance
		var entered_before: float = fresh._export_revenue_total
		fresh._execute_export(fresh_trader, seller, Commodity.Type.TIMBER, 10.0, 1.0, bid, fresh._new_daily_record())
		results.append({"entered": fresh._export_revenue_total - entered_before, "seller": seller.balance - seller_before, "trader": fresh_trader.balance - trader_before})
	print("  10 timber at bid 0.4 vs 0.7: cash entering %.1f / %.1f, seller %.1f / %.1f, Trader spread %.1f / %.1f" % [
		results[0]["entered"], results[1]["entered"], results[0]["seller"], results[1]["seller"], results[0]["trader"], results[1]["trader"]])
	_assert(absf(results[0]["entered"] - 10.0) < EPSILON and absf(results[1]["entered"] - 10.0) < EPSILON, "Cash entering should be units x reference price regardless of the bid")
	for r in results:
		_assert(absf(r["seller"] + r["trader"] - r["entered"]) < EPSILON, "The seller's receipt plus the Trader's spread should equal the cash that entered")
	_assert(results[1]["seller"] > results[0]["seller"] and results[1]["trader"] < results[0]["trader"], "A higher bid should shift value from the Trader to the seller")

## Cattle and sheep use the same export path as every other good: enabled by
## default, reference price from HERD_EXPORT_PRICE, and a horizon that is the
## real countdown to the next review.
func _check_herd_export_path() -> void:
	print("\n=== Herds: livestock export through the common path ===")
	var sim := _new_sim("build_economy_with_charcoal_burner")
	var settlement_id: int = sim.get_settlement_ids()[0]
	var enabled := {}
	for option in sim.get_trader_export_settings(HEScenarioSeeds.TRADER_BUSINESS_ID):
		enabled[option["commodity_id"]] = option["enabled"]
		if option["commodity_id"] == Commodity.Type.CATTLE:
			_assert(absf(option["reference_price"] - HESimulation.HERD_EXPORT_PRICE[HEBusiness.Species.CATTLE]) < EPSILON, "A live animal's reference price is HERD_EXPORT_PRICE")
	_assert(enabled.get(Commodity.Type.CATTLE, false) and enabled.get(Commodity.Type.SHEEP, false), "Cattle and sheep should be export checkbox goods, enabled by default")
	var ranch: HEBusiness = sim._trade_seller(settlement_id, Commodity.Type.CATTLE)
	_assert(ranch != null and ranch.kind == HEBusiness.Kind.HERD and ranch.species == HEBusiness.Species.CATTLE, "The cattle seller should be the Cattle Ranch")

	var horizons: Array[int] = []
	for day in 100:
		horizons.append(sim._days_until_next_supply(ranch))
		sim.advance_ticks(1)
	var counted_down := true
	var reset_seen := false
	for i in range(1, horizons.size()):
		if horizons[i] == horizons[i - 1] - 1 or horizons[i] == 1:
			continue
		if horizons[i] > horizons[i - 1]:
			reset_seen = true
			continue
		counted_down = false
	print("  herd horizon over 100 days: starts %d, a review resets it: %s, never the full %d-day growth cycle: %s" % [
		horizons[0], reset_seen, ranch.growth_days, horizons.max() < ranch.growth_days or ranch.growth_days <= HESimulation.HERD_EVAL_INTERVAL_DAYS])
	_assert(counted_down and reset_seen, "A herd's horizon should count down day by day to its next review, then reset")
	_assert(horizons.max() <= HESimulation.HERD_EVAL_INTERVAL_DAYS, "A herd's horizon never exceeds its review interval")

## The Trader holds no reserve of its own any more: nothing in the simulation
## carries the old constant or the old Trader-owned surplus functions.
func _check_no_export_reserve_left() -> void:
	print("\n=== No Trader-owned reserve left in the simulation ===")
	var source := FileAccess.get_file_as_string("res://scripts/sim/household_economy/he_simulation.gd")
	for name in ["TRADER_RESERVE_BUFFER_DAYS", "_seller_surplus_above_reserve", "_exportable_surplus"]:
		_assert(not source.contains(name), "%s should be gone: the seller decides what is spare" % name)
	print("  reserve constant and Trader-owned surplus functions are gone")

## Exercises the opt-in Bloomery scenario: wood bought from the Woodlot plus
## iron ore imported by the Trader smelt into iron, which that same Trader
## then exports since no household ever wants iron directly (see
## he_simulation.gd's _run_input_purchasing/_run_trade doc comments).
## Reuses _check_conservation's exact money-reconciliation formula (this is
## the scenario where import_cost actually moves) plus the same shape of
## check for iron's own goods conservation (opening + produced - exported,
## no consumed/written_off term since no household or emigration ever
## touches iron).
func _check_bloomery_smelting() -> void:
	print("\n=== Bloomery: smelts wood + imported ore into iron, which the Trader exports ===")
	var sim := _new_sim("build_three_business_economy_with_bloomery")
	sim.advance_ticks(200)
	var history := sim.get_daily_history(200)

	var total_iron_produced := 0.0
	var total_iron_exported := 0.0
	var total_ore_imported := 0.0
	var total_import_cost := 0.0
	var worst_iron_gap := 0.0
	var worst_money_gap := 0.0
	for record in history:
		total_iron_produced += (record["produced"] as Dictionary).get("Iron", 0.0)
		total_iron_exported += (record["exported"] as Dictionary).get("Iron", 0.0)
		total_ore_imported += (record["imported"] as Dictionary).get("Iron Ore", 0.0)
		total_import_cost += float(record["import_cost"])

		var opening: float = (record["opening_stock"] as Dictionary).get("Iron", 0.0)
		var produced: float = (record["produced"] as Dictionary).get("Iron", 0.0)
		var exported: float = (record["exported"] as Dictionary).get("Iron", 0.0)
		var closing: float = (record["closing_stock"] as Dictionary).get("Iron", 0.0)
		worst_iron_gap = max(worst_iron_gap, abs(closing - (opening + produced - exported)))

		var expected_money: float = record["opening_money"] - float(record["money_written_off"]) + float(record["export_revenue"]) - float(record["import_cost"])
		worst_money_gap = max(worst_money_gap, abs(record["closing_money"] - expected_money))

	print("  over 200 days: iron produced=%.1f, iron exported=%.1f, ore imported=%.1f, import cost=%.1f" % [total_iron_produced, total_iron_exported, total_ore_imported, total_import_cost])
	print("  worst iron stock reconciliation gap: %.4f" % worst_iron_gap)
	print("  worst same-day money reconciliation gap: %.4f" % worst_money_gap)

	_assert(total_iron_produced > 0.0, "Bloomery should have smelted at least some iron over 200 days")
	_assert(total_ore_imported > 0.0, "Trader should have imported iron ore for the Bloomery over 200 days")
	_assert(total_import_cost > 0.0, "Importing ore should cost the Trader money -- see _import_cost_total")
	# No household ever wants iron, so it should all leave via export rather
	# than piling up unsold in the Bloomery's own inventory.
	_assert(absf(total_iron_produced - total_iron_exported) < total_iron_produced * 0.05 + EPSILON,
		"Nearly all smelted iron should get exported, not stockpiled -- produced %.1f, exported %.1f" % [total_iron_produced, total_iron_exported])
	_assert(worst_iron_gap < EPSILON, "Iron stock did not reconcile as opening + produced - exported, worst gap %.4f" % worst_iron_gap)
	_assert(worst_money_gap < EPSILON, "Money did not reconcile with import_cost included, worst gap %.4f" % worst_money_gap)

	var bloomery_report: Dictionary = {}
	for report in sim.get_business_reports():
		if report["business_id"] == HEScenarioSeeds.BLOOMERY_BUSINESS_ID:
			bloomery_report = report
	_assert(not bloomery_report.is_empty(), "Bloomery should appear in business reports when the scenario includes it")
	_assert(bloomery_report.get("capacity", 0) > 0, "Bloomery should still have staff after 200 days -- its recipe should clear the reference wage (see he_scenario_seeds.gd's _bloomery_recipe doc comment), not starve to zero")
	var recent_transactions := sim.get_trader_transactions(HEScenarioSeeds.TRADER_BUSINESS_ID, 30)
	var saw_ore_import := false
	var saw_iron_export := false
	for transaction in recent_transactions:
		saw_ore_import = saw_ore_import or (transaction["direction"] == "import" and transaction["commodity"] == "Iron Ore")
		saw_iron_export = saw_iron_export or (transaction["direction"] == "export" and transaction["commodity"] == "Iron")
	_assert(saw_ore_import, "Trader's last-30-day transaction history should include an Iron Ore import")
	_assert(saw_iron_export, "Trader's last-30-day transaction history should include an Iron export")

## The local mine must replace the Trader's ore-import fallback. Input
## purchasing runs before surplus export each day, so the Bloomery gets its
## claim on the mine's previous closing stock before the Trader can move it.
func _check_local_iron_mine_supplies_bloomery_first() -> void:
	print("\n=== Iron Mine: supplies the Bloomery before Trader export ===")
	var sim := _new_sim("build_economy_with_bloomery_and_iron_mine")
	var maximum_buffered_timber := 0.0
	var maximum_buffered_ore := 0.0
	for _day in 60:
		sim.advance_ticks(1)
		for report in sim.get_business_reports():
			if report["business_id"] != HEScenarioSeeds.BLOOMERY_BUSINESS_ID:
				continue
			var inputs: Dictionary = report["input_inventory"]
			maximum_buffered_timber = maxf(maximum_buffered_timber, inputs.get("Timber", 0.0))
			maximum_buffered_ore = maxf(maximum_buffered_ore, inputs.get("Iron Ore", 0.0))
	var history := sim.get_daily_history(60)
	var ore_produced := 0.0
	var ore_imported := 0.0
	var iron_produced := 0.0
	var worst_input_stock_gap := 0.0
	for record in history:
		ore_produced += (record["produced"] as Dictionary).get("Iron Ore", 0.0)
		ore_imported += (record["imported"] as Dictionary).get("Iron Ore", 0.0)
		iron_produced += (record["produced"] as Dictionary).get("Iron", 0.0)
		for commodity_name in ["Timber", "Iron Ore"]:
			var expected: float = (record["opening_stock"] as Dictionary).get(commodity_name, 0.0) \
				+ (record["produced"] as Dictionary).get(commodity_name, 0.0) \
				+ (record["imported"] as Dictionary).get(commodity_name, 0.0) \
				- (record["consumed"] as Dictionary).get(commodity_name, 0.0) \
				- (record["exported"] as Dictionary).get(commodity_name, 0.0)
			var closing: float = (record["closing_stock"] as Dictionary).get(commodity_name, 0.0)
			worst_input_stock_gap = maxf(worst_input_stock_gap, absf(closing - expected))

	var mine_present := false
	for report in sim.get_business_reports():
		if report["business_id"] == HEScenarioSeeds.IRON_MINE_BUSINESS_ID:
			mine_present = true
			break
	print("  over 60 days: ore mined=%.1f, ore imported=%.1f, iron smelted=%.1f, max Bloomery buffers=%.1f timber/%.1f ore" % [ore_produced, ore_imported, iron_produced, maximum_buffered_timber, maximum_buffered_ore])
	_assert(mine_present, "Iron Mine should appear in the local-ore scenario")
	_assert(ore_produced > 0.0, "Iron Mine should produce ore")
	_assert(iron_produced > 0.0, "Bloomery should smelt iron from locally mined ore")
	_assert(ore_imported < EPSILON, "Trader should not import ore while a local Iron Mine supplies it, imported %.3f" % ore_imported)
	for transaction in sim.get_trader_transactions(HEScenarioSeeds.TRADER_BUSINESS_ID, 30):
		_assert(not (transaction["direction"] == "import" and transaction["commodity"] == "Iron Ore"), "Local-mine Trader history should not contain an Iron Ore import")
	_assert(maximum_buffered_timber > 0.0 and maximum_buffered_ore > 0.0, "Bloomery should retain both recipe inputs between production days")
	_assert(worst_input_stock_gap < EPSILON, "Buffered Timber/Iron Ore stock did not reconcile, worst gap %.4f" % worst_input_stock_gap)

## The export list is derived from the commodity catalogue, not hand-listed, so
## a new good can't be silently left off the settings page: it must appear in the
## fixed order, start disabled, and only be shown while something sells it.
func _check_export_settings_derived_from_commodities() -> void:
	print("
=== Trader export settings: derived list, fixed order, rows hidden without a seller ===")
	var priority := HESimulation.EXPORT_PRIORITY
	_assert(priority.has(Commodity.Type.WOOL), "Wool should be an exportable good")
	_assert(priority.has(Commodity.Type.TOOLS), "Tools have a market price (the Toolsmith's) and should be exportable")
	_assert(not HESimulation.EXPORT_COMMODITIES.has(Commodity.Type.TOOLS), "Tools should start disabled: the Toolsmith serves local households")
	var seen := {}
	for commodity in priority:
		_assert(not seen.has(commodity), "%s listed twice in EXPORT_PRIORITY" % Commodity.name_of(commodity))
		seen[commodity] = true
	for commodity in HESimulation.EXPORT_PINNED_FIRST + HESimulation.EXPORT_PINNED_LAST:
		_assert(priority.has(commodity), "Pinned good %s is not exportable" % Commodity.name_of(commodity))
	_assert(priority[0] == Commodity.Type.IRON, "Iron must keep first call on Trader capacity")
	_assert(priority[priority.size() - 1] == Commodity.Type.SHEEP and priority[priority.size() - 2] == Commodity.Type.CATTLE, "Livestock must stay last")
	for commodity in HESimulation.EXPORT_COMMODITIES:
		_assert(priority.has(commodity), "Default-enabled %s is not exportable" % Commodity.name_of(commodity))

	var trader_id := HEScenarioSeeds.TRADER_BUSINESS_ID
	# Farm + Woodlot + Trader only: no Sheep Farm, ranch, Butcher or mine.
	var bare := HESimulation.new(SEED, func(rng: RandomNumberGenerator) -> Dictionary:
		return HEFixtures.build_custom(rng, [HEScenarioSeeds.FARM_BUSINESS_ID, HEScenarioSeeds.WOODLOT_BUSINESS_ID, trader_id]))
	var bare_rows := bare.get_trader_export_settings(trader_id)
	var bare_goods: Array = []
	for option in bare_rows:
		bare_goods.append(option["commodity_id"])
	for hidden in [Commodity.Type.WOOL, Commodity.Type.IRON_ORE, Commodity.Type.IRON, Commodity.Type.CATTLE, Commodity.Type.SHEEP, Commodity.Type.MEAT]:
		_assert(not bare_goods.has(hidden), "%s has no local seller in this settlement, so its row should be hidden" % Commodity.name_of(hidden))
	_assert(bare_goods.has(Commodity.Type.GRAIN) and bare_goods.has(Commodity.Type.TIMBER), "Grain and Timber have sellers and should be shown")
	# Toggling a hidden good is remembered but never makes its row appear.
	bare.set_trader_export_enabled(trader_id, Commodity.Type.WOOL, true)
	_assert(bare.get_trader_export_settings(trader_id).size() == bare_rows.size(), "Toggling a hidden good must not make its row appear")

	# Full economy: a Sheep Farm exists, so Wool appears -- off by default.
	var full := _new_sim("build_three_business_economy")
	var shown := {}
	var shown_order: Array = []
	for option in full.get_trader_export_settings(trader_id):
		shown[option["commodity_id"]] = option["enabled"]
		shown_order.append(option["commodity_id"])
	_assert(shown.has(Commodity.Type.WOOL), "Wool should be a Trader export setting once a Sheep Farm exists")
	_assert(shown.get(Commodity.Type.WOOL, true) == false, "Wool should start disabled")
	# Hiding must never reorder what remains.
	var last_index := -1
	for commodity in shown_order:
		var index := priority.find(commodity)
		_assert(index > last_index, "%s shown out of EXPORT_PRIORITY order" % Commodity.name_of(commodity))
		last_index = index

func _check_trader_export_settings() -> void:
	print("\n=== Trader export settings: ore opt-in and local input reserve ===")
	var sim := _new_sim("build_economy_with_bloomery_and_iron_mine")
	var trader_id := HEScenarioSeeds.TRADER_BUSINESS_ID
	var ore_enabled := true
	for option in sim.get_trader_export_settings(trader_id):
		if option["commodity_id"] == Commodity.Type.IRON_ORE:
			ore_enabled = option["enabled"]
	_assert(not ore_enabled, "Iron Ore export should start disabled")
	sim.set_trader_export_enabled(trader_id, Commodity.Type.IRON_ORE, true)
	sim.advance_ticks(30)
	var ore_exported := 0.0
	var iron_produced := 0.0
	for record in sim.get_daily_history(30):
		ore_exported += (record["exported"] as Dictionary).get("Iron Ore", 0.0)
		iron_produced += (record["produced"] as Dictionary).get("Iron", 0.0)
	_assert(ore_exported > EPSILON, "Enabling ore export should sell surplus ore")
	_assert(iron_produced > EPSILON, "Ore export must leave enough local ore for the Bloomery")
	sim.set_trader_export_enabled(trader_id, Commodity.Type.IRON_ORE, false)
	sim.advance_ticks(10)
	for record in sim.get_daily_history(10):
		_assert((record["exported"] as Dictionary).get("Iron Ore", 0.0) < EPSILON,
			"Disabling ore export should stop new ore shipments")
	# The Bloomery still buys ore from the Iron Mine locally, so the market
	# legitimately clears; with export off, that clearing must be exactly the
	# day's local purchases, not a leftover export.
	var ore_clearing: Dictionary = sim.get_market_report(1, Commodity.Type.IRON_ORE)["last_clearing"]
	var last_day_ore_traded: float = (sim.get_daily_history(1)[0]["traded_quantity"] as Dictionary).get("Iron Ore", 0.0)
	_assert(absf(ore_clearing.get("quantity_traded", 0.0) - last_day_ore_traded) < EPSILON,
		"Disabled ore export should not keep displaying a stale clearing")
	print("  enabled ore exported %.1f while Bloomery produced %.1f iron; disabling ore stopped exports" % [ore_exported, iron_produced])

## Building a scenario WITHOUT the Bloomery must never spawn one later --
## the opt-in toggle is which scenario builder gets picked (see
## he_scenario_seeds.gd's _build_world doc comment), not a runtime flag
## that a self-tuning trial-hire could quietly flip on.
func _check_bloomery_stays_off_when_not_seeded() -> void:
	print("\n=== Bloomery: absent entirely from a scenario that never seeded it ===")
	var sim := _new_sim("build_three_business_economy")
	sim.advance_ticks(200)
	for report in sim.get_business_reports():
		_assert(report["business_id"] != HEScenarioSeeds.BLOOMERY_BUSINESS_ID, "A Bloomery should never appear in a scenario that never constructed one")
	print("  no Bloomery business exists after 200 days in a scenario that never seeded one")

func _check_firing_is_logged_with_reason() -> void:
	print("\n=== Employment: firing is logged with the capacity-change reason ===")
	var sim := _new_sim("build_three_business_economy")
	var farm = sim.businesses[HEScenarioSeeds.FARM_BUSINESS_ID]
	var old_capacity: int = farm.capacity
	farm.capacity = 0
	sim._reconcile_employment({"capacity_changes": {
		HEScenarioSeeds.FARM_BUSINESS_ID: {
			"reason": "low_revenue",
			"old_capacity": old_capacity,
			"new_capacity": 0,
			"average_revenue_per_worker": 0.25,
			"reference_wage_per_worker": 0.75,
			"cash_runway_days": INF,
			"required_runway_days": 0.0,
		},
	}})
	var events := sim.get_event_log()
	var firing: Dictionary = {}
	for event in events:
		if event["type"] == "fired":
			firing = event
			break
	_assert(not firing.is_empty(), "Reducing an occupied business target should log a firing")
	_assert(firing.get("business_id", -1) == HEScenarioSeeds.FARM_BUSINESS_ID, "Firing should identify the former employer")
	_assert(firing.get("reason", "") == "low_revenue", "Firing should retain its capacity-change reason")
	_assert(firing.get("old_capacity", -1) == old_capacity and firing.get("new_capacity", -1) == 0, "Firing should show the old and new target")
	var farm_events := sim.get_business_employment_events(HEScenarioSeeds.FARM_BUSINESS_ID)
	_assert(farm_events.size() > 0 and farm_events[0]["type"] == "fired", "Farm employment history should include its recent firing first")
	_assert(sim.get_business_employment_events(HEScenarioSeeds.TRADER_BUSINESS_ID).is_empty(), "Farm firings should not appear in Trader employment history")
	if not farm_events.is_empty():
		farm_events[0]["reason"] = "changed by caller"
		_assert(sim.get_business_employment_events(HEScenarioSeeds.FARM_BUSINESS_ID)[0]["reason"] == "low_revenue", "Employment history should return copies")
	farm.capacity = old_capacity
	sim._reconcile_employment()
	var updated_events := sim.get_business_employment_events(HEScenarioSeeds.FARM_BUSINESS_ID)
	_assert(not updated_events.is_empty() and updated_events[0]["type"] == "job" and updated_events[0].get("workers", 0) > 0, "Farm employment history should put hires first and record hired workers")
	sim.day = HESimulation.EVENT_LOG_RETENTION_DAYS + 1
	sim._log_event("birth", {"household_id": 1})
	_assert(sim.get_business_employment_events(HEScenarioSeeds.FARM_BUSINESS_ID, "fired").size() > 0, "Employment history should survive beyond the shared notification window")
	print("  firing identifies household, employer, target change, and profitability evidence")

func _check_event_history_survives_busy_categories() -> void:
	print("\n=== Blotter: filters can rescan a complete day-based history ===")
	var sim := _new_sim("build_three_business_economy")
	sim._log_event("old_age", {"household_id": 1, "workers": 1})
	sim._log_event("fired", {"household_id": 1, "business_id": HEScenarioSeeds.FARM_BUSINESS_ID})
	for i in 250:
		sim._log_event("job", {"household_id": 1000 + i, "business_id": HEScenarioSeeds.FARM_BUSINESS_ID})
	var events := sim.get_event_log_days(30)
	var found_old_age := false
	for event in events:
		if event["type"] == "old_age":
			found_old_age = true
			break
	_assert(events.size() == 252, "A busy category should not evict events inside the requested day window")
	_assert(found_old_age, "Changing filters should recover a quieter event from the same day window")
	_assert(sim.get_business_employment_events(HEScenarioSeeds.FARM_BUSINESS_ID, "job", 200).size() == HESimulation.EMPLOYMENT_EVENTS_PER_TYPE, "Employment history should cap hires per business")
	_assert(sim.get_business_employment_events(HEScenarioSeeds.FARM_BUSINESS_ID, "fired").size() == 1, "A burst of hires should not evict the latest firing")
	print("  all 252 same-window events remain available; employment history retains each event type separately")

## Field/harvest model regression checks, day by day over one Farm growth
## cycle plus change: harvests are lumpy (stock only jumps on a harvest
## day, and each business's own per-business stock/sale/export accounting
## reconciles every single day, not just in aggregate -- see
## _check_conservation for the city-wide version of this), a business never
## earns revenue on a day nothing of its output actually sold locally or
## exported, wages never draw a business's balance below its own
## generous-but-real negative floor (see he_simulation.gd's WAGE_NEGATIVE_
## BALANCE_FLOOR_DAYS), and neither Farm nor Woodlot ever employs past its
## own land-derived max_capacity.
func _check_field_model_dynamics() -> void:
	print("\n=== Field model: lumpy harvests, no free revenue, wage floor, land cap ===")
	var sim := _new_sim("build_three_business_economy")
	var days := HEScenarioSeeds.FARM_GROWTH_DAYS + 30
	var harvest_days := 0
	var worst_stock_gap := 0.0
	var worst_floor_breach := 0.0
	var over_cap_by := 0
	var free_revenue_days := 0
	var invalid_harvest_projections := 0
	var previous_stock := {}
	for report in sim.get_business_reports():
		previous_stock[report["business_id"]] = report["stock"]

	for i in days:
		sim.advance_ticks(1)
		var day_record: Dictionary = sim.get_daily_history(1)[0]
		for report in sim.get_business_reports():
			var business_id: int = report["business_id"]
			if report["kind"] == "production":
				var harvested: float = report["last_actual_units"]
				if harvested > 0.0001:
					harvest_days += 1
				var traded: float = (day_record["traded_quantity"] as Dictionary).get(report["output_commodity"], 0.0)
				var exported: float = (day_record["exported"] as Dictionary).get(report["output_commodity"], 0.0)
				var expected_stock: float = float(previous_stock[business_id]) + harvested - traded - exported
				worst_stock_gap = max(worst_stock_gap, abs(report["stock"] - expected_stock))
				if traded <= 0.0001 and exported <= 0.0001 and report["last_revenue"] > 0.0001:
					free_revenue_days += 1
				if report["land_area_acres"] > 0.0:
					var projected_yield: float = report["next_harvest_yield_fraction"]
					var projected_units: float = report["next_harvest_expected_units"]
					if projected_yield < 0.0 or projected_yield > 1.0 or projected_units < 0.0:
						invalid_harvest_projections += 1
			previous_stock[business_id] = report["stock"]

			var employed: int = report["employed_workers"]
			# The land cap: only land-based businesses have one. (A ranch's
			# max_capacity is a staffing ceiling that a multi-worker household can
			# step over when it is hired whole.)
			if report["land_area_acres"] > 0.0 and not report.has("herd_size") and employed > report["max_capacity"]:
				over_cap_by = max(over_cap_by, employed - report["max_capacity"])
			var reference: float = report["reference_wage_per_worker"]
			var floor: float = -HESimulation.WAGE_NEGATIVE_BALANCE_FLOOR_DAYS * reference * employed
			if report["balance"] < floor - EPSILON:
				worst_floor_breach = max(worst_floor_breach, floor - report["balance"])

	print("  over %d days: Farm/Woodlot harvest-days=%d, worst per-business stock gap=%.4f, worst wage-floor breach=%.4f, worst over-land-cap=%d, days with revenue but no sale/export=%d" % [
		days, harvest_days, worst_stock_gap, worst_floor_breach, over_cap_by, free_revenue_days])

	_assert(harvest_days > 0, "Farm and/or Woodlot should have harvested at least once over %d days" % days)
	_assert(worst_stock_gap < EPSILON, "A business's own stock should reconcile as previous + harvested - traded - exported every day, worst gap %.4f" % worst_stock_gap)
	_assert(worst_floor_breach < EPSILON, "A business's balance dropped below its own generous wage floor by %.4f" % worst_floor_breach)
	_assert(over_cap_by == 0, "A business employed %d workers past its own land-derived max_capacity" % over_cap_by)
	_assert(free_revenue_days == 0, "A business recorded revenue on a day it sold nothing locally and exported nothing")
	_assert(invalid_harvest_projections == 0, "A next-harvest projection reported invalid expected units or yield")

## The core "let it tune itself" claim: starting from a deliberately
## mis-staffed split (Woodlot overstaffed, Farm understaffed), the business
## earning the better sales-revenue-per-worker should gain capacity/
## employment over time and the worse-earning one should lose it, with NO
## manual retuning of either recipe's output rate. rolling_average_revenue_
## per_worker, not rolling_average_wage, is the profitability signal now
## that wages are always paid at the going reference rate out of cash on
## hand (see he_business.gd's rolling_average_revenue_per_worker doc
## comment and he_simulation.gd's HEWages.pay_wages/_evaluate_business_capacity) --
## a solvent business's OWN wage is nearly always just the reference wage
## by construction, so comparing wage-to-reference the old way would show
## nothing moving even while real profitability clearly diverges.
##
## With the Trader in the mix, Woodlot's structural timber oversupply is no
## longer a permanent penalty -- trade relieves it, and Woodlot's own
## revenue-per-worker recovers past Farm's well before day 300. So this no
## longer asserts a fixed final Farm-vs-Woodlot ranking (that was really a
## proxy for "Woodlot's oversupply never gets fixed," which is exactly what
## the Trader exists to fix); it only checks that employment actually moved
## in response to the ORIGINAL mis-staffing, which is the thing this
## scenario is actually testing. It separately checks that the Trader
## itself -- the one business whose entire job is being that outlet -- is
## still alive and earning real revenue this far out, a direct regression
## check for the "permanently dies and stops trading" bug fixed alongside
## this test (dead-forever looks like employed_workers==0 and revenue stuck
## at exactly 0.0; a healthy business can still dip below the reference
## wage on any single snapshot day without being dead, so that's not
## asserted here).
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

	print("  day 14:  Farm capacity=%d employed=%d revenue/worker=%.3f | Woodlot capacity=%d employed=%d revenue/worker=%.3f | Trader capacity=%d employed=%d revenue/worker=%.3f | reference=%.3f | total workers=%d" % [
		early["farm"]["capacity"], early["farm"]["employed_workers"], early["farm"]["rolling_average_revenue_per_worker"],
		early["woodlot"]["capacity"], early["woodlot"]["employed_workers"], early["woodlot"]["rolling_average_revenue_per_worker"],
		early["trader"]["capacity"], early["trader"]["employed_workers"], early["trader"]["rolling_average_revenue_per_worker"],
		early["farm"]["reference_wage_per_worker"], early_total_workers])
	print("  day 300: Farm capacity=%d employed=%d revenue/worker=%.3f | Woodlot capacity=%d employed=%d revenue/worker=%.3f | Trader capacity=%d employed=%d revenue/worker=%.3f | reference=%.3f | total workers=%d" % [
		late["farm"]["capacity"], late["farm"]["employed_workers"], late["farm"]["rolling_average_revenue_per_worker"],
		late["woodlot"]["capacity"], late["woodlot"]["employed_workers"], late["woodlot"]["rolling_average_revenue_per_worker"],
		late["trader"]["capacity"], late["trader"]["employed_workers"], late["trader"]["rolling_average_revenue_per_worker"],
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
	_assert(late["trader"]["rolling_average_revenue_per_worker"] > 0.0,
		"Trader should be earning real revenue by day 300, not stuck at 0 like the permanently-dead-capacity bug this test guards against")

## Supplier harvests arrive every few weeks, so a Trader should not lay off
## workers every time a single seven-day stretch contains no surplus. Check
## both the plain and Bloomery economies after their initial adjustment.
func _check_trader_employment_does_not_churn_between_harvests() -> void:
	print("\n=== Trader: staffing remains stable across supplier harvest gaps ===")
	for scenario in ["build_three_business_economy", "build_three_business_economy_with_bloomery"]:
		var sim := _new_sim(scenario)
		var late_layoff_days := 0
		for _day in 500:
			sim.advance_ticks(1)
			if sim.day <= 210:
				continue
			var latest_firing := sim.get_business_employment_events(HEScenarioSeeds.TRADER_BUSINESS_ID, "fired", 1)
			if not latest_firing.is_empty() and latest_firing[0]["day"] == sim.day - 1:
				late_layoff_days += 1
		print("  %s: %d Trader layoff days from day 211 to 500" % [scenario, late_layoff_days])
		# Limit is 5, not 4: with the ranches in the scenario the household
		# basket includes wool, which lifts the reference wage a little above
		# the ranch-less economy's, so the Trader trims one more time while it
		# settles (5 days here vs 2 without ranches). Still a "settles, not
		# thrashes" bound -- the unfixed bug this guards against laid off
		# roughly every three weeks (11+ days).
		# Now 6, not 5, with the 5% sales tax on: sellers keep a little less
		# revenue per worker, so the Trader trims once more while it settles
		# (probed: 4 layoff days at 0% tax, 5 at 2%, 6 at 5%).
		_assert(late_layoff_days <= 6,"Trader repeatedly laid off staff between supplier harvests in %s (%d layoff days)" % [scenario, late_layoff_days])

func _business_snapshot(sim: HESimulation, day: int) -> Dictionary:
	sim.advance_ticks(day - sim.day)
	var out := {}
	for report in sim.get_business_reports():
		out[report["name"].to_lower()] = report
	# A business that exhausted its credit is deleted, so it has no report;
	# stand in an all-zero one so share/capacity checks read it as gone.
	for key in ["farm", "woodlot", "trader"]:
		if not out.has(key):
			out[key] = {"capacity": 0, "employed_workers": 0, "rolling_average_revenue_per_worker": 0.0,
				"reference_wage_per_worker": out.values()[0]["reference_wage_per_worker"]}
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
		_assert((h["worker_sexes"] as Array).size() == worker_ages.size() and (h["dependent_sexes"] as Array).size() == ages.size(),
			"Household %d: sexes out of step with ages (%d/%d workers, %d/%d dependents)" % [household_id, (h["worker_sexes"] as Array).size(), worker_ages.size(), (h["dependent_sexes"] as Array).size(), ages.size()])
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
	# Deliberately NOT "workforce grows": aging adds workers, but the labor
	# market only has so many jobs, and surplus unemployed households
	# emigrate by design (see the emigration check) -- so the endpoint is
	# set by job supply and swings widely with the trajectory (55 vs 90 for
	# the same seed with the ranches on/off). The pipeline working is what
	# the promotions/households assertions above prove; this only guards
	# against the workforce collapsing outright.
	_assert(ending_workforce * 2 >= starting_workforce, "Total city-wide worker capacity should not collapse, got %d -> %d" % [starting_workforce, ending_workforce])

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

	# Reaching the aging threshold only makes a dependent eligible to leave
	# (5%-25% per monthly check, see HEHousehold.leave_home_chance), so allow
	# two more years for the promotion to actually happen.
	sim.advance_ticks(360 * 3)
	var city := sim.get_city_summary()
	print("  adopted dependent's fate three years later: worker_promotions_total=%d (expected >= 1 -- it should have aged up and split off)" % city["worker_promotions_total"])
	_assert(city["worker_promotions_total"] >= 1, "Adopted dependent should keep aging normally and eventually promote to worker, got 0 promotions")
	_check_demographic_invariants(sim)

func _build_orphan_world(_rng: RandomNumberGenerator) -> Dictionary:
	var settlement := HESettlement.new(1, "Testholm")
	var farm_recipe := Recipe.new("farm", {}, {Commodity.Type.GRAIN: 1.6})
	var farm := HEBusiness.new(1, "Farm", farm_recipe, 50, 2)
	# The households begin with enough grain stock that the Farm has no early
	# sales. Give it runway to keep paying wages until those reserves run down;
	# otherwise it fails before this demographic regression reaches adulthood.
	farm.balance = 500.0
	var businesses: Dictionary[int, HEBusiness] = {1: farm}
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

## Checks the herd MECHANICS run sanely on their own, independent of
## monetization (see _check_herd_monetization for that): both ranches grow
## from their seeded starting herd, cull back down once they cross their
## target (proving culled stock actually reaches inventory), sheep
## accumulate a wool trickle, and the two ranches never together claim more
## than the shared settlement grazing pool.
func _check_herds_grow_and_cull() -> void:
	print("\n=== Herds: ranches grow, cull to inventory, and share a land cap ===")
	var sim := _new_sim("build_three_business_economy")
	var intervals := 24 # 24 * HERD_EVAL_INTERVAL_DAYS(90) = ~6 years
	sim.advance_ticks(intervals * HESimulation.HERD_EVAL_INTERVAL_DAYS)

	var cattle: Dictionary = {}
	var sheep: Dictionary = {}
	for report in sim.get_business_reports():
		if report.get("species", "") == "Cattle":
			cattle = report
		elif report.get("species", "") == "Sheep":
			sheep = report

	_assert(not cattle.is_empty() and not sheep.is_empty(), "Expected both a Cattle Ranch and a Sheep Farm in business reports")
	if cattle.is_empty() or sheep.is_empty():
		return

	print("  after %d years: cattle herd=%.1f (cull target %.0f) stock=%.1f | sheep herd=%.1f (cull target %.0f) stock=%.1f wool_stock=%.1f" % [
		intervals * HESimulation.HERD_EVAL_INTERVAL_DAYS / 360, cattle["herd_size"], HESimulation.default_cull_target(HEBusiness.Species.CATTLE, HESimulation.DEFAULT_RANCH_LAND_ACRES[HEBusiness.Species.CATTLE]), cattle["stock"],
		sheep["herd_size"], HESimulation.default_cull_target(HEBusiness.Species.SHEEP, HESimulation.DEFAULT_RANCH_LAND_ACRES[HEBusiness.Species.SHEEP]), sheep["stock"], sheep["wool_stock"]])

	_assert(cattle["herd_size"] > HEScenarioSeeds.CATTLE_STARTING_HERD, "Cattle herd should have grown from its seeded starting size")
	_assert(sheep["herd_size"] > HEScenarioSeeds.SHEEP_STARTING_HERD, "Sheep herd should have grown from its seeded starting size")
	_assert(cattle["herd_size"] <= HESimulation.default_cull_target(HEBusiness.Species.CATTLE, HESimulation.DEFAULT_RANCH_LAND_ACRES[HEBusiness.Species.CATTLE]) + EPSILON, "Cattle herd should never exceed its cull target, got %.2f" % cattle["herd_size"])
	_assert(sheep["herd_size"] <= HESimulation.default_cull_target(HEBusiness.Species.SHEEP, HESimulation.DEFAULT_RANCH_LAND_ACRES[HEBusiness.Species.SHEEP]) + EPSILON, "Sheep herd should never exceed its cull target, got %.2f" % sheep["herd_size"])
	# Where a cull ends up (an outlet's inventory, or home-butchered into
	# meat) depends on which businesses survived, so count the culls themselves.
	var culled := {"Cattle": 0.0, "Sheep": 0.0}
	for record in sim.get_daily_history(730):
		for animal in culled.keys():
			culled[animal] += (record["produced"] as Dictionary).get(animal, 0.0)
	_assert(culled["Cattle"] > 0.0, "Cattle Ranch should have culled at least once in the last two years")
	_assert(culled["Sheep"] > 0.0, "Sheep Farm should have culled at least once in the last two years")
	_assert(sheep["wool_stock"] > 0.0, "Sheep Farm should have accumulated some wool by now")

	var cattle_land: float = cattle["herd_size"] * HESimulation.CATTLE_LAND_PER_HEAD
	var sheep_land: float = sheep["herd_size"] * HESimulation.SHEEP_LAND_PER_HEAD
	print("  grazing land used: cattle %.1f / %.1f acres, sheep %.1f / %.1f acres" % [cattle_land, HESimulation.DEFAULT_RANCH_LAND_ACRES[HEBusiness.Species.CATTLE], sheep_land, HESimulation.DEFAULT_RANCH_LAND_ACRES[HEBusiness.Species.SHEEP]])
	_assert(cattle_land <= HESimulation.DEFAULT_RANCH_LAND_ACRES[HEBusiness.Species.CATTLE] + EPSILON, "The cattle herd should never claim more than its ranch's land, used %.2f" % cattle_land)
	_assert(sheep_land <= HESimulation.DEFAULT_RANCH_LAND_ACRES[HEBusiness.Species.SHEEP] + EPSILON, "The sheep herd should never claim more than its farm's land, used %.2f" % sheep_land)

## Wool sells to local households through the same market Farm/Woodlot use
## (proving _business_selling's new Kind.HERD/Species.SHEEP branch actually
## resolves a seller and clears real trades, not just a phantom demand that
## never funds), and culled Cattle/Sheep stock earns real money through the
## Trader's export pass even though neither ranch employs or pays anyone.
## The player can set a ranch's cull target: the ranch culls back down to it,
## its staff ceiling follows, and out-of-range values are clamped.
func _check_herd_cull_target_is_configurable() -> void:
	print("\n=== Herds: the cull target is configurable per ranch ===")
	var sim := _new_sim("build_three_business_economy")
	var sheep_id := HEScenarioSeeds.SHEEP_FARM_BUSINESS_ID
	var sheep: HEBusiness = sim.businesses[sheep_id]
	var default_target := HESimulation.default_cull_target(HEBusiness.Species.SHEEP, HESimulation.DEFAULT_RANCH_LAND_ACRES[HEBusiness.Species.SHEEP])
	_assert(is_equal_approx(sim.herd_cull_target(sheep), default_target), "An untouched ranch should use its species default cull target")
	var default_capacity := sheep.max_capacity

	# Raising it: the staff ceiling grows with the bigger herd to look after.
	var raised := sim.set_herd_cull_target(sheep_id, 250.0)
	_assert(is_equal_approx(raised, 250.0), "A target inside the allowed range should be applied as given, got %.1f" % raised)
	_assert(sheep.max_capacity > default_capacity, "A bigger cull target should raise the ranch's staff ceiling (%d -> %d)" % [default_capacity, sheep.max_capacity])

	# Lowering it below the herd: next review culls straight down to it.
	var lowered := sim.set_herd_cull_target(sheep_id, 120.0)
	sim.advance_ticks(24 * HESimulation.HERD_EVAL_INTERVAL_DAYS)
	print("  sheep herd after 6 years with target %.0f: %.1f (staff ceiling %d, was %d)" % [lowered, sheep.herd_size, sheep.max_capacity, default_capacity])
	_assert(sheep.herd_size <= lowered + EPSILON, "The herd should never exceed its configured cull target, got %.2f vs %.2f" % [sheep.herd_size, lowered])
	_assert(sheep.max_capacity < default_capacity or default_capacity <= 1, "A smaller cull target should lower the staff ceiling")

	# Out-of-range values are clamped, not trusted.
	var limits := sim.herd_cull_target_range(sheep)
	_assert(is_equal_approx(sim.set_herd_cull_target(sheep_id, 1.0), limits.x), "A target below the hardship floor should clamp up to it")
	_assert(is_equal_approx(sim.set_herd_cull_target(sheep_id, 1000000.0), limits.y), "A target above what the pasture holds should clamp down")
	_assert(sim.set_herd_cull_target(HEScenarioSeeds.FARM_BUSINESS_ID, 100.0) < 0.0, "Setting a cull target on a non-herd business should be rejected")

## Dynamic cull: a young herd past its breeding-stock floor sells part of its
## growth each review, so the first sale lands within a year or so instead of
## ~900 days; switching it off restores hold-until-target.
func _check_herd_dynamic_cull() -> void:
	print("\n=== Herds: dynamic cull sells growth ahead of the cull target ===")
	var cattle_id := HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID
	var results := {}
	for enabled in [true, false]:
		var sim := _new_sim("build_three_business_economy")
		_assert(sim.set_herd_dynamic_cull(cattle_id, enabled) == enabled, "Dynamic cull should be switchable on a ranch")
		var ranch: HEBusiness = sim.businesses[cattle_id]
		var target := sim.herd_cull_target(ranch)
		var culled := 0.0
		var first_cull_day := -1
		for review in 16: # ~4 years
			sim.advance_ticks(HESimulation.HERD_EVAL_INTERVAL_DAYS)
			_assert(ranch.herd_size <= target + EPSILON, "Herd must never exceed its cull target, got %.2f" % ranch.herd_size)
			if ranch.last_actual_units > 0.0:
				culled += ranch.last_actual_units
				if first_cull_day < 0:
					first_cull_day = sim.day
		results[enabled] = first_cull_day
		print("  dynamic=%s: first cull day %d, culled %.1f head in ~4 years, herd now %.1f / %.0f" % [enabled, first_cull_day, culled, ranch.herd_size, target])
	_assert(results[true] > 0 and results[true] <= 360, "Dynamic cull should sell within the first year, got day %d" % results[true])
	_assert(results[false] < 0 or results[false] > 600, "Static cull should hold until the herd nears its target, got day %d" % results[false])
	_assert(HESimulation.dynamic_cull_share(60.0, 150.0) == 0.0 and is_equal_approx(HESimulation.dynamic_cull_share(150.0, 150.0), 1.0), "Share should run from 0 at the breeding floor to 1 at the target")

## Husbandry: a herd's labor must have a real marginal product, or the
## capacity tuner has no stable staffing level to find (it churned the Sheep
## Farm ~400 times in 10 years when staffing changed nothing). Same seed, two
## worlds: ranches with no workers allowed vs. ranches pinned fully staffed
## (pinned by min_capacity so the comparison isn't muddied by hiring noise).
func _check_herd_staffing_matters() -> void:
	print("\n=== Herds: staffing a ranch actually changes how its herd and wool do ===")
	var unstaffed := _new_sim("build_three_business_economy")
	var staffed := _new_sim("build_three_business_economy")
	for business_id in [HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID, HEScenarioSeeds.SHEEP_FARM_BUSINESS_ID]:
		var u: HEBusiness = unstaffed.businesses[business_id]
		u.max_capacity = 0
		u.capacity = 0
		var s: HEBusiness = staffed.businesses[business_id]
		s.capacity = s.max_capacity
		s.min_capacity = s.max_capacity
	unstaffed.advance_ticks(360)
	staffed.advance_ticks(360)

	var cattle_id := HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID
	var sheep_id := HEScenarioSeeds.SHEEP_FARM_BUSINESS_ID
	var cattle_u: HEBusiness = unstaffed.businesses[cattle_id]
	var cattle_s: HEBusiness = staffed.businesses[cattle_id]
	var sheep_u: HEBusiness = unstaffed.businesses[sheep_id]
	var sheep_s: HEBusiness = staffed.businesses[sheep_id]
	print("  after 1 year, cattle herd: unstaffed=%.1f staffed=%.1f (care %.2f vs %.2f) | sheep herd: unstaffed=%.1f staffed=%.1f, wool made last review: %.2f vs %.2f" % [
		cattle_u.herd_size, cattle_s.herd_size, cattle_u.last_care_fraction, cattle_s.last_care_fraction,
		sheep_u.herd_size, sheep_s.herd_size, sheep_u.last_wool_produced, sheep_s.last_wool_produced])
	_assert(cattle_u.last_care_fraction == 0.0, "An unstaffed ranch should apply zero staffed care, got %.2f" % cattle_u.last_care_fraction)
	_assert(cattle_s.last_care_fraction > 0.5, "A fully staffed ranch should apply most of the care it needs, got %.2f" % cattle_s.last_care_fraction)
	_assert(cattle_s.herd_size > cattle_u.herd_size, "A staffed Cattle Ranch's herd should grow faster than an unstaffed one (%.1f vs %.1f)" % [cattle_s.herd_size, cattle_u.herd_size])
	_assert(sheep_s.last_wool_produced > sheep_u.last_wool_produced, "A staffed Sheep Farm should produce more wool per head-review than an unstaffed one (%.2f vs %.2f)" % [sheep_s.last_wool_produced, sheep_u.last_wool_produced])

func _check_herd_monetization() -> void:
	print("\n=== Herds monetize: wool sells locally, culled stock exports through the Trader ===")
	var sim := _new_sim("build_three_business_economy")
	var intervals := 24 # same horizon as _check_herds_grow_and_cull
	sim.advance_ticks(intervals * HESimulation.HERD_EVAL_INTERVAL_DAYS)

	var cattle: Dictionary = {}
	var sheep: Dictionary = {}
	for report in sim.get_business_reports():
		if report.get("species", "") == "Cattle":
			cattle = report
		elif report.get("species", "") == "Sheep":
			sheep = report
	_assert(not cattle.is_empty() and not sheep.is_empty(), "Expected both a Cattle Ranch and a Sheep Farm in business reports")
	if cattle.is_empty() or sheep.is_empty():
		return

	print("  Cattle Ranch balance=%.1f  Sheep Farm balance=%.1f  city export_revenue_total=%.1f" % [
		cattle["balance"], sheep["balance"], sim.get_city_summary()["export_revenue_total"]])
	_assert(cattle["balance"] > 0.0, "Cattle Ranch should have earned real money from the Trader exporting its culled stock, balance is still 0")
	# Husbandry makes a sheep farm's labor pay for itself, so unlike before it
	# should be comfortably in the black at the snapshot, not just noisy.
	_assert(sheep["balance"] > 0.0, "Sheep Farm should have earned real money (wool sold locally and/or its own stock exported), balance is %.1f" % sheep["balance"])

	var market := sim.get_market_summary()
	_assert(market.has("Wool"), "Wool should now be a market commodity alongside Grain/Timber")
	_assert(market["Wool"]["price"] > 0.0, "Wool should have a real market price")

	var any_wool_traded := false
	for record in sim.get_daily_history(360):
		if (record["traded_quantity"] as Dictionary).get("Wool", 0.0) > 0.0001:
			any_wool_traded = true
			break
	_assert(any_wool_traded, "Households should have actually bought wool from the Sheep Farm at least once in the run's final year")

	_check_demographic_invariants(sim)

## A ranch that cannot make payroll slaughters some of its own cattle at home:
## no cash is created, the meat lands in the ranch's inventory (booked as
## production) and is bought by the town's households over the following days,
## and the ranch is not failed for the wage the slaughter was meant to cover.
func _check_hardship_butchery_makes_local_meat() -> void:
	print("\n=== Hardship butchering: a cash-starved ranch slaughters at home and sells meat locally ===")
	var sim := _new_sim("build_three_business_economy")
	var ranch: HEBusiness = sim.businesses[HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID]
	var worker: HEHousehold = null
	for household_id in sim.households.keys():
		var h: HEHousehold = sim.households[household_id]
		if h.worker_capacity() > 0:
			worker = h
			break
	_assert(worker != null, "Expected a household able to staff the ranch")
	if worker == null:
		return
	worker.employer_business_id = ranch.id
	var wage_bill: float = sim.wages.reference_wage_per_worker(ranch.settlement_id) * float(sim._business_employed_worker_count(ranch.id))
	# Just past what the ranch can borrow against its herd (not 60 days of wages).
	# Each head slaughtered also lowers that limit by its collateral, so a small
	# margin is what one slaughter's meat can recover.
	ranch.balance = -sim.wages.overdraft_limit(ranch, wage_bill) - 1.0
	var herd_before := ranch.herd_size
	sim.advance_ticks(1)

	_assert(sim.businesses.has(ranch.id), "A ranch with meat on its shelf to cover payroll should not fail the day it slaughters")
	_assert(ranch.last_hardship_butchered >= 1.0, "A ranch past its wage floor should slaughter at least one head")
	_assert(ranch.herd_size < herd_before, "Hardship butchering should shrink the live herd")
	var day_one: Dictionary = sim.get_daily_history(1)[0]
	_assert((day_one["exported"] as Dictionary).get("Cattle", 0.0) < 0.0001, "Hardship butchering must not be booked as a Trader export")
	var made: float = (day_one["produced"] as Dictionary).get("Meat", 0.0)
	_assert(made >= HESimulation.HOME_BUTCHER_MEAT_PER_HEAD[HEBusiness.Species.CATTLE], "The slaughter should produce meat, made %.1f" % made)
	_assert(ranch.stock(Commodity.Type.CATTLE) < 0.0001, "Home slaughter should not touch the culled-livestock inventory")
	print("  slaughtered %.0f head -> %.1f meat on the shelf (herd %.1f -> %.1f)" % [ranch.last_hardship_butchered, made, herd_before, ranch.herd_size])

	var sold := 0.0
	var balance_after_slaughter := ranch.balance
	# Households only start buying meat once their grain buffers run down, a
	# week or so in, so give them three weeks.
	sim.advance_ticks(20)
	for record in sim.get_daily_history(20):
		sold += (record["traded_quantity"] as Dictionary).get("Meat", 0.0)
	print("  households bought %.1f meat over the next 20 days; ranch balance %.1f -> %.1f" % [sold, balance_after_slaughter, ranch.balance])
	_assert(sold > 0.0001, "Households should buy the ranch's home-butchered meat locally")
	_assert(sim.businesses.has(ranch.id), "The ranch should survive on the meat it sells")
	_assert(ranch.balance > balance_after_slaughter, "Meat sales should repay the ranch's debt")
	_check_demographic_invariants(sim)

## A staffed ranch's husbandry is financed by its herd, not paid for in
## breeding stock: with no income until the cull, it runs an overdraft against
## the herd's value, so it slaughters nothing for payroll, keeps its care up, and
## its herd outgrows an unstaffed ranch's. (Hardship slaughter remains the
## backstop once the borrowing limit is reached -- the test above.)
func _check_herd_collateral_finances_wages() -> void:
	print("\n=== Herd collateral: payroll is financed against the herd, not paid in head ===")
	var results := {}
	for staffed in [false, true]:
		var sim := _new_sim("build_three_business_economy")
		var ranch: HEBusiness = sim.businesses[HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID]
		if staffed:
			ranch.capacity = ranch.max_capacity
			ranch.min_capacity = ranch.max_capacity
		else:
			ranch.max_capacity = 0
			ranch.capacity = 0
		var slaughtered := 0.0
		var lowest_balance := 0.0
		var collateral_at_start: float = sim.wages._herd_collateral(ranch)
		for day in 360:
			sim.advance_ticks(1)
			slaughtered += ranch.last_hardship_butchered
			lowest_balance = minf(lowest_balance, ranch.balance)
		results[staffed] = {"herd": ranch.herd_size, "care": ranch.last_care_fraction, "slaughtered": slaughtered,
			"lowest": lowest_balance, "workers": sim._business_employed_worker_count(ranch.id), "collateral": collateral_at_start}
	var s: Dictionary = results[true]
	var u: Dictionary = results[false]
	print("  unstaffed herd %.1f | staffed herd %.1f (care %.2f, %d workers, %.0f head slaughtered, lowest balance %.0f of %.0f borrowable)" % [
		u["herd"], s["herd"], s["care"], s["workers"], s["slaughtered"], s["lowest"], s["collateral"]])
	_assert(s["workers"] > 0, "Test setup: the staffed ranch should have a crew")
	_assert(s["slaughtered"] < 0.0001, "A ranch borrowing against its herd should slaughter nothing to make payroll, slaughtered %.0f" % s["slaughtered"])
	_assert(s["lowest"] < 0.0 and s["lowest"] >= -s["collateral"] - EPSILON, "It should run an overdraft, within what the herd covers (%.0f of %.0f)" % [-s["lowest"], s["collateral"]])
	_assert(s["care"] > 0.9, "Care should stay near full when payroll is not paid in carcasses, got %.2f" % s["care"])
	_assert(s["herd"] > u["herd"] + 5.0, "A staffed ranch's herd should clearly outgrow an unstaffed one (%.1f vs %.1f)" % [s["herd"], u["herd"]])

## With no staffed Trader or Butcher, a ranch butchers its own cull the day it
## happens: no standing livestock stock, and the meat is sold locally. With an
## outlet staffed, the cull stays in inventory for it to buy.
func _check_cull_without_outlet_is_butchered_at_home() -> void:
	print("\n=== Culls with no Trader or Butcher are butchered at home ===")
	var sim := _new_sim("build_three_business_economy")
	for outlet_id in [HEScenarioSeeds.TRADER_BUSINESS_ID, HEScenarioSeeds.BUTCHER_BUSINESS_ID]:
		var outlet: HEBusiness = sim.businesses[outlet_id]
		outlet.capacity = 0
		outlet.max_capacity = 0
	var ranches := {}
	for business_id in [HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID, HEScenarioSeeds.SHEEP_FARM_BUSINESS_ID]:
		ranches[business_id] = sim.businesses[business_id]
	sim.advance_ticks(24 * HESimulation.HERD_EVAL_INTERVAL_DAYS)
	var produced_meat := 0.0
	for record in sim.get_daily_history(24 * HESimulation.HERD_EVAL_INTERVAL_DAYS):
		produced_meat += (record["produced"] as Dictionary).get("Meat", 0.0)
	_assert(produced_meat > 0.0, "Home-butchered culls should produce meat")
	for business_id in ranches.keys():
		var ranch: HEBusiness = sim.businesses.get(business_id)
		if ranch == null:
			continue
		var animals := ranch.stock(ranch.herd_commodity())
		print("  %s: %d head of livestock held, %.1f meat made over the run" % [ranch.name, int(animals), produced_meat])
		_assert(animals < 0.0001, "%s should hold no culled livestock without an outlet, holds %.1f" % [ranch.name, animals])
	var sees_meat: bool = sim.get_market_summary().has("Meat")
	_assert(sees_meat, "Meat should be listed in the local market once ranches home-butcher")

## Culled cattle are a saleable good: a herd review moves head into the ranch's
## inventory (herd_size stays the living herd), the Butcher buys some, the Trader
## exports only what the Butcher does not take, each transfer is recorded once at
## its source, and the Goods page reports it by channel with no household buyer.
func _check_livestock_goods() -> void:
	print("\n=== Livestock goods: one cull, one Butcher purchase, one Trader export, and the Goods report ===")
	var sim := _new_sim("build_three_business_economy")
	sim.sales_tax_rate = 0.0
	var sid: int = sim.get_settlement_ids()[0]
	var cattle := Commodity.Type.CATTLE
	var ranch: HEBusiness = sim.businesses[HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID]
	var butcher: HEBusiness = sim.businesses[HEScenarioSeeds.BUTCHER_BUSINESS_ID]
	var trader: HEBusiness = sim.businesses[HEScenarioSeeds.TRADER_BUSINESS_ID]
	# Cattle and sheep are ordinary entries in the Trader's export settings, on by default.
	var export_defaults := {}
	for setting in sim.get_trader_export_settings(trader.id):
		export_defaults[setting["name"]] = setting["enabled"]
	_assert(export_defaults.get("Cattle", false) and export_defaults.get("Sheep", false), "Cattle and sheep should be Trader export settings, enabled by default, got %s" % [export_defaults])
	# Free the Trader's capacity for livestock: every other export off.
	for exported_good in HESimulation.EXPORT_PRIORITY:
		if exported_good != cattle:
			sim.set_trader_export_enabled(trader.id, exported_good, false)

	# One cull: the review lands on the last tick of the first interval.
	sim.advance_ticks(HESimulation.HERD_EVAL_INTERVAL_DAYS - 1)
	var target := sim.herd_cull_target(ranch)
	ranch.herd_size = target - 1.0
	sim.advance_ticks(1)
	var culled := ranch.stock(cattle)
	var review: Dictionary = sim.get_daily_history(1)[0]
	_assert(culled > 0.0, "A herd review above the cull target should leave culled head in the ranch's inventory")
	_assert(is_equal_approx(ranch.herd_size, target), "The living herd stays distinct from inventory: back at its cull target %.1f, is %.2f" % [target, ranch.herd_size])
	_assert(is_equal_approx((review["produced"] as Dictionary).get("Cattle", 0.0), culled), "The cull should be booked as production of exactly the head now in inventory")
	_assert(is_equal_approx(float((review["closing_stock"] as Dictionary)["Cattle"]), culled), "Culled head should be counted in the day's closing stock")

	# One Butcher purchase and one export, in the same tick: staff the Butcher,
	# give the ranch plenty to sell, and the Trader takes only what is left.
	var worker: HEHousehold = null
	for household_id in sim.households.keys():
		var h: HEHousehold = sim.households[household_id]
		if h.worker_capacity() > 0:
			worker = h
			break
	worker.employer_business_id = butcher.id
	var buffer_head := float(sim._business_employed_worker_count(butcher.id)) * HESimulation.BUTCHERY_INPUT_BUFFER_DAYS / HESimulation.BUTCHERY_WORKER_DAYS_PER_HEAD[HEBusiness.Species.CATTLE]
	ranch.add_stock(cattle, buffer_head + 20.0)
	var stock_before := ranch.stock(cattle)
	var expected_bought: float = sim._butchery_wanted_head(butcher, HEBusiness.Species.CATTLE)
	# The crew's full buffer, held back to the meat the Butcher expects to sell
	# (HESimulation._butchery_meat_room): with little local meat demand that is
	# a small lot, not the whole buffer.
	var expected_head := minf(buffer_head, sim._butchery_meat_room(butcher) / HESimulation.BUTCHERY_MEAT_PER_HEAD[HEBusiness.Species.CATTLE])
	_assert(is_equal_approx(expected_bought, expected_head), "A freshly staffed Butcher with no livestock should want the lesser of a full buffer (%.1f head) and its meat cover (%.1f head), wants %.1f" % [buffer_head, expected_head, expected_bought])
	sim.advance_ticks(1)
	var bought: float = (butcher.todays_flows[HEBusiness.FLOW_BOUGHT] as Dictionary).get(cattle, 0.0)
	var sold: float = (ranch.todays_flows[HEBusiness.FLOW_SOLD] as Dictionary).get(cattle, 0.0)
	var exported := sold - bought
	var bid := HESimulation.livestock_quote(HEBusiness.Species.CATTLE, HESimulation.LivestockQuote.TRADER_BID)
	var reference := HESimulation.livestock_quote(HEBusiness.Species.CATTLE, HESimulation.LivestockQuote.POSTED)
	_assert(is_equal_approx(bid, reference * HESimulation.TRADER_BUY_PRICE_FRACTION), "The Trader's bid should be its usual fraction of the posted price, as for every export")
	var purchase_price := HESimulation.livestock_quote(HEBusiness.Species.CATTLE, HESimulation.LivestockQuote.BUTCHER_PURCHASE)
	print("  culled %.1f head; then the Butcher bought %.1f and the Trader exported %.1f of %.1f" % [culled, bought, exported, stock_before])
	_assert(is_equal_approx(bought, expected_bought), "The Butcher should buy exactly the head it wanted: %.2f vs %.2f" % [bought, expected_bought])
	_assert(exported > 0.0, "Head the Butcher did not take should be exported")
	_assert(is_equal_approx(ranch.stock(cattle), stock_before - sold), "Ranch inventory should fall by exactly the head sold")
	_assert(is_equal_approx(ranch.last_revenue, bought * purchase_price + exported * bid), "The ranch is paid the Butcher's quote for local head and the Trader bid for exported head")
	var day_record: Dictionary = sim.get_daily_history(1)[0]
	_assert(is_equal_approx((day_record["traded_quantity"] as Dictionary).get("Cattle", 0.0), bought), "Only locally bought head count as traded")
	_assert(is_equal_approx((day_record["exported"] as Dictionary).get("Cattle", 0.0), exported), "Only the Trader's head count as exported; none is both")

	var transactions := sim.get_livestock_transactions(sid, cattle, 1)
	var purchase_rows := transactions.filter(func(t): return t["channel"] == "butcher_purchase")
	var export_rows := transactions.filter(func(t): return t["channel"] == "trader_export")
	_assert(purchase_rows.size() == 1 and export_rows.size() == 1, "The tick should record one local purchase and one export, got %d and %d" % [purchase_rows.size(), export_rows.size()])
	if purchase_rows.size() == 1 and export_rows.size() == 1:
		_assert(is_equal_approx(purchase_rows[0]["quantity"], bought) and is_equal_approx(purchase_rows[0]["unit_price"], purchase_price) \
			and purchase_rows[0]["seller_id"] == ranch.id and purchase_rows[0]["buyer_id"] == butcher.id, "The purchase record should name the ranch, the Butcher, the head and the Butcher's quote")
		_assert(is_equal_approx(export_rows[0]["quantity"], exported) and is_equal_approx(export_rows[0]["unit_price"], reference) \
			and is_equal_approx(export_rows[0]["paid_price"], bid) and export_rows[0]["buyer_id"] == trader.id, "The export record should carry the reference and the bid")

	# The Goods page reads the good like any other: one trading price and the same
	# row shape, the Butcher's held input at what it paid, the Trader as an export
	# buyer, and no household.
	var summary := sim.get_market_summary()
	_assert(summary.has("Cattle") and summary.has("Sheep"), "Cattle and sheep should be listed while ranches and a Butcher exist")
	var row: Dictionary = summary["Cattle"]
	var row_keys := row.keys()
	var grain_keys: Array = (summary["Grain"] as Dictionary).keys()
	row_keys.sort()
	grain_keys.sort()
	_assert(row_keys == grain_keys, "A livestock row should have exactly the shape of any other good's row, got %s vs %s" % [row_keys, grain_keys])
	_assert(is_equal_approx(row["price"], reference), "The row's one price is the posted price, like another good's market price; the Trader and Butcher pay fractions of it")
	_assert(is_equal_approx(row["last_clearing"]["quantity_traded"], bought) and is_equal_approx(row["last_clearing"]["exported"], exported), "The row's last day should split local sales from exports")
	var detail := sim.get_market_detail(sid, cattle)
	var holding: Dictionary = {}
	for h in detail["holdings"]:
		if h["business_id"] == butcher.id:
			holding = h
	_assert(not holding.is_empty() and is_equal_approx(holding["value"], butcher.stock(cattle) * purchase_price), "The Butcher's held head should be valued at what it paid")
	var export_buyers: Array = detail["buyers"].filter(func(b): return b.get("kind", "") == "export")
	_assert(export_buyers.size() == 1 and export_buyers[0].has("capacity") and export_buyers[0].has("available"), "The Trader should appear once, as an export buyer with its capacity, like for any good")
	_assert(detail["buyers"].all(func(b): return b.get("kind", "") != "household"), "No household buys live cattle")
	_assert(detail["need"].is_empty() and detail["price_signal"].is_empty(), "Livestock has no household need and no local price drift")

	# No spurious rows: nothing to sell, buy or export means no livestock listing,
	# and a Trader alone (spare export capacity) does not create one.
	for included in [[HEScenarioSeeds.FARM_BUSINESS_ID, HEScenarioSeeds.WOODLOT_BUSINESS_ID], [HEScenarioSeeds.FARM_BUSINESS_ID, HEScenarioSeeds.TRADER_BUSINESS_ID]]:
		var bare := HESimulation.new(SEED, func(rng): return HEFixtures.build_custom(rng, included), true)
		bare.advance_ticks(30)
		var bare_summary := bare.get_market_summary()
		_assert(not bare_summary.has("Cattle") and not bare_summary.has("Sheep"), "A settlement with no ranch or Butcher should list no livestock, roster %s" % [included])

## Livestock export is an ordinary Trader setting: with a staffed Trader and the
## cattle checkbox on, a cull waits in the ranch's inventory for it; with the box
## off and no Butcher, the Trader is not an outlet and the ranch butchers its own
## cull the same day instead of stockpiling it.
func _check_livestock_export_toggle() -> void:
	print("\n=== Livestock export is a Trader setting: switched off, the ranch butchers its own cull ===")
	var cattle := Commodity.Type.CATTLE
	var by_setting := {}
	for enabled in [true, false]:
		var roster := [HEScenarioSeeds.FARM_BUSINESS_ID, HEScenarioSeeds.WOODLOT_BUSINESS_ID, HEScenarioSeeds.TRADER_BUSINESS_ID, HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID]
		var sim := HESimulation.new(SEED, func(rng): return HEFixtures.build_custom(rng, roster), true)
		sim.set_trader_export_enabled(HEScenarioSeeds.TRADER_BUSINESS_ID, cattle, enabled)
		var ranch: HEBusiness = sim.businesses[HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID]
		sim.advance_ticks(HESimulation.HERD_EVAL_INTERVAL_DAYS - 1)
		ranch.herd_size = sim.herd_cull_target(ranch) - 1.0
		sim.advance_ticks(1)
		var review: Dictionary = sim.get_daily_history(1)[0]
		by_setting[enabled] = {"culled": (review["produced"] as Dictionary).get("Cattle", 0.0), "held": ranch.stock(cattle), "meat": (review["produced"] as Dictionary).get("Meat", 0.0)}
	print("  export on: held %.1f of %.1f culled, %.1f meat | export off: held %.1f, %.1f meat" % [
		by_setting[true]["held"], by_setting[true]["culled"], by_setting[true]["meat"], by_setting[false]["held"], by_setting[false]["meat"]])
	_assert(by_setting[true]["culled"] > 0.0 and by_setting[false]["culled"] > 0.0, "Both runs should cull at the first review")
	_assert(is_equal_approx(by_setting[true]["held"], by_setting[true]["culled"]) and by_setting[true]["meat"] < 0.0001, "With export on, the cull waits in inventory for the Trader and nothing is home-butchered")
	_assert(by_setting[false]["held"] < 0.0001 and by_setting[false]["meat"] > 0.0, "With export off and no Butcher, the ranch should butcher the cull at home")

## The Butcher turns a ranch's cull into meat and leather instead of the Trader
## exporting it raw, and households eat the meat (twice grain's food value) and
## may wear the leather. Run for four years so both ranches have culled
## several times, reconciling goods and money every single day.
## Starts each ranch within one review's growth of its cull target, so its first
## cull lands in the first year instead of 1.5-3 years in. The Butcher is hired on
## day one and pays wages from a small startup reserve; with the seeded herds
## (100 head against targets of 150 and 200) it fails before it ever sees an
## animal, which makes any check of what it does vacuous. See the TODO on hiring
## in he_simulation.gd's _reconcile_employment.
func _seed_ranches_near_cull_target(sim: HESimulation, share_of_target: float = 0.97) -> void:
	for business_id in sim.businesses.keys():
		var b: HEBusiness = sim.businesses[business_id]
		if b.kind == HEBusiness.Kind.HERD:
			b.herd_size = floorf(sim.herd_cull_target(b) * share_of_target)
			b.collateral_herd = b.herd_size

## The Butcher's first cull is bought on credit; the animals it holds must secure
## its wage overdraft (as a ranch's herd does) and it starts with working capital
## for a first buffer of cattle, so it does not fail the day after buying.
func _check_butcher_credit(sim: HESimulation) -> void:
	var butcher: HEBusiness = sim.businesses[HEScenarioSeeds.BUTCHER_BUSINESS_ID]
	var wage_bill := 2.0 * 0.8
	var empty_limit := sim.wages.overdraft_limit(butcher, wage_bill)
	var start_cash := butcher.balance
	butcher.add_stock(Commodity.Type.CATTLE, 20.0)
	var held_limit := sim.wages.overdraft_limit(butcher, wage_bill)
	var collateral := 20.0 * HESimulation.livestock_quote(HEBusiness.Species.CATTLE, HESimulation.LivestockQuote.TRADER_BID) * HESimulation.HERD_COLLATERAL_FRACTION
	butcher.consume(Commodity.Type.CATTLE, 20.0)
	print("  Butcher: start cash %.0f | overdraft limit %.1f empty, %.1f holding 20 cattle (collateral %.1f)" % [start_cash, empty_limit, held_limit, collateral])
	_assert(held_limit > empty_limit and absf(held_limit - maxf(empty_limit, collateral)) < EPSILON, "Held livestock should secure the Butcher's wage overdraft")
	var buffer_cost := 2.0 * HESimulation.BUTCHERY_INPUT_BUFFER_DAYS / HESimulation.BUTCHERY_WORKER_DAYS_PER_HEAD[HEBusiness.Species.CATTLE] 		* HESimulation.livestock_quote(HEBusiness.Species.CATTLE, HESimulation.LivestockQuote.BUTCHER_PURCHASE)
	_assert(start_cash >= buffer_cost - EPSILON, "The Butcher should start with cash for its first buffer of cattle (%.0f vs %.0f)" % [start_cash, buffer_cost])

func _check_butcher_processes_livestock() -> void:
	print("\n=== Butcher: ranch culls become meat and leather, which households eat ===")
	var sim := _new_sim("build_three_business_economy")
	_seed_ranches_near_cull_target(sim)
	_check_butcher_credit(sim)
	var butcher: HEBusiness = sim.businesses[HEScenarioSeeds.BUTCHER_BUSINESS_ID]
	_assert(butcher.processes_livestock and butcher.sells(Commodity.Type.MEAT) and butcher.sells(Commodity.Type.LEATHER),
		"The seeded Butcher should process livestock into meat and leather")
	_assert(sim._business_selling(sim.get_settlement_ids()[0], Commodity.Type.LEATHER) == butcher,
		"The Butcher should be the local seller of its secondary output too")

	var reconciled_commodities := HESimulation.SUBSISTENCE_COMMODITIES.duplicate()
	reconciled_commodities.append_array(HESimulation.LIVESTOCK_GOODS)
	var produced := {}
	var consumed := {}
	var exported := {}
	var worst_stock_gap := 0.0
	var worst_money_gap := 0.0
	for window in 4:
		sim.advance_ticks(360)
		for record in sim.get_daily_history(360):
			for c in reconciled_commodities:
				var name := Commodity.name_of(c)
				var day_produced: float = record["produced"].get(name, 0.0)
				var day_consumed: float = record["consumed"].get(name, 0.0)
				var day_exported: float = (record["exported"] as Dictionary).get(name, 0.0)
				var written_off: float = (record["goods_written_off"] as Dictionary).get(c, 0.0)
				var expected: float = record["opening_stock"][name] + day_produced - day_consumed - day_exported - written_off
				worst_stock_gap = maxf(worst_stock_gap, absf(record["closing_stock"][name] - expected))
				produced[name] = produced.get(name, 0.0) + day_produced
				consumed[name] = consumed.get(name, 0.0) + day_consumed
				exported[name] = exported.get(name, 0.0) + day_exported
			var expected_money: float = record["opening_money"] - float(record["money_written_off"]) + float(record["export_revenue"]) - float(record["import_cost"])
			worst_money_gap = maxf(worst_money_gap, absf(record["closing_money"] - expected_money))

	var butchered: float = consumed.get("Cattle", 0.0) + consumed.get("Sheep", 0.0)
	var exported_raw: float = exported.get("Cattle", 0.0) + exported.get("Sheep", 0.0)
	print("  over 4 years: butchered %.0f head (exported raw: %.0f) -> meat %.0f, leather %.0f | households ate %.0f meat" % [
		butchered, exported_raw, produced.get("Meat", 0.0), produced.get("Leather", 0.0), consumed.get("Meat", 0.0)])
	print("  worst stock gap %.4f, worst money gap %.4f" % [worst_stock_gap, worst_money_gap])
	_assert(butchered > 0.0, "The Butcher should have processed some livestock in four years")
	_assert(produced.get("Meat", 0.0) > 0.0 and produced.get("Leather", 0.0) > 0.0, "The Butcher should have made both meat and leather")
	# The Butcher is sized to what households buy (HESimulation._butchery_meat_room),
	# so the rest of a cull leaves raw through the Trader instead of becoming a
	# meat glut: what it makes must be eaten.
	_assert(consumed.get("Meat", 0.0) >= 0.8 * produced.get("Meat", 0.0), "Households should eat most of the meat made, not leave a glut (%.0f eaten of %.0f made)" % [consumed.get("Meat", 0.0), produced.get("Meat", 0.0)])
	_assert(consumed.get("Meat", 0.0) > 0.0, "Households should have eaten some of the meat")
	# Meat sits near price parity with grain. Households judge that price a
	# little differently, so demand shifts gradually across it; if they all
	# agreed, every household would flip together each time the price crossed
	# parity and demand would alternate between everyone and no one.
	var demanded: Array = sim.get_market_report(sim.get_settlement_ids()[0], Commodity.Type.MEAT)["demanded_history"]
	var zero_demand_days := 0
	for v in demanded:
		if v <= 0.0001:
			zero_demand_days += 1
	print("  meat demand: %d zero-demand days in the last %d" % [zero_demand_days, demanded.size()])
	_assert(zero_demand_days <= 5, "Meat demand should not swing to zero as households all flip satisfier together: %d zero days of %d" % [zero_demand_days, demanded.size()])
	_assert(worst_stock_gap < EPSILON, "Goods did not reconcile with a Butcher present, worst gap %.4f" % worst_stock_gap)
	_assert(worst_money_gap < EPSILON, "Money did not reconcile with a Butcher present, worst gap %.4f" % worst_money_gap)
	_check_demographic_invariants(sim)

## The Toolsmith buys the Bloomery's iron locally (instead of the Trader
## exporting all of it at half price) and sells tools to households, which use
## them at the pooled model's 0.005 per person per day. Two years, reconciling
## goods and money every day.
func _check_toolsmith_supplies_tools() -> void:
	print("\n=== Toolsmith: iron becomes tools, which households use ===")
	var sim := _new_sim("build_economy_with_toolsmith")
	var settlement_id: int = sim.get_settlement_ids()[0]
	var toolsmith: HEBusiness = sim.businesses[HEScenarioSeeds.TOOLSMITH_BUSINESS_ID]
	_assert(toolsmith.sells(Commodity.Type.TOOLS) and toolsmith.recipe.inputs.has(Commodity.Type.IRON),
		"The seeded Toolsmith should turn iron into tools")
	_assert(sim._business_selling(settlement_id, Commodity.Type.TOOLS) == toolsmith, "The Toolsmith should be the local seller of tools")
	_assert(not _new_sim("build_economy_with_bloomery_and_iron_mine").businesses.has(HEScenarioSeeds.TOOLSMITH_BUSINESS_ID),
		"Only the Toolsmith scenario should seed a Toolsmith")

	var reconciled_commodities := HESimulation.SUBSISTENCE_COMMODITIES.duplicate()
	reconciled_commodities.append_array(HESimulation.LIVESTOCK_GOODS)
	reconciled_commodities.append(Commodity.Type.IRON)
	var produced := {}
	var consumed := {}
	var worst_stock_gap := 0.0
	var worst_money_gap := 0.0
	for window in 2:
		sim.advance_ticks(360)
		for record in sim.get_daily_history(360):
			for c in reconciled_commodities:
				var name := Commodity.name_of(c)
				var day_produced: float = record["produced"].get(name, 0.0)
				var day_consumed: float = record["consumed"].get(name, 0.0)
				var day_exported: float = (record["exported"] as Dictionary).get(name, 0.0)
				var day_imported: float = (record["imported"] as Dictionary).get(name, 0.0)
				var written_off: float = (record["goods_written_off"] as Dictionary).get(c, 0.0)
				var expected: float = record["opening_stock"][name] + day_produced + day_imported - day_consumed - day_exported - written_off
				worst_stock_gap = maxf(worst_stock_gap, absf(record["closing_stock"][name] - expected))
				produced[name] = produced.get(name, 0.0) + day_produced
				consumed[name] = consumed.get(name, 0.0) + day_consumed
			var expected_money: float = record["opening_money"] - float(record["money_written_off"]) + float(record["export_revenue"]) - float(record["import_cost"])
			worst_money_gap = maxf(worst_money_gap, absf(record["closing_money"] - expected_money))

	# Survival is deliberately not asserted: a business that exhausts its credit
	# is deleted, and the Toolsmith's imported iron depends on the Trader, which
	# the seeded economy can lose.
	print("  over 2 years: toolsmith made %.0f tools from %.0f iron; households used %.0f | still open: %s" % [
		produced.get("Tools", 0.0), consumed.get("Iron", 0.0), consumed.get("Tools", 0.0), sim.businesses.has(toolsmith.id)])
	print("  worst stock gap %.4f, worst money gap %.4f" % [worst_stock_gap, worst_money_gap])
	_assert(produced.get("Tools", 0.0) > 0.0 and consumed.get("Iron", 0.0) > 0.0, "The Toolsmith should have turned some iron into tools")
	_assert(consumed.get("Tools", 0.0) > 0.0, "Households should have used some tools")
	_assert(worst_stock_gap < EPSILON, "Goods did not reconcile with a Toolsmith present, worst gap %.4f" % worst_stock_gap)
	_assert(worst_money_gap < EPSILON, "Money did not reconcile with a Toolsmith present, worst gap %.4f" % worst_money_gap)
	_check_demographic_invariants(sim)

## Industrial tools (docs/tools-industrial-demand-plan.md): tool-using
## businesses wear tools out, buy replacements from the Toolsmith and lose
## output without them, down to a floor -- but only in a town with a seller of
## tools, so every scenario without a Toolsmith is unaffected.
func _check_industrial_tools_model() -> void:
	print("\n=== Industrial tools: coverage, floor, wear, gate ===")
	var floor_value := HEBusiness.TOOL_PRODUCTIVITY_FLOOR
	var farm := HEScenarioSeeds.make_farm(1, 1, 4)
	_assert(farm.uses_tools() and is_equal_approx(farm.tool_wear_per_worker_day, 1.0 / 300.0), "A Farm should use tools, worn out over 300 worker-days")
	_assert(not HEScenarioSeeds.make_toolsmith(2, 1).uses_tools(), "The Toolsmith should not use tools yet (its stock is also its product)")
	_assert(is_equal_approx(farm.tool_productivity(4), floor_value), "No tools should give exactly the floor")
	farm.add_stock(Commodity.Type.TOOLS, 2.0)
	_assert(is_equal_approx(farm.tool_coverage(4), 0.5) and is_equal_approx(farm.tool_productivity(4), floor_value + (1.0 - floor_value) * 0.5),
		"Half the crew equipped should give halfway between the floor and full")
	farm.add_stock(Commodity.Type.TOOLS, 20.0)
	_assert(is_equal_approx(farm.tool_productivity(4), 1.0), "More tools than workers should not exceed 1.0")
	_assert(is_equal_approx(farm.tool_productivity(0), 1.0), "No workers need no tools")

	# On, with a toolsmith in town: floor without tools, wear when held.
	var worn_sim := _new_sim("build_economy_with_toolsmith")
	var worn_farm: HEBusiness = worn_sim.businesses[HEScenarioSeeds.FARM_BUSINESS_ID]
	worn_farm.inventory[Commodity.Type.TOOLS] = 0.0
	_assert(is_equal_approx(worn_sim._tool_productivity(worn_farm), floor_value), "A toolless Farm should sit at the floor when tools are on and sold in town")
	var crew := worn_sim._business_employed_worker_count(worn_farm.id)
	# Exactly its purchase target, so today's purchasing has nothing to add and
	# the day's change is pure wear.
	var target: float = float(crew) * (worn_farm.tools_per_worker + worn_farm.tool_wear_per_worker_day * HESimulation.PRODUCTION_INPUT_BUFFER_DAYS)
	worn_farm.inventory[Commodity.Type.TOOLS] = target
	_assert(is_equal_approx(worn_sim._tool_productivity(worn_farm), 1.0), "A fully equipped Farm should be at 1.0")
	worn_sim.advance_ticks(1)
	var expected_left: float = target - float(crew) * worn_farm.tool_wear_per_worker_day
	_assert(absf(worn_farm.stock(Commodity.Type.TOOLS) - expected_left) < 0.0001,
		"One day should wear workers x wear-rate tools: have %.4f, expected %.4f" % [worn_farm.stock(Commodity.Type.TOOLS), expected_left])

	# On, no toolsmith: no tools economy, so no wear and no productivity loss.
	var bare_sim := _new_sim("build_three_business_economy")
	var bare_farm: HEBusiness = bare_sim.businesses[HEScenarioSeeds.FARM_BUSINESS_ID]
	_assert(is_equal_approx(bare_sim._tool_productivity(bare_farm), 1.0), "Without a tools seller, productivity should stay 1.0")
	bare_farm.add_stock(Commodity.Type.TOOLS, 5.0)
	bare_sim.advance_ticks(3)
	_assert(is_equal_approx(bare_farm.stock(Commodity.Type.TOOLS), 5.0), "Without a tools seller, tools should not wear")
	print("  coverage maths, floor, gate and wear as expected")

	# Bootstrap: a town with a Toolsmith starts every tool user equipped for its
	# day-one crew; a town without one holds no tools at all.
	var seeded := _new_sim("build_economy_with_toolsmith")
	var equipped_users := 0
	for business in seeded.businesses.values():
		if business.uses_tools():
			equipped_users += 1
			_assert(business.stock(Commodity.Type.TOOLS) >= float(business.capacity) * business.tools_per_worker - 0.0001,
				"%s should start equipped for its day-one crew" % business.name)
	_assert(equipped_users >= 2, "The toolsmith scenario should have tool users to equip")
	_assert(bare_farm.stock(Commodity.Type.TOOLS) == 5.0 and _new_sim("build_three_business_economy").businesses[HEScenarioSeeds.FARM_BUSINESS_ID].stock(Commodity.Type.TOOLS) == 0.0,
		"A town without a Toolsmith should seed no tools")
	# A business built mid-run gets the money for its first tools.
	var created := HEScenarioSeeds.make_iron_mine(seeded.next_business_id(), HEScenarioSeeds.SETTLEMENT_ID)
	var created_crew := clampi(HEScenarioSeeds.NEW_BUSINESS_STARTING_CAPACITY, seeded._capacity_floor(created), created.max_capacity)
	seeded.add_new_business(created)
	var tool_price: float = (seeded.markets[HEScenarioSeeds.SETTLEMENT_ID] as HEMarket).price[Commodity.Type.TOOLS]
	var expected_cash: float = HEScenarioSeeds.startup_cash(created, created_crew) + float(created_crew) * created.tools_per_worker * tool_price
	_assert(absf(created.balance - expected_cash) < 0.0001, "A created tool user's startup cash should include its first tools: %.2f vs %.2f" % [created.balance, expected_cash])

	# Purchasing: a business with no tools buys them from the Toolsmith and climbs
	# back off the floor.
	var buy_sim := _new_sim("build_economy_with_toolsmith")
	var buy_farm: HEBusiness = buy_sim.businesses[HEScenarioSeeds.FARM_BUSINESS_ID]
	buy_farm.inventory[Commodity.Type.TOOLS] = 0.0
	# The market view lists the starved farm among the tools buyers.
	var tool_detail := buy_sim.get_market_detail(HEScenarioSeeds.SETTLEMENT_ID, Commodity.Type.TOOLS)
	var farm_listed := false
	for buyer in tool_detail["buyers"]:
		if buyer.get("business_id", -1) == buy_farm.id:
			farm_listed = true
	_assert(farm_listed, "A tool-short business should appear among the tools market's buyers")
	buy_sim.advance_ticks(40)
	var restocked := buy_farm.stock(Commodity.Type.TOOLS)
	var restocked_productivity := buy_sim._tool_productivity(buy_farm)
	print("  farm restocked from nothing: %.1f tools, productivity %.2f after 40 days" % [restocked, restocked_productivity])
	_assert(restocked > 1.0 and restocked_productivity > floor_value + 0.1, "An unequipped Farm should buy tools from the Toolsmith and recover")

	# Goods and money reconcile with wear in the books. Every tool user starts
	# equipped so wear actually runs.
	var run_sim := _new_sim("build_economy_with_toolsmith")
	for business_id in run_sim.businesses.keys():
		var b: HEBusiness = run_sim.businesses[business_id]
		if b.uses_tools():
			b.add_stock(Commodity.Type.TOOLS, 20.0)
	var reconciled := HESimulation.SUBSISTENCE_COMMODITIES.duplicate()
	reconciled.append_array(HESimulation.LIVESTOCK_GOODS)
	reconciled.append(Commodity.Type.IRON)
	var worn_total := 0.0
	var worst_stock_gap := 0.0
	var worst_money_gap := 0.0
	run_sim.advance_ticks(360)
	for record in run_sim.get_daily_history(360):
		for c in reconciled:
			var name := Commodity.name_of(c)
			var expected: float = record["opening_stock"][name] + record["produced"].get(name, 0.0) + (record["imported"] as Dictionary).get(name, 0.0) \
				- record["consumed"].get(name, 0.0) - (record["exported"] as Dictionary).get(name, 0.0) - (record["goods_written_off"] as Dictionary).get(c, 0.0)
			worst_stock_gap = maxf(worst_stock_gap, absf(record["closing_stock"][name] - expected))
		var expected_money: float = record["opening_money"] - float(record["money_written_off"]) + float(record["export_revenue"]) - float(record["import_cost"])
		worst_money_gap = maxf(worst_money_gap, absf(record["closing_money"] - expected_money))
		worn_total += record["consumed"].get("Tools", 0.0)
	print("  360 days: %.1f tools consumed (households + wear) | worst stock gap %.4f, worst money gap %.4f" % [worn_total, worst_stock_gap, worst_money_gap])
	_assert(worst_stock_gap < EPSILON, "Goods did not reconcile with industrial tool wear, worst gap %.4f" % worst_stock_gap)
	_assert(worst_money_gap < EPSILON, "Money did not reconcile with industrial tool wear, worst gap %.4f" % worst_money_gap)

## The catalog is what every consumption/market/reserve loop reads, so pin its
## shape: the three needs, today's one satisfier each, and food alone driving
## the lifecycle engine.
func _check_needs_catalog() -> void:
	print("\n=== Household needs: catalog ===")
	var ids: Array = []
	for need in HENeeds.all():
		ids.append(need.id)
	_assert(ids == [HENeed.Id.FOOD, HENeed.Id.HEAT, HENeed.Id.CLOTHING, HENeed.Id.TOOLS], "Needs should be food, heat, clothing, tools in that order")
	_assert(HESimulation.SUBSISTENCE_COMMODITIES == [Commodity.Type.MEAT, Commodity.Type.GRAIN, Commodity.Type.CHARCOAL, Commodity.Type.TIMBER, Commodity.Type.LEATHER, Commodity.Type.WOOL, Commodity.Type.TOOLS],
		"Subsistence commodities should be the union of every need's satisfiers, in need order")
	for need in HENeeds.all():
		_assert(need.is_satisfied_by(need.baseline), "%s's baseline should be one of its satisfiers" % need.label)
		_assert(need.drives_lifecycle == (need.id == HENeed.Id.FOOD), "Only food should drive the lifecycle engine (%s)" % need.label)
	_assert(HENeeds.for_commodity(Commodity.Type.GRAIN).id == HENeed.Id.FOOD, "Grain should satisfy food")
	_assert(HENeeds.for_commodity(Commodity.Type.IRON) == null, "Iron satisfies no household need")
	_assert(HENeeds.for_commodity(Commodity.Type.MEAT).id == HENeed.Id.FOOD, "Meat should satisfy food")
	_assert(is_equal_approx(HENeeds.get_need(HENeed.Id.FOOD).value_of(Commodity.Type.MEAT), 2.0 * HENeeds.get_need(HENeed.Id.FOOD).value_of(Commodity.Type.GRAIN)),
		"Meat should be worth twice grain as food")
	_assert(HENeeds.get_need(HENeed.Id.FOOD).satisfiers()[0] == Commodity.Type.MEAT, "Meat is the denser food, so it should burn before grain")
	_assert(is_equal_approx(HENeeds.units_per_person_daily(Commodity.Type.MEAT), 0.2), "A person needs half as much meat as grain")
	_assert(HENeeds.for_commodity(Commodity.Type.LEATHER).id == HENeed.Id.CLOTHING, "Leather should satisfy clothing")
	_assert(is_equal_approx(HENeeds.get_need(HENeed.Id.CLOTHING).value_of(Commodity.Type.LEATHER), HENeeds.get_need(HENeed.Id.CLOTHING).value_of(Commodity.Type.WOOL)),
		"Leather and wool should clothe one-for-one")
	_assert(HENeeds.get_need(HENeed.Id.CLOTHING).baseline == Commodity.Type.WOOL and HENeeds.get_need(HENeed.Id.FOOD).baseline == Commodity.Type.GRAIN,
		"Baselines should stay wool and grain")
	_assert(is_equal_approx(HENeeds.units_per_person_daily(Commodity.Type.GRAIN), 0.4), "Grain per person per day should stay 0.4")
	_assert(HENeeds.units_per_person_daily(Commodity.Type.IRON) == 0.0, "A good that satisfies no need has no daily use")

	# The Needs tab lists the catalog, so a new need can't be forgotten there.
	var tab_order: Array = HENeeds.display_order()
	for need in HENeeds.all():
		_assert(tab_order.has(need.id), "%s is missing from the Needs tab" % need.label)
	_assert(tab_order.size() == HENeeds.all().size(), "The Needs tab should list each need exactly once")

	# Tools: morale only. Going without costs no health, having them lifts
	# morale, and the lift offsets other penalties (an unemployed household here).
	var tools_need := HENeeds.get_need(HENeed.Id.TOOLS)
	_assert(tools_need.health_weight == 0.0 and tools_need.morale_bonus > 0.0, "Tools should be a morale-only need")
	var bonus_household := HEHousehold.new(1, 2, 2)
	var base_morale := bonus_household.morale()
	_assert(not bonus_household.is_employed() and base_morale < 1.0, "Fixture household should start with an unemployment penalty")
	bonus_household.last_need_required[HENeed.Id.TOOLS] = 0.1
	bonus_household.last_need_provided[HENeed.Id.TOOLS] = 0.05
	_assert(bonus_household.morale_bonuses().is_empty() and is_equal_approx(bonus_household.morale(), base_morale), "A half-met tools need should give no morale bonus")
	bonus_household.last_need_provided[HENeed.Id.TOOLS] = 0.1
	_assert(bonus_household.morale_bonuses().size() == 1 and is_equal_approx(bonus_household.morale(), minf(1.0, base_morale + tools_need.morale_bonus)),
		"A met tools need should lift morale by its bonus")
	_assert(is_equal_approx(bonus_household.health(), 1.0), "Tools must not change health")

	# Morale can pass 100% when bonuses outweigh penalties, and only that excess
	# is a production bonus.
	var happy_household := HEHousehold.new(2, 2, 2)
	happy_household.employer_business_id = 1
	_assert(is_equal_approx(happy_household.morale(), 1.0) and is_equal_approx(happy_household.productivity_multiplier(), 1.0),
		"A household with no penalties or bonuses should sit at exactly 100% morale and no output bonus")
	happy_household.last_need_required[HENeed.Id.TOOLS] = 0.1
	happy_household.last_need_provided[HENeed.Id.TOOLS] = 0.1
	_assert(happy_household.morale() > 1.0 and happy_household.morale() <= HEHousehold.MORALE_MAX,
		"Bonuses with no penalties should carry morale above 100%, under the ceiling")
	_assert(is_equal_approx(happy_household.productivity_multiplier(), 1.0 + tools_need.morale_bonus * HEHousehold.MORALE_PRODUCTIVITY_PER_POINT),
		"Morale above 100% should become the same fraction of extra output")
	_assert(is_equal_approx(bonus_household.productivity_multiplier(), 1.0), "Morale below 100% must not cost output")
	var sim := _new_sim("build_economy_with_bloomery_and_iron_mine")
	var bloomery: HEBusiness = sim.businesses[HEScenarioSeeds.BLOOMERY_BUSINESS_ID]
	_assert(bloomery.need_inputs == {Commodity.Type.TIMBER: HENeed.Id.HEAT}, "The Bloomery's timber input should be a heat slot")
	print("  catalog shape and Bloomery heat slot as expected")

	# The household detail page reads this: one entry per need, in need units.
	sim.advance_ticks(3)
	var h := sim.get_household_summary(sim.get_household_ids()[0])
	var needs: Array = h["needs"]
	_assert(needs.size() == HENeeds.all().size(), "A household summary should report every need")
	for i in needs.size():
		var need: HENeed = HENeeds.all()[i]
		var entry: Dictionary = needs[i]
		_assert(entry["label"] == need.label, "Summary needs should follow catalog order")
		_assert(is_equal_approx(entry["required"], h["headcount"] * need.per_person_daily),
			"%s required should be headcount x per-person daily need" % need.label)
		_assert(entry["provided"] <= entry["required"] + EPSILON, "%s cannot be provided beyond what is required" % need.label)
		_assert((entry["satisfiers"] as Array).size() == need.satisfiers().size(), "%s should list each of its satisfiers" % need.label)
	print("  household summary reports each need's required/provided and its satisfiers")

## Today's catalog gives every need a single satisfier, so substitution can't
## show up in a scenario run. Exercise it with a fixture need -- timber (1
## unit) or a denser stand-in (4 units) -- so the next real satisfier (charcoal
## for heat, meat for food, ...) lands on logic that is already checked.
func _check_need_substitutes() -> void:
	print("\n=== Household needs: substitutable satisfiers ===")
	var units: Dictionary[Commodity.Type, float] = {Commodity.Type.WOOL: 4.0, Commodity.Type.TIMBER: 1.0}
	var need := HENeed.new(HENeed.Id.HEAT, "Fixture heat", 0.5, units, Commodity.Type.TIMBER)
	_assert(is_equal_approx(need.units_per_person_daily(Commodity.Type.WOOL), 0.125), "A 4x-dense satisfier needs a quarter of the units")

	var h := HEHousehold.new(1, 2, 0)
	h.add_stock(Commodity.Type.WOOL, 2.0)
	h.add_stock(Commodity.Type.TIMBER, 3.0)
	_assert(is_equal_approx(need.held(h), 11.0), "Held should sum value-weighted stock across satisfiers: got %.2f" % need.held(h))

	var burn := need.burn(h, 10.0)
	_assert(is_equal_approx(burn["provided"], 10.0), "Burning 10 should be fully met")
	_assert(is_equal_approx(burn["burned"].get(Commodity.Type.WOOL, 0.0), 2.0), "The denser satisfier should be spent first")
	_assert(is_equal_approx(burn["burned"].get(Commodity.Type.TIMBER, 0.0), 2.0), "The remainder should come from the next satisfier")
	_assert(is_equal_approx(h.stock(Commodity.Type.TIMBER), 1.0), "Timber should be left with only what was not burned")

	var short := need.burn(h, 5.0)
	_assert(is_equal_approx(short["provided"], 1.0), "A burn beyond what is held supplies only what exists: got %.2f" % short["provided"])
	_assert(is_equal_approx(need.held(h), 0.0), "Everything held should be spent")

	# Cascade: the baseline alone until an alternative is actually on offer,
	# then cheapest per need-unit first (wool 2.0 / 4 = 0.5 vs timber 1.0).
	var sim := _new_sim("build_three_business_economy")
	var settlement_id: int = sim.get_settlement_ids()[0]
	_assert(sim._household_cascade(settlement_id, need) == [Commodity.Type.TIMBER], "With no alternative on offer, only the baseline should be listed")
	var wool_seller: HEBusiness = sim._business_selling(settlement_id, Commodity.Type.WOOL)
	wool_seller.add_stock(Commodity.Type.WOOL, 5.0)
	_assert(sim._household_cascade(settlement_id, need) == [Commodity.Type.WOOL, Commodity.Type.TIMBER],
		"A cheaper-per-unit satisfier on offer should be listed first, with the baseline still behind it")
	print("  burn order, partial burns and cascade order behave as expected")

## Substitution through the real clearing paths, with the Charcoal Burner's
## scenario. Charcoal is cheaper per heat unit than timber, so it is every
## buyer's first choice; these check that when it cannot cover a buyer, the
## buyer still gets heat from timber.
func _check_fuel_fallback() -> void:
	print("\n=== Heat falls back to timber when charcoal cannot cover the need ===")
	var heat: HENeed = HENeeds.get_need(HENeed.Id.HEAT)
	var charcoal := Commodity.Type.CHARCOAL
	var timber := Commodity.Type.TIMBER

	# Households: a sliver of charcoal for sale, ample timber.
	var sim := _new_sim("build_economy_with_charcoal_burner")
	var settlement_id: int = sim.get_settlement_ids()[0]
	var market: HEMarket = sim.markets[settlement_id]
	market.price[charcoal] = 3.0 # 0.75 per heat vs timber's 1.0
	var burner: HEBusiness = sim.businesses[HEScenarioSeeds.CHARCOAL_BURNER_BUSINESS_ID]
	burner.inventory = {charcoal: 2.0}
	var woodlot: HEBusiness = sim.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID]
	woodlot.inventory = {timber: 5000.0}
	for household_id in sim.get_household_ids():
		var h: HEHousehold = sim.households[household_id]
		h.inventory = {}
		h.balance = 1000.0
	_assert(sim._household_cascade(settlement_id, heat) == [charcoal, timber], "Charcoal on offer and cheaper should lead the households' cascade")
	sim._run_market(sim._new_daily_record())
	var worst_gap := 0.0
	var any_unmet := false
	var charcoal_bought := 0.0
	for household_id in sim.get_household_ids():
		var h: HEHousehold = sim.households[household_id]
		var target: float = float(h.headcount()) * heat.per_person_daily * HESimulation.TARGET_BUFFER_DAYS
		worst_gap = maxf(worst_gap, target - heat.held(h))
		charcoal_bought += h.stock(charcoal)
		any_unmet = any_unmet or h.last_unmet_scarcity.get(charcoal, 0.0) > 0.0001 or h.last_unmet_scarcity.get(timber, 0.0) > 0.0001
	print("  households: charcoal sold=%.2f, worst heat shortfall vs buffer=%.4f" % [charcoal_bought, worst_gap])
	_assert(charcoal_bought > 1.99, "The little charcoal for sale should all be sold, got %.2f" % charcoal_bought)
	_assert(worst_gap < EPSILON, "Households should top up the rest of their heat buffer with timber, worst shortfall %.4f" % worst_gap)
	_assert(not any_unmet, "A need covered by the fallback should not be reported as unmet")

	# A preferred good whose seller PACES its sales (a long-cycle business such
	# as the Woodlot) still has most of its stock left after clearing, so having
	# stock is not the same as being available. Fixture need: timber (4 units
	# each, the Woodlot's paced stock) is cheaper per unit than wool (1 unit,
	# the baseline) -- when timber's paced offer can't cover the households,
	# they must top up with wool instead of going without.
	var saved_needs: Array[HENeed] = HENeeds._all
	var fixture_units: Dictionary[Commodity.Type, float] = {timber: 4.0, Commodity.Type.WOOL: 1.0}
	var fixture_needs: Array[HENeed] = [HENeed.new(HENeed.Id.HEAT, "Fixture fuel", 0.5, fixture_units, Commodity.Type.WOOL)]
	HENeeds._all = fixture_needs
	var paced := _new_sim("build_economy_with_charcoal_burner")
	var paced_settlement: int = paced.get_settlement_ids()[0]
	paced.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID].inventory = {timber: 400.0}
	# The wool seller paces its sales too, so give it enough stock that its own
	# paced offer comfortably covers what the timber leaves over.
	paced._business_selling(paced_settlement, Commodity.Type.WOOL).inventory = {Commodity.Type.WOOL: 500000.0}
	var paced_target := 0.0
	for household_id in paced.get_household_ids():
		var h: HEHousehold = paced.households[household_id]
		h.inventory = {}
		h.balance = 1000.0
		paced_target += float(h.headcount()) * fixture_needs[0].per_person_daily * HESimulation.TARGET_BUFFER_DAYS
	var timber_offer: float = paced._household_offer(paced_settlement, timber)
	_assert(timber_offer > 0.0 and timber_offer * 4.0 < paced_target, "Test setup: timber's paced offer (%.2f units) should be unable to cover the households' %.2f heat" % [timber_offer, paced_target])
	_assert(paced._household_cascade(paced_settlement, fixture_needs[0]) == [timber, Commodity.Type.WOOL], "Test setup: timber should lead, wool behind it")
	paced._run_market(paced._new_daily_record())
	var paced_gap := 0.0
	for household_id in paced.get_household_ids():
		var h: HEHousehold = paced.households[household_id]
		paced_gap = maxf(paced_gap, float(h.headcount()) * fixture_needs[0].per_person_daily * HESimulation.TARGET_BUFFER_DAYS - fixture_needs[0].held(h))
	var timber_left: float = paced.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID].stock(timber)
	HENeeds._all = saved_needs
	print("  paced preferred seller: timber left unsold=%.1f, worst heat shortfall vs buffer=%.4f" % [timber_left, paced_gap])
	_assert(timber_left > 1.0, "Test setup: the Woodlot should still hold stock after clearing (it paces its sales)")
	_assert(paced_gap < EPSILON, "Households should top up from the baseline when the preferred seller's paced offer runs short, worst shortfall %.4f" % paced_gap)

	# Bloomery: only a sliver of charcoal exists. There is no household reserve,
	# so the Bloomery may take part of it, but never more than exists, and the
	# rest of its heat must still come from timber.
	var sim2 := _new_sim("build_economy_with_charcoal_burner")
	var settlement_id2: int = sim2.get_settlement_ids()[0]
	(sim2.markets[settlement_id2] as HEMarket).price[charcoal] = 3.0
	var burner2: HEBusiness = sim2.businesses[HEScenarioSeeds.CHARCOAL_BURNER_BUSINESS_ID]
	burner2.inventory = {charcoal: 1.0}
	var bloomery: HEBusiness = sim2.businesses[HEScenarioSeeds.BLOOMERY_BUSINESS_ID]
	bloomery.inventory = {}
	bloomery.balance = 10000.0
	sim2.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID].inventory = {timber: 5000.0}
	# Purchases are proportional across inputs, so the ore side needs stock too.
	sim2.businesses[HEScenarioSeeds.IRON_MINE_BUSINESS_ID].inventory = {Commodity.Type.IRON_ORE: 5000.0}
	sim2._run_input_purchasing(sim2._new_daily_record())
	print("  bloomery: timber bought=%.1f, charcoal bought=%.1f, input fulfilment=%.2f" % [bloomery.stock(timber), bloomery.stock(charcoal), bloomery.last_input_fulfillment_ratio])
	_assert(bloomery.stock(charcoal) <= 1.0001, "A business cannot buy more charcoal than the burner holds, got %.3f" % bloomery.stock(charcoal))
	_assert(bloomery.stock(timber) > 0.0, "The Bloomery should buy timber when the cheaper fuel is unavailable to it")
	_assert(bloomery.last_input_fulfillment_ratio > 0.0, "The Bloomery should not stall for fuel while timber is for sale")

## Government Warehouse: costs 200 from the treasury, employs 2 admin workers
## paid by the treasury, and money stays conserved.
func _check_government_warehouse() -> void:
	print("
=== Government Warehouse: built from the treasury, 2 admin workers ===")
	var sim := _new_sim("build_three_business_economy")
	sim.construction_days = 0 # instant builds; _check_government_construction covers the wait
	var cost := HEScenarioSeeds.WAREHOUSE_BUILD_COST
	_assert(not sim.build_government_building(1, "warehouse"), "Starting treasury is too small to afford a warehouse")
	sim.advance_ticks(1)
	var gov: HEBusiness = sim.businesses[HEScenarioSeeds.GOVERNMENT_BUSINESS_ID]
	gov.balance = cost + 50.0
	var money_before := sim._total_money()
	_assert(sim.build_government_building(1, "warehouse"), "Warehouse should build once the treasury covers it")
	_assert(absf(gov.balance - 50.0) < EPSILON, "Treasury should pay exactly the build cost")
	_assert(absf(money_before - sim._total_money() - cost) < EPSILON, "Building should take exactly the cost out of circulation")
	_assert(absf(sim.get_city_summary()["construction_spend_total"] - cost) < EPSILON, "Construction spend should be booked")
	_assert(not sim.build_government_building(1, "warehouse"), "Only one warehouse per town")
	sim.advance_ticks(14)
	var warehouse_id := -1
	for report in sim.get_business_reports(1):
		if report["kind"] == "warehouse":
			warehouse_id = report["business_id"]
			_assert(report["employed_workers"] >= 1 and report["capacity"] == 2 and report["max_capacity"] == 2, "Warehouse should staff its 2 admin slots (employed %d)" % report["employed_workers"])
			_assert(absf(report["balance"] - gov.balance) < EPSILON, "Warehouse cash should be the treasury's")
	_assert(warehouse_id != -1, "Warehouse should appear in business reports")
	var warehouse: HEBusiness = sim.businesses[warehouse_id]
	_assert(absf(warehouse.balance) < EPSILON, "Warehouse must hold no cash of its own")

	# Buy orders: the treasury pays for goods that land in the warehouse's
	# inventory, within the daily cap, and money is only moved, never made.
	var timber := Commodity.Type.TIMBER
	gov.balance = 500.0
	_assert(sim.set_warehouse_order(warehouse_id, timber, 25.0, false, 0.0), "Warehouse should accept a buy order")
	_assert(not sim.set_warehouse_order(gov.id, timber, 25.0, false, 0.0), "Only a warehouse takes orders")
	sim.advance_ticks(1)
	_assert(warehouse.stock(timber) <= HESimulation.WAREHOUSE_DAILY_TRADE_CAP + EPSILON, "A day's buying is capped (bought %.2f)" % warehouse.stock(timber))
	sim.advance_ticks(20)
	_assert(warehouse.stock(timber) > 0.0, "Buy order should stock the warehouse with timber")
	_assert(warehouse.stock(timber) <= 25.0 + EPSILON, "Buy order should stop at its target (held %.2f)" % warehouse.stock(timber))
	_assert(absf(warehouse.balance) < EPSILON, "Warehouse still has no cash after buying")

	# Sell order: held goods above `keep` are exported through the Trader and
	# the treasury is paid.
	var held := warehouse.stock(timber)
	if held > 0.0:
		_assert(sim.set_warehouse_order(warehouse_id, timber, 0.0, true, 0.0), "Warehouse should accept a sell order")
		sim.advance_ticks(10)
		_assert(warehouse.stock(timber) < held, "Sell order should export held timber (still %.2f of %.2f)" % [warehouse.stock(timber), held])

## Government build costs: farm and woodlot are the free starter tier (built
## through the same path as the warehouse), and a goods cost is drawn from the
## Government Warehouse's stock and blocked while the warehouse can't cover it.
func _check_government_build_costs() -> void:
	print("
=== Government build costs: free farm/woodlot, goods cost from the warehouse ===")
	var sim := _new_sim("build_three_business_economy")
	sim.construction_days = 0 # instant builds; _check_government_construction covers the wait
	var settlement: HESettlement = sim.settlements[1]
	var gov: HEBusiness = sim.businesses[HEScenarioSeeds.GOVERNMENT_BUSINESS_ID]
	for type_key in ["farm", "woodlot"]:
		_assert(sim.has_business_of_type(1, type_key), "Seeded town starts with a %s" % type_key)
		_assert(sim.build_government_building(1, type_key) == false, "A second %s is refused (unique per town)" % type_key)
		for business_id in sim.businesses.keys():
			if (sim.businesses[business_id] as HEBusiness).type_key == type_key:
				sim.businesses.erase(business_id)
				settlement.business_ids.erase(business_id)
				break
		var treasury_before := gov.balance
		_assert(sim.build_government_building(1, type_key), "%s should build through the Government for free" % type_key)
		_assert(absf(gov.balance - treasury_before) < EPSILON, "A free %s must not touch the treasury" % type_key)
		_assert(sim.has_business_of_type(1, type_key), "The new %s should exist" % type_key)

	# Goods cost: no warehouse -> blocked; warehouse without stock -> blocked;
	# stocked warehouse -> builds and the goods are consumed.
	var timber := Commodity.Type.TIMBER
	var option := {"type_key": "test_hall", "cost": HEScenarioSeeds.build_cost(0.0, {timber: 5.0})}
	_assert(sim.government_build_blocker(1, option).contains("warehouse"), "Goods cost needs a warehouse")
	gov.balance = HEScenarioSeeds.WAREHOUSE_BUILD_COST + 50.0
	_assert(sim.build_government_building(1, "warehouse"), "Warehouse builds")
	var warehouse := sim._government_warehouse(1)
	_assert(sim.government_build_blocker(1, option).contains("has 0"), "Empty warehouse can't cover the goods cost")
	warehouse.add_stock(timber, 8.0)
	_assert(sim.government_build_blocker(1, option) == "", "Stocked warehouse covers the goods cost")
	_assert(HEScenarioSeeds.cost_text(option["cost"]) == "5 Timber" or HEScenarioSeeds.cost_text(option["cost"]).contains("5"), "cost_text lists goods")

## Housing: houses are buildings, not businesses. A house is built by the
## government for gold from the treasury plus timber from the warehouse (so it
## needs a warehouse), is repeatable, shelters one household, and a full town
## cuts births while homeless households shed members.
func _check_housing() -> void:
	print("\n=== Housing: government-built houses, saturation, homelessness ===")
	var sim := _new_sim("build_three_business_economy")
	sim.construction_days = 0 # instant builds; _check_government_construction covers the wait
	var seeded: Dictionary = sim.get_housing_report(1)
	_assert(seeded["modeled"], "The seeded town models housing")
	_assert(seeded["capacity"] >= seeded["households"], "Seeded housing covers the starting households (%d for %d)" % [seeded["capacity"], seeded["households"]])
	_assert(not seeded["saturated"] and seeded["homeless_households"] == 0, "A freshly seeded town has a free house")
	for builder in ["build_three_business_economy_with_bloomery", "build_economy_with_bloomery_and_iron_mine", "build_economy_with_charcoal_burner", "build_lopsided_start"]:
		var other := _new_sim(builder)
		_assert(other.get_housing_report(1)["capacity"] >= other.get_housing_report(1)["households"], "%s seeds enough housing" % builder)
	var custom := HESimulation.new(SEED, func(rng): return HEFixtures.build_custom(rng, [HEScenarioSeeds.FARM_BUSINESS_ID]), true)
	_assert(custom.get_housing_report(1)["capacity"] >= custom.get_housing_report(1)["households"], "Custom roster seeds enough housing")

	var house_option: Dictionary = {}
	for option in HEScenarioSeeds.government_buildings():
		if option["type_key"] == "house":
			house_option = option
	_assert(not house_option.is_empty(), "The government can build houses")
	_assert(is_equal_approx(house_option["cost"]["gold"], 15.0) and is_equal_approx(house_option["cost"]["goods"][Commodity.Type.TIMBER], 50.0), "A house costs 15 gold + 50 timber")
	var gov: HEBusiness = sim.businesses[HEScenarioSeeds.GOVERNMENT_BUSINESS_ID]
	gov.balance = HEScenarioSeeds.WAREHOUSE_BUILD_COST + 500.0
	_assert(sim.government_build_blocker(1, house_option) == "needs a government warehouse", "No warehouse: house is blocked on the warehouse (got '%s')" % sim.government_build_blocker(1, house_option))
	_assert(not sim.build_government_building(1, "house"), "A house cannot be built without a warehouse")

	_assert(sim.build_government_building(1, "warehouse"), "Warehouse builds")
	var warehouse := sim._government_warehouse(1)
	_assert(sim.government_build_blocker(1, house_option).contains("has 0"), "Empty warehouse can't supply the timber")
	_assert(sim.build_goods_order_state(1, house_option) == "can_order", "Short of timber with a warehouse: the build can order it")
	_assert(sim.request_government_build(1, "house") == "ordered", "Pressing build orders the missing timber")
	var timber_order: Dictionary = warehouse.warehouse_orders.get(Commodity.Type.TIMBER, {})
	_assert(is_equal_approx(float(timber_order.get("buy_up_to", 0.0)), 50.0), "The standing order targets the house's timber cost")
	_assert(sim.build_goods_order_state(1, house_option) == "ordered", "With the order standing, the state is ordered")
	_assert(sim.request_government_build(1, "house") == "", "Pressing again before the goods arrive does nothing")
	sim.advance_ticks(10)
	_assert(warehouse.stock(Commodity.Type.TIMBER) >= 50.0 - EPSILON, "The order stocks the warehouse with timber (has %.1f)" % warehouse.stock(Commodity.Type.TIMBER))
	var timber_before := warehouse.stock(Commodity.Type.TIMBER)
	var houses_before: int = sim.get_housing_report(1)["houses"]
	var treasury_before := gov.balance
	_assert(sim.build_government_building(1, "house"), "House builds from treasury gold + warehouse timber")
	_assert(sim.get_housing_report(1)["houses"] == houses_before + 1, "A house was added")
	_assert(absf(treasury_before - gov.balance - 15.0) < EPSILON, "The house cost 15 gold")
	_assert(absf(timber_before - warehouse.stock(Commodity.Type.TIMBER) - 50.0) < EPSILON, "The house consumed 50 timber from the warehouse")
	warehouse.add_stock(Commodity.Type.TIMBER, 60.0)
	_assert(sim.build_government_building(1, "house"), "Houses are repeatable")
	_assert(sim.businesses.size() == sim.businesses.keys().size() and not sim.has_business_of_type(1, "house"), "Houses are not businesses")

	# Tenement: upgrades the innermost plain house in place (+3 capacity, no new
	# lot); only builds a new dense house once every house is already dense.
	var before: Dictionary = sim.get_housing_report(1)
	var innermost: int = (sim.settlements[1] as HESettlement).dwelling_ids.min()
	warehouse.add_stock(Commodity.Type.TIMBER, 400.0)
	warehouse.add_stock(Commodity.Type.STONE, 400.0)
	var tenement_option: Dictionary = {}
	for option in HEScenarioSeeds.government_buildings():
		if option["type_key"] == "tenement":
			tenement_option = option
	var upgrade_gold: float = float(sim.build_cost_for(1, tenement_option)["gold"])
	_assert(is_equal_approx(upgrade_gold, HEScenarioSeeds.TENEMENT_UPGRADE_GOLD), "While a house can be upgraded the upgrade price applies")
	_assert(upgrade_gold > float(house_option["cost"]["gold"]) * 3.0 - EPSILON, "An upgrade (+3 households) costs at least three houses of gold")
	var gold_before_upgrade := gov.balance
	_assert(sim.build_government_building(1, "tenement"), "A tenement builds from treasury gold + warehouse timber")
	_assert(absf(gold_before_upgrade - gov.balance - upgrade_gold) < EPSILON, "The upgrade charged the upgrade price")
	var after: Dictionary = sim.get_housing_report(1)
	_assert(after["houses"] == before["houses"], "A tenement upgrades a house instead of adding a lot")
	_assert(after["capacity"] == before["capacity"] + 3, "An upgrade adds three households of capacity")
	_assert(sim.dwellings[innermost].type_key == "tenement", "The innermost house was the one upgraded")
	_assert(after["upgradable_houses"] == before["upgradable_houses"] - 1, "One fewer plain house to upgrade")
	for dwelling_id in (sim.settlements[1] as HESettlement).dwelling_ids:
		sim.dwellings[dwelling_id].upgrade_to_dense()
	var dense_houses: int = sim.get_housing_report(1)["houses"]
	warehouse.add_stock(Commodity.Type.TIMBER, 400.0)
	warehouse.add_stock(Commodity.Type.STONE, 400.0)
	_assert(is_equal_approx(float(sim.build_cost_for(1, tenement_option)["gold"]), HEScenarioSeeds.TENEMENT_BUILD_GOLD), "With nothing to upgrade the new-build price applies")
	_assert(sim.build_government_building(1, "tenement"), "With no plain house left a tenement is built new")
	_assert(sim.get_housing_report(1)["houses"] == dense_houses + 1, "...as an added lot")

	# Saturation: drop all houses -> every household homeless, births scaled
	# down and members shed. Compare against an identical town with housing.
	var housed := _new_sim("build_three_business_economy")
	var evicted := _new_sim("build_three_business_economy")
	var evicted_settlement: HESettlement = evicted.settlements[1]
	evicted.dwellings.clear()
	evicted_settlement.dwelling_ids.clear()
	var report: Dictionary = evicted.get_housing_report(1)
	_assert(report["saturated"] and report["homeless_households"] == report["households"], "Without houses the whole town is homeless")
	_assert(evicted.get_household_summary(evicted.get_household_ids()[0])["housing_status"] == "homeless", "An evicted household reports homeless")
	_assert(housed.get_household_summary(housed.get_household_ids()[0])["housing_status"] == "housed", "A housed household reports housed")
	var pop_start: int = housed.get_city_summary()["population"]
	housed.advance_ticks(720)
	evicted.advance_ticks(720)
	var housed_summary: Dictionary = housed.get_city_summary()
	var evicted_summary: Dictionary = evicted.get_city_summary()
	print("  population %d -> housed %d, homeless %d; emigrations %d vs %d; births %d vs %d" % [pop_start, housed_summary["population"], evicted_summary["population"], housed_summary["emigrations_total"], evicted_summary["emigrations_total"], housed_summary["births_total"], evicted_summary["births_total"]])
	_assert(evicted_summary["emigrations_total"] > housed_summary["emigrations_total"], "Homeless households emigrate far more")
	_assert(evicted_summary["population"] < housed_summary["population"], "A homeless town ends smaller than a housed one")

## Construction: a government build is paid for when ordered, stands as a
## foundation (a construction report the town layout seats on its final site)
## for CONSTRUCTION_DAYS, then opens with the same id on the same site.
func _check_government_construction() -> void:
	print("\n=== Government construction: foundation first, building after %d days ===" % HESimulation.CONSTRUCTION_DAYS)
	var sim := _new_sim("build_three_business_economy")
	var gov: HEBusiness = sim.businesses[HEScenarioSeeds.GOVERNMENT_BUSINESS_ID]
	gov.balance = HEScenarioSeeds.WAREHOUSE_BUILD_COST + 500.0
	var layout := HETownLayout.new("construction", 1, sim.get_business_reports(), sim.get_dwelling_reports())
	var treasury_before := gov.balance
	_assert(sim.build_government_building(1, "warehouse"), "Warehouse construction starts")
	_assert(absf(treasury_before - gov.balance - HEScenarioSeeds.WAREHOUSE_BUILD_COST) < EPSILON, "The cost is paid when construction starts")
	_assert(sim._government_warehouse(1) == null, "The warehouse is not open while under construction")
	_assert(not sim.build_government_building(1, "warehouse"), "A second warehouse is refused while one is under construction")
	_assert(sim.government_build_blocker(1, {"type_key": "warehouse", "cost": HEScenarioSeeds.build_cost()}) == "under construction", "The blocker says under construction")
	var constructions := sim.get_construction_reports(1)
	_assert(constructions.size() == 1 and int(constructions[0]["days_left"]) == HESimulation.CONSTRUCTION_DAYS, "One construction report, %d days left" % HESimulation.CONSTRUCTION_DAYS)
	var warehouse_id := int(constructions[0]["business_id"])
	_assert(warehouse_id == sim.next_business_id() - 1, "The construction reserves its business id")
	layout.reconcile(sim.get_business_reports(), sim.get_dwelling_reports(), constructions)
	var site := layout.site_of_business(warehouse_id)
	_assert(not site.is_empty() and site["under_construction"], "The layout seats the foundation on a site")
	for i in HESimulation.CONSTRUCTION_DAYS - 1:
		sim.advance_ticks(1)
		_assert(sim._government_warehouse(1) == null, "Still a foundation on day %d" % sim.day)
	sim.advance_ticks(1)
	_assert(sim._government_warehouse(1) != null and sim._government_warehouse(1).id == warehouse_id, "The warehouse opens after %d days with its reserved id" % HESimulation.CONSTRUCTION_DAYS)
	_assert(sim.get_construction_reports(1).is_empty(), "No construction left")
	layout.reconcile(sim.get_business_reports(), sim.get_dwelling_reports(), sim.get_construction_reports())
	var built_site := layout.site_of_business(warehouse_id)
	_assert(built_site.get("site_id", -1) == site["site_id"] and not built_site["under_construction"], "The building opens on its foundation's site")

	# A house: foundation on a housing lot, then the house; two queued tenement
	# upgrades never target the same house.
	var warehouse := sim._government_warehouse(1)
	warehouse.add_stock(Commodity.Type.TIMBER, 1000.0)
	warehouse.add_stock(Commodity.Type.STONE, 1000.0)
	gov.balance = 5000.0
	var houses_before: int = sim.get_housing_report(1)["houses"]
	_assert(sim.build_government_building(1, "house"), "House construction starts")
	_assert(sim.get_housing_report(1)["houses"] == houses_before, "No house until construction finishes")
	var house_construction: Dictionary = sim.get_construction_reports(1)[0]
	layout.reconcile(sim.get_business_reports(), sim.get_dwelling_reports(), sim.get_construction_reports())
	var lot := layout.site_of_dwelling(int(house_construction["dwelling_id"]))
	_assert(not lot.is_empty() and lot["under_construction"], "The house foundation takes a lot")
	_assert(sim.build_government_building(1, "tenement") and sim.build_government_building(1, "tenement"), "Two tenement upgrades start")
	var targets: Array = []
	for report in sim.get_construction_reports(1):
		if int(report["upgrade_dwelling_id"]) != -1:
			targets.append(int(report["upgrade_dwelling_id"]))
	_assert(targets.size() == 2 and targets[0] != targets[1], "Queued upgrades target different houses (%s)" % str(targets))
	sim.advance_ticks(HESimulation.CONSTRUCTION_DAYS)
	_assert(sim.get_housing_report(1)["houses"] == houses_before + 1, "The house opens after construction")
	for dwelling_id in targets:
		_assert(sim.dwellings[dwelling_id].is_dense(), "House %d was upgraded" % dwelling_id)
	layout.reconcile(sim.get_business_reports(), sim.get_dwelling_reports(), sim.get_construction_reports())
	var house_site := layout.site_of_dwelling(int(house_construction["dwelling_id"]))
	_assert(house_site.get("site_id", -1) == lot["site_id"] and not house_site["under_construction"], "The house stands on its foundation's lot")

## Government + sales tax: every domestic sale remits a slice to the town
## treasury, which pays one permanent administrator and never overdrafts.
## Sweeps the tax rate so the printout answers "is a sales tax alone enough,
## or do we also need a resident/property tax?" -- see HESimulation.SALES_TAX_RATE.
func _check_government_taxes() -> void:
	print("\n=== Government: sales tax funds a permanent administrator ===")
	var gov_id := HEScenarioSeeds.GOVERNMENT_BUSINESS_ID
	var sim := _new_sim("build_three_business_economy")
	var summary := sim.get_government_summary(1)
	_assert(not summary.is_empty(), "Seeded town should have a government")
	_assert((summary["administrator_household_ids"] as Array).size() == 1, "Government should start with exactly one administrator household")
	_assert(summary["builder_slots"] == 0, "Builder jobs are a stub: no slots yet")

	var days := 730
	var worst_treasury := INF
	var late_shortfall_days := 0
	var capacity_start := 0
	for report in sim.get_business_reports():
		if report["business_id"] == gov_id:
			capacity_start = report["capacity"]
			_assert(report["kind"] == "government", "Government report should be kind=government")
	var wage_total := 0.0
	for d in days:
		sim.advance_ticks(1)
		worst_treasury = minf(worst_treasury, sim.get_government_summary(1)["treasury"])
		for report in sim.get_business_reports(1):
			if report["business_id"] != gov_id:
				continue
			wage_total += report["last_wages_paid"]
			if d >= 30 and report["wage_shortfall"] > EPSILON:
				late_shortfall_days += 1
	summary = sim.get_government_summary(1)
	# Wages follow prices, which swing with the seasons, so the wage a single
	# day shows says little: compare the income to the wage averaged over the run.
	var wage_per_day: float = wage_total / float(days)
	for report in sim.get_business_reports(1):
		if report["business_id"] == gov_id:
			_assert(report["capacity"] == capacity_start, "Government capacity must not self-tune")
	print("  default rate %.0f%%: tax collected=%.1f (%.2f/day) vs administrator wage %.2f/day, treasury=%.1f, wage-shortfall days after day 30: %d" % [sim.sales_tax_rate * 100.0, summary["tax_collected_total"], summary["tax_collected_total"] / days, wage_per_day, summary["treasury"], late_shortfall_days])
	_assert(summary["tax_collected_total"] > 0.0, "Sales tax should collect something")
	_assert(worst_treasury >= -EPSILON, "Treasury must never overdraft (worst %.4f)" % worst_treasury)
	_assert(late_shortfall_days == 0, "Sales tax alone should sustain the administrator's wage after the first month (%d short days)" % late_shortfall_days)
	_assert(summary["tax_collected_total"] / days >= wage_per_day, "Average tax income should cover the administrator's daily wage")

	# Tax is a transfer: same-day money reconciliation must still hold with it on.
	var worst_money_gap := 0.0
	for record in sim.get_daily_history(days):
		var expected: float = record["opening_money"] - float(record["money_written_off"]) + float(record["export_revenue"]) - float(record["import_cost"])
		worst_money_gap = maxf(worst_money_gap, absf(record["closing_money"] - expected))
	_assert(worst_money_gap < EPSILON, "Money did not reconcile with sales tax on, worst gap %.4f" % worst_money_gap)

	# Rate sweep (information + a monotonicity guard).
	var previous_tax := -1.0
	for rate in [0.0, 0.03, 0.05, 0.08]:
		var swept := _new_sim("build_three_business_economy")
		swept.sales_tax_rate = rate
		swept.advance_ticks(365)
		var s := swept.get_government_summary(1)
		print("  rate %.0f%%: year-1 tax=%.1f treasury=%.1f" % [rate * 100.0, s["tax_collected_total"], s["treasury"]])
		if rate == 0.0:
			_assert(s["tax_collected_total"] == 0.0, "Rate 0 must collect nothing")
		_assert(s["tax_collected_total"] >= previous_tax, "A higher rate should not collect less tax")
		previous_tax = s["tax_collected_total"]

	# The post is permanent: lose the administrator and the next weekly
	# reconcile fills it again.
	var staffed := _new_sim("build_three_business_economy")
	var admin_id: int = (staffed.get_government_summary(1)["administrator_household_ids"] as Array)[0]
	staffed.households[admin_id].employer_business_id = -1
	staffed.advance_ticks(HESimulation.CAPACITY_EVAL_INTERVAL_DAYS)
	_assert((staffed.get_government_summary(1)["administrator_household_ids"] as Array).size() >= 1, "Administrator post should be refilled after the holder leaves")

	# Top-line treasury summary: matches the government's balance, and its
	# 30-day change equals balance now minus the closing balance 30 days ago.
	var trend := sim.get_treasury_summary(30)
	_assert(trend["has_government"] and absf(trend["treasury"] - summary["treasury"]) < EPSILON, "Treasury summary should match the government balance")
	_assert(trend["days_covered"] == 30, "A two-year-old sim should cover the full 30-day window")
	var gov_history: Array[float] = []
	for report in sim.get_business_reports(1):
		if report["business_id"] == gov_id:
			gov_history.assign(report["balance_history"])
	_assert(absf(trend["change"] - (summary["treasury"] - gov_history[gov_history.size() - 31])) < EPSILON, "30-day treasury change should be now minus the balance 30 days ago")
	var young := _new_sim("build_three_business_economy")
	young.advance_ticks(5)
	_assert(young.get_treasury_summary(30)["days_covered"] == 4, "A young sim should report only the history it has")
	print("  top-line treasury: %.1f gold, %+.1f over %d days" % [trend["treasury"], trend["change"], trend["days_covered"]])

	# A town with no government taxes nothing and reports none.
	var bare := _new_sim("build_two_settlement_economy")
	bare.advance_ticks(60)
	_assert(bare.get_government_summary(1).is_empty(), "A scenario without a government should report none")
	_assert(not bare.get_treasury_summary(30)["has_government"], "No government: the top-line treasury should be hidden")

func _total_worker_capacity(sim: HESimulation) -> int:
	var total := 0
	for household_id in sim.get_household_ids():
		total += sim.get_household_summary(household_id)["worker_capacity"]
	return total

# ---------------------------------------------------------------------------
# Seasons
# ---------------------------------------------------------------------------

## A herd business of `species` in `sim`.
func _herd_of(sim: HESimulation, species: HEBusiness.Species) -> HEBusiness:
	for business in sim.businesses.values():
		var b: HEBusiness = business
		if b.kind == HEBusiness.Kind.HERD and b.species == species:
			return b
	return null

func _check_season_calendar() -> void:
	print("\n=== Seasons: four 90-day seasons, a 360-day year, visible in the clock ===")
	var expected := {0: 0, 89: 0, 90: 1, 179: 1, 180: 2, 269: 2, 270: 3, 359: 3, 360: 0, 449: 0, 450: 1, 1079: 3}
	for d in expected.keys():
		_assert(HESimulation.season_of_day(d) == expected[d], "Day %d should be in season %d, got %d" % [d, expected[d], HESimulation.season_of_day(d)])
	_assert(HESimulation.DAYS_PER_YEAR == 360, "A year should be four 90-day seasons")
	_assert(HESimulation.HERD_EVAL_INTERVAL_DAYS == HESimulation.DAYS_PER_SEASON, "Herd reviews should close exactly one season each")

	var valley := {
		Commodity.Type.GRAIN: [0.8, 1.0, 1.6, 0.1],
		Commodity.Type.TIMBER: [1.0, 1.0, 1.0, 0.6],
		Commodity.Type.WOOL: [1.5, 1.5, 0.5, 0.2],
	}
	for commodity in valley.keys():
		for season in 4:
			var got := HESimulation.seasonal_output_modifier(commodity, season * HESimulation.DAYS_PER_SEASON)
			_assert(absf(got - valley[commodity][season]) < 0.0001, "%s modifier for season %d should match the valley seed (%.2f), got %.2f" % [Commodity.name_of(commodity), season, valley[commodity][season], got])
	_assert(HESimulation.seasonal_output_modifier(Commodity.Type.IRON, 270) == 1.0, "A good without a seasonal curve should not be scaled")
	_assert(HESimulation.seasonal_yield_scale(Commodity.Type.IRON, 270) == 1.0, "A good without a seasonal curve should not be rescaled")
	# The export carry looks ahead: heavy through autumn (winter is next), light
	# in spring and summer, and gone for a good with no curve.
	var grain := Commodity.Type.GRAIN
	var carry_autumn := HESimulation.seasonal_carry_days(grain, 180)
	var carry_summer := HESimulation.seasonal_carry_days(grain, 90)
	var carry_spring := HESimulation.seasonal_carry_days(grain, 0)
	_assert(carry_autumn > 70.0 and carry_autumn < 100.0, "Grain should carry ~80 days of use into winter from autumn, got %.1f" % carry_autumn)
	_assert(carry_summer < 1.0 and carry_spring < 10.0, "Spring and summer should hold back almost nothing (got %.1f, %.1f)" % [carry_spring, carry_summer])
	_assert(HESimulation.seasonal_carry_days(Commodity.Type.IRON, 180) == 0.0, "A good without a curve carries nothing")
	# What a harvest is scaled by is the curve over its own yearly mean, so a
	# year's four seasons average 1.0 and annual output is the unseasonal model's.
	for commodity in valley.keys():
		var yearly := 0.0
		for season in 4:
			yearly += HESimulation.seasonal_yield_scale(commodity, season * HESimulation.DAYS_PER_SEASON)
		_assert(absf(yearly / 4.0 - 1.0) < 0.0001, "%s seasonal yield scales should average 1.0 over a year, got %.4f" % [Commodity.name_of(commodity), yearly / 4.0])

	var sim := _new_sim("build_three_business_economy")
	var seen: Array[String] = []
	for i in 5:
		var clock := sim.get_clock_summary()
		seen.append(clock["season_name"])
		_assert(clock["season_name"] == HESimulation.SEASON_NAMES[clock["season"]], "Clock season name should match its index")
		_assert(clock["day_of_season"] == clock["day"] % 90, "Clock day_of_season should be the day within the season")
		sim.advance_ticks(90)
	print("  seasons at each 90-day mark: %s" % ", ".join(seen))
	_assert(seen == ["Spring", "Summer", "Autumn", "Winter", "Spring"], "A run should walk Spring, Summer, Autumn, Winter, Spring")
	_assert(sim.get_clock_summary()["year"] == 1, "Day 450 should be in year 1 (0-based)")

## Field harvests and shearing scale by the season they land in, and only
## that: a fully-labored field yields area * yield * modifier.
func _check_seasonal_production() -> void:
	print("\n=== Seasons: harvests and wool differ by season ===")
	var sim := _new_sim("build_three_business_economy")
	var farm: HEBusiness = sim.businesses[HEScenarioSeeds.FARM_BUSINESS_ID]
	var woodlot: HEBusiness = sim.businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID]
	var cases := [[farm, Commodity.Type.GRAIN], [woodlot, Commodity.Type.TIMBER]]
	for case in cases:
		var b: HEBusiness = case[0]
		var commodity: Commodity.Type = case[1]
		var per_season: Array[String] = []
		for season in 4:
			# One field ripe and fully labored, the rest far from harvest.
			for f in b.fields:
				f.days_growing = 0
				f.labor_applied = 0.0
			var field: HEField = b.fields[0]
			field.days_growing = b.growth_days - 1
			field.labor_applied = field.area * b.labor_per_area_per_day * b.growth_days
			sim.day = season * HESimulation.DAYS_PER_SEASON + 45
			var stock_before := b.stock(commodity)
			var record := {"produced": {}}
			sim._run_field_growth(b, record)
			var harvested := b.stock(commodity) - stock_before
			var full := field.area * b.yield_per_area
			var modifier := HESimulation.seasonal_yield_scale(commodity, sim.day)
			per_season.append("%.0f" % harvested)
			_assert(absf(harvested - full * modifier) < 0.01,
				"%s harvest in %s should be %.1f x the full yield %.1f, got %.1f" % [b.name, HESimulation.SEASON_NAMES[season], modifier, full, harvested])
			_assert(absf(float(record["produced"][Commodity.name_of(commodity)]) - harvested) < 0.01, "%s harvest should be recorded as produced exactly once" % b.name)
		print("  %s harvest by season (spring..winter): %s" % [b.name, ", ".join(per_season)])

	# Wool lands at the review closing the season: a sheep farm's clip differs
	# by season for the same herd and care.
	var clips: Array[float] = []
	for season in 4:
		var wool_sim := _new_sim("build_three_business_economy")
		var sheep := _herd_of(wool_sim, HEBusiness.Species.SHEEP)
		sheep.add_stock(Commodity.Type.GRAIN, sheep.herd_size * HESimulation.FODDER_PER_HEAD_PER_WINTER[sheep.species])
		wool_sim.day = season * HESimulation.DAYS_PER_SEASON + HESimulation.DAYS_PER_SEASON - 1
		var record := wool_sim._new_daily_record()
		var wool_before := sheep.stock(Commodity.Type.WOOL)
		wool_sim._run_herds(record)
		clips.append(sheep.stock(Commodity.Type.WOOL) - wool_before)
		_assert(absf(sheep.last_wool_produced - clips[season]) < 0.0001, "Sheep wool report should equal the wool added to inventory")
	var clip_text: Array[String] = []
	for clip in clips:
		clip_text.append("%.1f" % clip)
	print("  sheep wool by review season (spring..winter): %s" % ", ".join(clip_text))
	_assert(clips[0] > clips[2] and clips[2] > clips[3], "Wool should be heaviest in spring/summer and lightest in winter")
	_assert(absf(clips[0] / clips[1] - 1.0) < 0.1, "Spring and summer clips should be comparable (same modifier, similar herd)")

## Winter reviews eat the herd's own grain; the share of the need covered sets
## that winter's mortality.
func _check_winter_fodder_and_herd_outcomes() -> void:
	print("\n=== Seasons: winter fodder is consumed and underfed herds lose more ===")
	var rows: Array[String] = []
	for species in [HEBusiness.Species.CATTLE, HEBusiness.Species.SHEEP]:
		var outcomes: Array[float] = []
		var deaths_fed := 0.0
		for cover in [1.0, 0.5, 0.0]:
			var sim := _new_sim("build_three_business_economy")
			var b: HEBusiness = _herd_of(sim, species)
			var head: float = b.herd_size
			var need: float = head * HESimulation.FODDER_PER_HEAD_PER_WINTER[species]
			b.inventory[Commodity.Type.GRAIN] = need * cover
			b.care_worker_days = 0.0
			sim.day = 4 * HESimulation.DAYS_PER_SEASON - 1
			var record := sim._new_daily_record()
			var grain_before: float = sim._total_stock_snapshot()["Grain"]
			sim._run_herds(record)
			var grain_after: float = sim._total_stock_snapshot()["Grain"]
			var eaten: float = need * cover
			_assert(absf(b.stock(Commodity.Type.GRAIN)) < 0.0001, "A winter review should eat all the fodder it can (left %.2f)" % b.stock(Commodity.Type.GRAIN))
			_assert(absf((grain_before - grain_after) - eaten) < 0.01, "Grain removed from the world should equal the fodder eaten (%.2f vs %.2f)" % [grain_before - grain_after, eaten])
			_assert(absf(float(record["consumed"].get("Grain", 0.0)) - eaten) < 0.01, "Fodder should be recorded as consumed grain")
			_assert(absf(b.last_fodder_eaten - eaten) < 0.01 and absf(b.last_fodder_needed - need) < 0.01, "The herd should report its winter fodder need and intake")
			_assert(b.last_review_season == HESimulation.Season.WINTER, "The review should record that it closed winter")
			var birth_event: Dictionary = {}
			for herd_event in b.herd_events: # a dynamic cull may log after the birth
				if herd_event["type"] == "herd_birth":
					birth_event = herd_event
			var born: float = birth_event["born"]
			_assert(born > 0.0, "Births are a flat per-review rate, so winter reviews still add young (got %.2f)" % born)
			outcomes.append(b.herd_size / head)
			if cover == 1.0:
				deaths_fed = birth_event["died"]
		rows.append("%s herd retained: fed %.3f, half-fed %.3f, unfed %.3f" % [("Cattle" if species == HEBusiness.Species.CATTLE else "Sheep"), outcomes[0], outcomes[1], outcomes[2]])
		_assert(outcomes[0] > outcomes[1] and outcomes[1] > outcomes[2], "Less winter fodder should mean a smaller surviving herd (%s)" % rows.back())
		_assert(deaths_fed > 0.0, "Even a fed herd should lose its baseline mortality in winter")
	for row in rows:
		print("  " + row)

	# A non-winter review grows the herd and eats nothing.
	var spring_sim := _new_sim("build_three_business_economy")
	var cattle := _herd_of(spring_sim, HEBusiness.Species.CATTLE)
	cattle.inventory[Commodity.Type.GRAIN] = 50.0
	cattle.care_worker_days = 0.0
	var head_before := cattle.herd_size
	spring_sim.day = HESimulation.DAYS_PER_SEASON - 1
	spring_sim._run_herds(spring_sim._new_daily_record())
	_assert(cattle.herd_size > head_before, "A spring review should grow a fed herd")
	_assert(absf(cattle.stock(Commodity.Type.GRAIN) - 50.0) < 0.0001, "Only winter reviews eat fodder")
	_assert(cattle.last_fodder_needed == 0.0, "Fodder need should read zero outside winter")

	# Over a real run, ranches buy their fodder in autumn and eat it at winter.
	var run := _new_sim("build_three_business_economy")
	var bought := 0.0
	var eaten_total := 0.0
	var bought_outside := 0.0
	var ranch_ids: Array[int] = []
	for business in run.businesses.values():
		if (business as HEBusiness).kind == HEBusiness.Kind.HERD:
			ranch_ids.append((business as HEBusiness).id)
	for d in 2 * HESimulation.DAYS_PER_YEAR:
		var season := HESimulation.season_of_day(run.day)
		run.advance_ticks(1)
		for id in ranch_ids:
			if run.businesses.has(id):
				var flows: Dictionary = (run.businesses[id] as HEBusiness).todays_flows
				var got := float((flows.get(HEBusiness.FLOW_BOUGHT, {}) as Dictionary).get(Commodity.Type.GRAIN, 0.0))
				bought += got
				if season < HESimulation.Season.AUTUMN:
					bought_outside += got
				eaten_total += float((flows.get(HEBusiness.FLOW_CONSUMED, {}) as Dictionary).get(Commodity.Type.GRAIN, 0.0))
	print("  two years: ranches bought %.0f grain, ate %.0f at winter reviews" % [bought, eaten_total])
	_assert(bought > 0.0, "Ranches should buy winter fodder in the autumn")
	_assert(bought_outside < 0.0001, "Ranches should not buy fodder before autumn (%.1f bought)" % bought_outside)
	_assert(eaten_total > 0.0, "Ranches should eat their fodder at winter reviews")
	_assert(eaten_total <= bought + 0.01, "Ranches cannot eat more fodder than they bought (they start with none)")

## Over several years every unit of goods and money still reconciles, nothing
## goes wrong at the season boundaries, and the economy keeps going through
## the winters.
func _check_seasons_conserve_and_stay_viable() -> void:
	print("\n=== Seasons: stock and money conserve, and the economy survives several winters ===")
	var sim := _new_sim("build_three_business_economy")
	var start_population := sim._total_population()
	var reconciled := HESimulation.SUBSISTENCE_COMMODITIES.duplicate()
	reconciled.append_array(HESimulation.LIVESTOCK_GOODS)
	var worst_stock := 0.0
	var worst_money := 0.0
	var min_grain := INF
	var settled_min_grain := INF # years 3+, once the first winters have set the town's carry
	var good_years := 0
	var years := 5
	for year in years:
		sim.advance_ticks(HESimulation.DAYS_PER_YEAR)
		for record in sim.get_daily_history(HESimulation.DAYS_PER_YEAR):
			for c in reconciled:
				var name := Commodity.name_of(c)
				var expected: float = record["opening_stock"][name] + record["produced"].get(name, 0.0) - record["consumed"].get(name, 0.0) \
					- (record["exported"] as Dictionary).get(name, 0.0) - (record["goods_written_off"] as Dictionary).get(c, 0.0)
				worst_stock = maxf(worst_stock, absf(record["closing_stock"][name] - expected))
			var expected_money: float = record["opening_money"] - float(record["money_written_off"]) + float(record["export_revenue"]) - float(record["import_cost"])
			worst_money = maxf(worst_money, absf(record["closing_money"] - expected_money))
			min_grain = minf(min_grain, record["closing_stock"]["Grain"])
			if year >= 2:
				settled_min_grain = minf(settled_min_grain, record["closing_stock"]["Grain"])
		var herds_alive := 0
		for business in sim.businesses.values():
			if (business as HEBusiness).kind == HEBusiness.Kind.HERD and (business as HEBusiness).herd_size > 0.0:
				herds_alive += 1
		print("  year %d: population %d (start %d), unemployed households %d, herds alive %d, minimum town grain so far %.0f" % [year + 1, sim._total_population(), start_population, sim._unemployed_household_count(), herds_alive, min_grain])
		if sim._total_population() > 0 and herds_alive == 2:
			good_years += 1
	print("  worst stock gap %.4f, worst money gap %.4f over %d years" % [worst_stock, worst_money, years])
	_assert(settled_min_grain > 0.0, "The town should carry grain through every winter from year 3 on, but ran out (minimum %.1f)" % settled_min_grain)
	_assert(worst_stock < EPSILON, "Seasonal stock did not reconcile, worst gap %.4f" % worst_stock)
	_assert(worst_money < EPSILON, "Seasonal money did not reconcile, worst gap %.4f" % worst_money)
	_assert(good_years == years, "Population and both herds should survive every one of %d years (%d did)" % [years, good_years])
	_assert(sim._total_population() >= start_population / 2, "Population should not collapse across seasons (%d from %d)" % [sim._total_population(), start_population])
	for business_id in [HEScenarioSeeds.FARM_BUSINESS_ID, HEScenarioSeeds.WOODLOT_BUSINESS_ID]:
		_assert(sim.businesses.has(business_id), "Farm and Woodlot should still be trading after %d years" % years)
