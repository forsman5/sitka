class_name HESimulation
extends RefCounted

## H1, labor-market cut: deterministic, tick-based household economy inside
## one settlement. Opt-in and separate from Simulation (scripts/sim/
## simulation.gd)'s pooled valley model. Businesses (Farm, Woodlot -- see
## he_business.gd) are city-owned productive sites that hire households as
## labor, produce, sell on the market, and pay wages; households own no
## production themselves -- they supply labor, earn wages, and buy grain/
## timber to survive. A business's employee-slot count self-tunes weekly:
## paying above the going subsistence-equivalent wage lets it grow, paying
## below shrinks it, so labor drifts from an unprofitable business to a
## profitable one without anyone hand-tuning production rates. Starvation
## is real here (unlike the earlier owner-operator cut): a household that
## can't earn or afford enough to eat can lose members and cease to exist.
## Advanced only through advance_ticks(); nothing here reads or writes the
## scene tree.
##
## API boundary, same discipline as the pooled Simulation: callers use these
## query methods only, never the households/businesses Dictionaries
## directly. Returned dictionaries/arrays are snapshots and cannot mutate
## simulation state:
##   get_household_ids(), get_clock_summary(), get_household_summary(id),
##   get_business_reports(), get_market_summary(), get_city_summary(),
##   get_daily_history(days)

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Household = preload("res://scripts/sim/records/household.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")
const HEMarket = preload("res://scripts/sim/household_economy/records/he_market.gd")

## H1's two complementary goods -- grain (food) and timber, standing in for
## household fuel demand in this isolated experiment.
const SUBSISTENCE_COMMODITIES: Array[Commodity.Type] = [Commodity.Type.GRAIN, Commodity.Type.TIMBER]

const GRAIN_PER_PERSON_PER_DAY := 0.4 # matches Simulation.GRAIN_PER_PERSON_PER_DAY
const FUEL_TIMBER_PER_PERSON_PER_DAY := 0.1 # authored placeholder, not yet tuned

## A household requests up to this many days' worth of buffer; there is no
## "protected" seller buffer any more -- businesses aren't consumers of
## their own output, so they always offer everything they have.
const TARGET_BUFFER_DAYS := 3.0

const BASE_PRICE: Dictionary[Commodity.Type, float] = {
	Commodity.Type.GRAIN: 1.0,
	Commodity.Type.TIMBER: 1.0,
}
const PRICE_ADJUST_STEP := 0.05
const PRICE_MULTIPLIER_MIN := 0.25
const PRICE_MULTIPLIER_MAX := 4.0

const MIGRATION_PRESSURE_EVAL_INTERVAL_DAYS := 7
const STARVATION_EVAL_INTERVAL_DAYS := 30 # matches Simulation's cadence choice

## Weekly self-tuning: a business earning (rolling-average) more than
## WAGE_PROFIT_MARGIN above the going reference wage grows by
## CAPACITY_STEP_WORKERS (capped at max_capacity); one earning that much
## below shrinks by the same step (floored at 0). The margin is a dead-band
## so a business hovering near break-even doesn't thrash every week.
const CAPACITY_EVAL_INTERVAL_DAYS := 7
const CAPACITY_STEP_WORKERS := 4
const WAGE_PROFIT_MARGIN := 0.1

const HISTORY_MAX_DAYS := 360

var settlement: HESettlement
var households: Dictionary[int, HEHousehold] = {}
var businesses: Dictionary[int, HEBusiness] = {}
var market: HEMarket

var rng: RandomNumberGenerator
var day: int = 0

## Lets a scenario prove accounting with fixed quotes first before
## exercising the bounded price-drift rule.
var price_adjustment_enabled: bool = true

var _starvation_deaths_total := 0
var _money_written_off_total := 0.0
var _goods_written_off_total: Dictionary[Commodity.Type, float] = {}

var _history: Array[Dictionary] = []

func _init(seed: int, builder: Callable, p_price_adjustment_enabled: bool = true) -> void:
	rng = RandomNumberGenerator.new()
	rng.seed = seed
	price_adjustment_enabled = p_price_adjustment_enabled
	var world: Dictionary = builder.call(rng)
	settlement = world["settlement"]
	households = world["households"]
	businesses = world["businesses"]
	market = HEMarket.new(BASE_PRICE.duplicate())

func advance_ticks(days: int) -> void:
	for i in days:
		_daily_tick()
		day += 1

# ---------------------------------------------------------------------------
# Public query contract
# ---------------------------------------------------------------------------

