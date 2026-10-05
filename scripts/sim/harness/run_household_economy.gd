extends SceneTree

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")
const HEMarket = preload("res://scripts/sim/household_economy/records/he_market.gd")
const Commodity =preload("res://scripts/sim/records/commodity.gd")
const Recipe = preload("res://scripts/sim/records/recipe.gd")
const HENeed = preload("res://scripts/sim/household_economy/records/he_need.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")

## H1 labor-market acceptance check. Run with:
##   godot --headless --script res://scripts/sim/harness/run_household_economy.gd

const SEED := 4242
const EPSILON := 0.01

var _ok := true

func _init() -> void:
	_check_determinism()
	_check_multi_settlement_locality()
	_check_conservation()
	_check_bloomery_smelting()
	_check_businesses_share_wood_with_households()
	_check_input_purchases_on_credit()
	_check_goods_flow_history_reconciles_with_stock()
	_check_market_supply_demand_history()
	_check_local_iron_mine_supplies_bloomery_first()
	_check_trader_export_settings()
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
	_check_herd_staffing_matters()
	_check_herd_monetization()
	_check_butcher_processes_livestock()
	_check_needs_catalog()
	_check_need_substitutes()
	_check_government_taxes()

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
	reconciled_commodities.append_array(HESimulation.HERD_COMMODITIES)

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
	# he_simulation.gd's _pay_wages) before wages get rationed, so its floor
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
		var floor: float = -HESimulation.WAGE_NEGATIVE_BALANCE_FLOOR_DAYS * report["reference_wage_per_worker"] * report["employed_workers"]
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
	var wage_floor: float = -HESimulation.WAGE_NEGATIVE_BALANCE_FLOOR_DAYS * in_debt._reference_wage_per_worker(settlement_id) * employed
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
		_assert(supplied.size() == window and demanded.size() == window, "%s history should be capped at %d days, got %d/%d" % [Commodity.name_of(commodity), window, supplied.size(), demanded.size()])
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
			if employed > report["max_capacity"]:
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
## comment and he_simulation.gd's _pay_wages/_evaluate_business_capacity) --
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
		intervals * HESimulation.HERD_EVAL_INTERVAL_DAYS / 360, cattle["herd_size"], HESimulation.HERD_CULL_TARGET[HEBusiness.Species.CATTLE], cattle["stock"],
		sheep["herd_size"], HESimulation.HERD_CULL_TARGET[HEBusiness.Species.SHEEP], sheep["stock"], sheep["wool_stock"]])

	_assert(cattle["herd_size"] > HEScenarioSeeds.CATTLE_STARTING_HERD, "Cattle herd should have grown from its seeded starting size")
	_assert(sheep["herd_size"] > HEScenarioSeeds.SHEEP_STARTING_HERD, "Sheep herd should have grown from its seeded starting size")
	_assert(cattle["herd_size"] <= HESimulation.HERD_CULL_TARGET[HEBusiness.Species.CATTLE] + EPSILON, "Cattle herd should never exceed its cull target, got %.2f" % cattle["herd_size"])
	_assert(sheep["herd_size"] <= HESimulation.HERD_CULL_TARGET[HEBusiness.Species.SHEEP] + EPSILON, "Sheep herd should never exceed its cull target, got %.2f" % sheep["herd_size"])
	_assert(cattle["stock"] > 0.0, "Cattle Ranch should have culled at least once by now, stock is still 0")
	_assert(sheep["stock"] > 0.0, "Sheep Farm should have culled at least once by now, stock is still 0")
	_assert(sheep["wool_stock"] > 0.0, "Sheep Farm should have accumulated some wool by now")

	var land_used: float = cattle["herd_size"] * HESimulation.CATTLE_LAND_PER_HEAD + sheep["herd_size"] * HESimulation.SHEEP_LAND_PER_HEAD
	print("  shared grazing land used: %.1f / %.1f" % [land_used, HESimulation.SETTLEMENT_GRAZING_LAND])
	_assert(land_used <= HESimulation.SETTLEMENT_GRAZING_LAND + EPSILON, "Cattle and sheep together should never claim more than SETTLEMENT_GRAZING_LAND, used %.2f" % land_used)

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
	var default_target := HESimulation.HERD_CULL_TARGET[HEBusiness.Species.SHEEP]
	_assert(is_equal_approx(sim.herd_cull_target(sheep), default_target), "An untouched ranch should use its species default cull target")
	var default_capacity := sheep.max_capacity

	# Raising it: the staff ceiling grows with the bigger herd to look after.
	var raised := sim.set_herd_cull_target(sheep_id, 400.0)
	_assert(is_equal_approx(raised, 400.0), "A target inside the allowed range should be applied as given, got %.1f" % raised)
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