func get_household_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(households.keys())
	ids.sort()
	return ids

func get_clock_summary() -> Dictionary:
	return {"day": day}

func get_household_summary(household_id: int) -> Dictionary:
	var h: HEHousehold = households[household_id]
	var inventory := {}
	var demand := {}
	var consumed := {}
	var unmet_scarcity := {}
	var unmet_unaffordable := {}
	for c in SUBSISTENCE_COMMODITIES:
		var name := Commodity.name_of(c)
		inventory[name] = h.stock(c)
		demand[name] = h.last_demand.get(c, 0.0)
		consumed[name] = h.last_consumed.get(c, 0.0)
		unmet_scarcity[name] = h.last_unmet_scarcity.get(c, 0.0)
		unmet_unaffordable[name] = h.last_unmet_unaffordable.get(c, 0.0)

	return {
		"id": h.id,
		"worker_capacity": h.worker_capacity(),
		"dependents": h.demographics.dependents,
		"headcount": h.headcount(),
		"employer_business_id": h.employer_business_id,
		"is_employed": h.is_employed(),
		"inventory": inventory,
		"balance": h.balance,
		"food_stress": h.demographics.food_stress,
		"rolling_grain_fulfillment_30d": h.rolling_grain_fulfillment(),
		"has_migration_pressure": h.demographics.has_migration_pressure,
		"is_starvation_candidate": h.demographics.is_starvation_candidate(),
		"demand_today": demand,
		"consumed_today": consumed,
		"unmet_scarcity_today": unmet_scarcity,
		"unmet_unaffordable_today": unmet_unaffordable,
	}

func get_business_reports() -> Array:
	var out: Array = []
	var ids := businesses.keys()
	ids.sort()
	var reference_wage := _reference_wage_per_worker()
	for business_id in ids:
		var b: HEBusiness = businesses[business_id]
		var output_commodity := b.output_commodity()
		out.append({
			"business_id": b.id,
			"name": b.name,
			"recipe_id": b.recipe.id,
			"output_commodity": Commodity.name_of(output_commodity),
			"capacity": b.capacity,
			"max_capacity": b.max_capacity,
			"employed_workers": _business_employed_worker_count(business_id),
			"employed_household_count": _business_employed_household_count(business_id),
			"stock": b.stock(output_commodity),
			"balance": b.balance,
			"last_actual_units": b.last_actual_units,
			"last_wage_per_worker": b.last_wage_per_worker,
			"rolling_average_wage": b.rolling_average_wage(),
			"reference_wage_per_worker": reference_wage,
		})
	return out

func get_market_summary() -> Dictionary:
	var out := {}
	for c in SUBSISTENCE_COMMODITIES:
		out[Commodity.name_of(c)] = {
			"price": market.price[c],
			"last_clearing": (market.last_clearing.get(c, {}) as Dictionary).duplicate(),
		}
	return out

## City-wide totals AND distributions -- a healthy average must not hide a
## hungry or unfunded household.
func get_city_summary() -> Dictionary:
	var household_count := households.size()
	var households_short_of_goods := 0
	var households_short_of_funds := 0
	var unemployed_household_count := 0
	var stress_total := 0.0

	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		var scarcity_total := 0.0
		for v in h.last_unmet_scarcity.values():
			scarcity_total += v
		var unaffordable_total := 0.0
		for v in h.last_unmet_unaffordable.values():
			unaffordable_total += v
		if scarcity_total > 0.0001:
			households_short_of_goods += 1
		if unaffordable_total > 0.0001:
			households_short_of_funds += 1
		if not h.is_employed():
			unemployed_household_count += 1
		stress_total += h.demographics.food_stress

	return {
		"day": day,
		"household_count": household_count,
		"population": _total_population(),
		"unemployed_household_count": unemployed_household_count,
		"total_stock": _total_stock_snapshot(),
		"total_money": _total_money(),
		"avg_food_stress": (stress_total / household_count) if household_count > 0 else 0.0,
		"households_short_of_goods": households_short_of_goods,
		"households_short_of_funds": households_short_of_funds,
		"starvation_deaths_total": _starvation_deaths_total,
		"money_written_off_total": _money_written_off_total,
		"market": get_market_summary(),
	}

## Up to the last `days` daily records, oldest first. Each is deep-copied --
## mutating the returned data cannot affect the simulation.
func get_daily_history(days: int) -> Array:
	var start: int = max(0, _history.size() - days)
	var out: Array = []
	for i in range(start, _history.size()):
		out.append((_history[i] as Dictionary).duplicate(true))
	return out

# ---------------------------------------------------------------------------
# Daily tick: pay wages (from yesterday's settled revenue) -> produce ->
# clear the market (sets today's revenue for TOMORROW's wages) -> consume ->
# stress/migration-pressure (weekly) -> starvation (monthly, ACTS this time)
# -> business capacity self-tuning + labor reallocation (weekly) -> publish.
# ---------------------------------------------------------------------------

func _daily_tick() -> void:
	_reset_household_daily_records()
	var record := _new_daily_record()
	_pay_wages(record)
	_run_production(record)
	_run_market(record)
	_run_consumption(record)
	if (day + 1) % MIGRATION_PRESSURE_EVAL_INTERVAL_DAYS == 0:
		_evaluate_migration_pressure()
	if (day + 1) % STARVATION_EVAL_INTERVAL_DAYS == 0:
		_evaluate_starvation(record)
	if (day + 1) % CAPACITY_EVAL_INTERVAL_DAYS == 0:
		_evaluate_business_capacity(record)
		_reconcile_employment()
	_finalize_daily_record(record)

func _reset_household_daily_records() -> void:
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		h.last_demand = {}
		h.last_consumed = {}
		h.last_unmet_scarcity = {}
		h.last_unmet_unaffordable = {}

func _new_daily_record() -> Dictionary:
	return {
		"day": day,
		"opening_stock": _total_stock_snapshot(),
		"opening_money": _total_money(),
		"produced": {},
		"consumed": {},
		"unmet_scarcity": {},
		"unmet_unaffordable": {},
		"traded_quantity": {},
		"wages_paid": {},
		"starvation_deaths": 0,
		"money_written_off": 0.0,
		"goods_written_off": {},
	}

func _finalize_daily_record(record: Dictionary) -> void:
	record["closing_stock"] = _total_stock_snapshot()
	record["closing_money"] = _total_money()
	record["population"] = _total_population()
	_history.append(record)
	if _history.size() > HISTORY_MAX_DAYS:
		_history.pop_front()

## Every business pays each currently-employed household a wage per worker
## equal to YESTERDAY's settled revenue divided by TODAY's employed worker
## count -- paid before today's market runs (so households can spend a
## wage the same day they earn it; unlike the household-to-household market,
## there's no same-day circularity here, since the wage is fixed from
## yesterday's number before today's clearing even starts).
func _pay_wages(record: Dictionary) -> void:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		var employed := _business_employed_worker_count(business_id)
		var wage_per_worker: float = (b.last_revenue / employed) if employed > 0 else 0.0
		b.last_wage_per_worker = wage_per_worker
		b.record_wage_day(wage_per_worker)
		if employed <= 0 or wage_per_worker <= 0.0:
			record["wages_paid"][business_id] = 0.0
			continue
		var total_paid := 0.0
		for household_id in households.keys():
			var h: HEHousehold = households[household_id]
			if h.employer_business_id != business_id:
				continue
			var pay: float = wage_per_worker * h.worker_capacity()
			h.balance += pay
			total_paid += pay
		b.balance -= total_paid
		record["wages_paid"][business_id] = total_paid

## Each business produces its one recipe output using however many workers
## it currently has (derived live from household employer_business_id, not
## cached) -- no input constraints in H1's two recipes, so planned==actual.
func _run_production(record: Dictionary) -> void:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		var employed := _business_employed_worker_count(business_id)
		var output_commodity := b.output_commodity()
		var rate: float = b.recipe.outputs[output_commodity]
		var units: float = float(employed) * rate
		b.add_stock(output_commodity, units)
		b.last_planned_units = units
		b.last_actual_units = units
		b.last_output_produced = {output_commodity: units}
		var name := Commodity.name_of(output_commodity)
		record["produced"][name] = record["produced"].get(name, 0.0) + units

func _daily_need(h: HEHousehold, commodity: Commodity.Type) -> float:
	var headcount := float(h.headcount())
	match commodity:
		Commodity.Type.GRAIN:
			return headcount * GRAIN_PER_PERSON_PER_DAY
		Commodity.Type.TIMBER:
			return headcount * FUEL_TIMBER_PER_PERSON_PER_DAY
	return 0.0