## Husbandry: a herd's labor must have a real marginal product, or the
## capacity tuner has no stable staffing level to find (it churned the Sheep
## Farm ~400 times in 10 years when staffing changed nothing). Same seed, two
## worlds: ranches with no workers allowed vs. ranches pinned fully staffed
## (protected from the tuner so the comparison isn't muddied by hiring noise).
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
		s.protected_until_day = 1000000
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

## The Butcher turns a ranch's cull into meat and leather instead of the Trader
## exporting it raw, and households eat the meat (twice grain's food value) and
## may wear the leather. Run for four years so both ranches have culled
## several times, reconciling goods and money every single day.
func _check_butcher_processes_livestock() -> void:
	print("\n=== Butcher: ranch culls become meat and leather, which households eat ===")
	var sim := _new_sim("build_three_business_economy")
	var butcher: HEBusiness = sim.businesses[HEScenarioSeeds.BUTCHER_BUSINESS_ID]
	_assert(butcher.processes_livestock and butcher.sells(Commodity.Type.MEAT) and butcher.sells(Commodity.Type.LEATHER),
		"The seeded Butcher should process livestock into meat and leather")
	_assert(sim._business_selling(sim.get_settlement_ids()[0], Commodity.Type.LEATHER) == butcher,
		"The Butcher should be the local seller of its secondary output too")

	var reconciled_commodities := HESimulation.SUBSISTENCE_COMMODITIES.duplicate()
	reconciled_commodities.append_array(HESimulation.HERD_COMMODITIES)
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
	_assert(butchered > exported_raw, "Most of the cull should go to the Butcher rather than leave raw (%.0f butchered vs %.0f exported)" % [butchered, exported_raw])
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

## The catalog is what every consumption/market/reserve loop reads, so pin its
## shape: the three needs, today's one satisfier each, and food alone driving
## the lifecycle engine.
func _check_needs_catalog() -> void:
	print("\n=== Household needs: catalog ===")
	var ids: Array = []
	for need in HENeeds.all():
		ids.append(need.id)
	_assert(ids == [HENeed.Id.FOOD, HENeed.Id.HEAT, HENeed.Id.CLOTHING], "Needs should be food, heat, clothing in that order")
	_assert(HESimulation.SUBSISTENCE_COMMODITIES == [Commodity.Type.MEAT, Commodity.Type.GRAIN, Commodity.Type.TIMBER, Commodity.Type.LEATHER, Commodity.Type.WOOL],
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

	# Preferred satisfier: the baseline until an alternative is both in supply
	# and cheaper per need-unit (wool 2.0 / 4 = 0.5 vs timber 1.0).
	var sim := _new_sim("build_three_business_economy")
	var settlement_id: int = sim.get_settlement_ids()[0]
	_assert(sim._preferred_satisfier(settlement_id, need) == Commodity.Type.TIMBER, "With no alternative in supply, the baseline should be preferred")
	var trader: HEBusiness = sim._settlement_trader(settlement_id)
	trader.add_stock(Commodity.Type.WOOL, 5.0)
	_assert(sim._preferred_satisfier(settlement_id, need) == Commodity.Type.WOOL, "A cheaper-per-unit satisfier in supply should be preferred")
	print("  burn order, partial burns and preferred-satisfier choice behave as expected")

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
	for d in days:
		sim.advance_ticks(1)
		worst_treasury = minf(worst_treasury, sim.get_government_summary(1)["treasury"])
		if d >= 30:
			for report in sim.get_business_reports(1):
				if report["business_id"] == gov_id and report["wage_shortfall"] > EPSILON:
					late_shortfall_days += 1
	summary = sim.get_government_summary(1)
	var wage_per_day := 0.0
	for report in sim.get_business_reports(1):
		if report["business_id"] == gov_id:
			wage_per_day = report["last_wages_paid"]
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