## Consume owned goods -> update household stress/outcomes, purely from
## each household's OWN inventory. Only grain drives food_stress/migration-
## pressure/starvation-candidacy (fuel shortfall is tracked/reported but
## doesn't feed the reused stress engine, mirroring the pooled model's
## wool/tools-don't-feed-food-stress convention).
func _run_consumption(record: Dictionary) -> void:
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		for commodity in SUBSISTENCE_COMMODITIES:
			var demand := _daily_need(h, commodity)
			var taken := h.consume(commodity, demand)
			var shortfall := demand - taken
			h.last_demand[commodity] = demand
			h.last_consumed[commodity] = taken
			if shortfall > 0.0001:
				_accumulate(h.last_unmet_scarcity, commodity, shortfall)

			var name := Commodity.name_of(commodity)
			record["consumed"][name] = record["consumed"].get(name, 0.0) + taken
			record["unmet_scarcity"][name] = record["unmet_scarcity"].get(name, 0.0) + h.last_unmet_scarcity.get(commodity, 0.0)
			record["unmet_unaffordable"][name] = record["unmet_unaffordable"].get(name, 0.0) + h.last_unmet_unaffordable.get(commodity, 0.0)

			if commodity == Commodity.Type.GRAIN:
				var daily_ratio := h.record_grain_day(demand, taken)
				var rolling := h.rolling_grain_fulfillment()
				var rolling_is_low := rolling < Household.MIGRATION_PRESSURE_FULFILLMENT_THRESHOLD
				var rolling_is_severe := rolling < Household.STARVATION_FULFILLMENT_THRESHOLD
				h.demographics.apply_daily_fulfillment(daily_ratio, rolling_is_low, rolling_is_severe)

## Reporting only, exactly like the pooled model's migration pressure --
## does NOT move or remove anyone.
func _evaluate_migration_pressure() -> void:
	for household_id in households.keys():
		(households[household_id] as HEHousehold).demographics.update_migration_pressure()

## Unlike the earlier owner-operator cut, this ACTS: a household that's been
## severely short of food for a sustained stretch loses a member, and a
## household that runs out of members entirely is removed. Its employer (if
## any) automatically has one fewer worker from that point on, since
## employed-worker counts are always derived live from households, never
## cached. Any residual balance/inventory a household still held at the
## moment it winks out of existence is written off -- not redistributed,
## not inherited -- and tracked explicitly (see get_city_summary's
## money_written_off_total) so the closed-economy accounting stays honest
## about where it went instead of just quietly not adding up.
func _evaluate_starvation(record: Dictionary) -> void:
	var deaths := 0
	var to_remove: Array[int] = []
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		if not h.demographics.is_starvation_candidate():
			continue
		h.demographics.remove_member()
		deaths += 1
		if h.demographics.is_empty():
			to_remove.append(household_id)

	var money_written_off := 0.0
	var goods_written_off: Dictionary[Commodity.Type, float] = {}
	for household_id in to_remove:
		var h: HEHousehold = households[household_id]
		money_written_off += h.balance
		for c in SUBSISTENCE_COMMODITIES:
			var amount := h.stock(c)
			if amount > 0.0:
				goods_written_off[c] = goods_written_off.get(c, 0.0) + amount
		settlement.household_ids.erase(household_id)
		households.erase(household_id)

	_starvation_deaths_total += deaths
	_money_written_off_total += money_written_off
	for c in goods_written_off.keys():
		_goods_written_off_total[c] = _goods_written_off_total.get(c, 0.0) + goods_written_off[c]

	record["starvation_deaths"] = deaths
	record["money_written_off"] = money_written_off
	record["goods_written_off"] = goods_written_off

## Weekly self-tuning step 1: adjust each business's TARGET capacity from
## its own rolling-average wage vs. the going reference wage. This only
## sets the target; _reconcile_employment (called right after) is what
## actually moves households between employers to approach it.
func _evaluate_business_capacity(record: Dictionary) -> void:
	var reference_wage := _reference_wage_per_worker()
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		var avg_wage := b.rolling_average_wage()
		if avg_wage > reference_wage * (1.0 + WAGE_PROFIT_MARGIN):
			b.capacity = mini(b.capacity + CAPACITY_STEP_WORKERS, b.max_capacity)
		elif avg_wage < reference_wage * (1.0 - WAGE_PROFIT_MARGIN):
			b.capacity = maxi(b.capacity - CAPACITY_STEP_WORKERS, 0)
	record["reference_wage"] = reference_wage

## Weekly self-tuning step 2: lay off whole households (highest household ID
## first, an arbitrary but deterministic tie-break) from any business now
## over its (possibly just-reduced) capacity, then let every under-capacity
## business hire from the resulting pool of unemployed households (lowest
## household ID first). Businesses are processed in a fixed ID order for
## hiring, so a lower-ID business gets first pick of the pool when two are
## expanding into the same freed labor at once -- a deterministic but real
## bias, same spirit as the pooled model's documented edge-order bias in
## _run_trade.
func _reconcile_employment() -> void:
	var business_ids := businesses.keys()
	business_ids.sort()

	for business_id in business_ids:
		var b: HEBusiness = businesses[business_id]
		var employed_ids: Array[int] = []
		for household_id in households.keys():
			if (households[household_id] as HEHousehold).employer_business_id == business_id:
				employed_ids.append(household_id)
		employed_ids.sort()
		var employed_workers := _business_employed_worker_count(business_id)
		var i := employed_ids.size() - 1
		while employed_workers > b.capacity and i >= 0:
			var household_id: int = employed_ids[i]
			var h: HEHousehold = households[household_id]
			employed_workers -= h.worker_capacity()
			h.employer_business_id = -1
			i -= 1

	var available: Array[int] = []
	for household_id in households.keys():
		if (households[household_id] as HEHousehold).employer_business_id == -1:
			available.append(household_id)
	available.sort()

	var pool_index := 0
	for business_id in business_ids:
		var b: HEBusiness = businesses[business_id]
		var employed_workers := _business_employed_worker_count(business_id)
		while employed_workers < b.capacity and pool_index < available.size():
			var household_id: int = available[pool_index]
			pool_index += 1
			var h: HEHousehold = households[household_id]
			if h.worker_capacity() <= 0:
				continue
			h.employer_business_id = business_id
			employed_workers += h.worker_capacity()

## Step: prepare and clear local offers/requests, one commodity at a time.
## Snapshots every household's balance ONCE before either commodity clears
## (today's wage is already in that balance, paid earlier this same tick),
## and reserves spend against that snapshot across both commodities -- a
## household that wants to buy both grain and timber the same day can't
## double-spend the same money twice just because it's requesting two goods
## in the same pass.
func _run_market(record: Dictionary) -> void:
	var starting_balance: Dictionary = {}
	for household_id in households.keys():
		starting_balance[household_id] = (households[household_id] as HEHousehold).balance
	var reserved_spend: Dictionary = {}

	for commodity in SUBSISTENCE_COMMODITIES:
		_clear_market_for(commodity, record, starting_balance, reserved_spend)

## One commodity's daily clearing. The seller side is now a single business
## (whichever one's recipe outputs this commodity, or none) offering its
## ENTIRE current stock -- a business has no reason to hold back inventory
## the way a subsistence household once did, since it doesn't consume its
## own product. The buyer side is unchanged: household requests are sized
## against subsistence need before affordability caps them, capped by what's
## left of this household's snapshotted starting balance.
##
## When one side outnumbers the other, both sides are scaled by a single
## ratio (quantity_traded / that side's total) -- pure proportional scaling
## over continuous float quantities, so there is no remainder to round and
## therefore no room for a lowest-household-ID-eats-first bias.
func _clear_market_for(commodity: Commodity.Type, record: Dictionary, starting_balance: Dictionary, reserved_spend: Dictionary) -> void:
	var price: float = market.price[commodity]
	var seller: HEBusiness = _business_selling(commodity)
	var total_offer: float = seller.stock(commodity) if seller != null else 0.0

	var requests_funded: Dictionary = {}
	var total_funded_request := 0.0

	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		var daily_need := _daily_need(h, commodity)
		var target_stock := daily_need * TARGET_BUFFER_DAYS
		var stock := h.stock(commodity)

		var desired_qty: float = max(0.0, target_stock - stock)
		if desired_qty > 0.0001:
			var available_balance: float = starting_balance[household_id] - reserved_spend.get(household_id, 0.0)
			var affordable_qty: float = (available_balance / price) if price > 0.0 else 0.0
			var funded_qty: float = min(desired_qty, max(0.0, affordable_qty))
			if funded_qty > 0.0001:
				requests_funded[household_id] = funded_qty
				total_funded_request += funded_qty
			var unaffordable: float = desired_qty - funded_qty
			if unaffordable > 0.0001:
				_accumulate(h.last_unmet_unaffordable, commodity, unaffordable)

	var quantity_traded: float = min(total_offer, total_funded_request)
	var name := Commodity.name_of(commodity)

	if quantity_traded > 0.0001:
		var buy_scale: float = quantity_traded / total_funded_request
		for household_id in requests_funded.keys():
			var funded: float = requests_funded[household_id]
			var bought: float = funded * buy_scale
			var h: HEHousehold = households[household_id]
			h.balance -= bought * price
			reserved_spend[household_id] = reserved_spend.get(household_id, 0.0) + bought * price
			h.add_stock(commodity, bought)
			var scarcity_shortfall: float = funded - bought
			if scarcity_shortfall > 0.0001:
				_accumulate(h.last_unmet_scarcity, commodity, scarcity_shortfall)

		if seller != null:
			seller.consume(commodity, quantity_traded)
			seller.balance += quantity_traded * price
			seller.last_revenue = quantity_traded * price
	elif seller != null:
		seller.last_revenue = 0.0

	market.last_clearing[commodity] = {
		"total_offered": total_offer,
		"total_requested_funded": total_funded_request,
		"quantity_traded": quantity_traded,
		"price": price,
	}
	record["traded_quantity"][name] = record["traded_quantity"].get(name, 0.0) + quantity_traded

	if price_adjustment_enabled:
		_adjust_price(commodity, total_offer, total_funded_request)

## Bounded, gradual next-day price drift from today's offered supply vs.
## affordable requested quantity -- frozen during today's clearing (this
## runs after, using totals already computed above, and mutates
## market.price for TOMORROW's _clear_market_for to read).
func _adjust_price(commodity: Commodity.Type, total_offer: float, total_funded_request: float) -> void:
	if total_offer <= 0.0 and total_funded_request <= 0.0:
		return
	var base: float = BASE_PRICE[commodity]
	var current: float = market.price[commodity]
	var new_price := current
	if total_funded_request > total_offer:
		new_price = current * (1.0 + PRICE_ADJUST_STEP)
	elif total_offer > total_funded_request:
		new_price = current * (1.0 - PRICE_ADJUST_STEP)
	market.price[commodity] = clamp(new_price, base * PRICE_MULTIPLIER_MIN, base * PRICE_MULTIPLIER_MAX)

func _accumulate(dict: Dictionary, key, amount: float) -> void:
	dict[key] = dict.get(key, 0.0) + amount

func _business_selling(commodity: Commodity.Type) -> HEBusiness:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b.output_commodity() == commodity:
			return b
	return null

func _business_employed_worker_count(business_id: int) -> int:
	var total := 0
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		if h.employer_business_id == business_id:
			total += h.worker_capacity()
	return total

func _business_employed_household_count(business_id: int) -> int:
	var total := 0
	for household_id in households.keys():
		if (households[household_id] as HEHousehold).employer_business_id == business_id:
			total += 1
	return total

## The going rate a worker's wage needs to clear for that worker's WHOLE
## household to afford subsistence: (population / total workers) people
## depend on each worker's wage, on average, and each of those people needs
## GRAIN_PER_PERSON_PER_DAY worth of grain plus FUEL_TIMBER_PER_PERSON_PER_DAY
## worth of timber at CURRENT market prices. This is the number
## _evaluate_business_capacity compares each business's actual wage
## against -- a business paying above it is generating more value per
## worker than that worker's household needs to survive (profitable, should
## grow); below it, it structurally can't sustain the households working
## there (unprofitable, should shrink), regardless of what its production
## recipe's rate happens to be.
func _reference_wage_per_worker() -> float:
	var total_workers := 0
	var total_population := 0
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		total_workers += h.worker_capacity()
		total_population += h.headcount()
	if total_workers <= 0:
		return 0.0
	var dependency_ratio := float(total_population) / float(total_workers)
	var per_person_cost := market.price[Commodity.Type.GRAIN] * GRAIN_PER_PERSON_PER_DAY \
		+ market.price[Commodity.Type.TIMBER] * FUEL_TIMBER_PER_PERSON_PER_DAY
	return dependency_ratio * per_person_cost

func _total_stock_snapshot() -> Dictionary:
	var snap := {}
	for c in SUBSISTENCE_COMMODITIES:
		var total := 0.0
		for household_id in households.keys():
			total += (households[household_id] as HEHousehold).stock(c)
		for business_id in businesses.keys():
			total += (businesses[business_id] as HEBusiness).stock(c)
		snap[Commodity.name_of(c)] = total
	return snap

func _total_money() -> float:
	var total := 0.0
	for household_id in households.keys():
		total += (households[household_id] as HEHousehold).balance
	for business_id in businesses.keys():
		total += (businesses[business_id] as HEBusiness).balance
	return total

func _total_population() -> int:
	var total := 0
	for household_id in households.keys():
		total += (households[household_id] as HEHousehold).headcount()
	return total
