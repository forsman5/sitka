extends RefCounted

## What every business pays its workers, and what that wage is measured and
## backed against. Split out of HESimulation so the wage model has one home;
## the simulation owns the state (households, businesses, markets, the day)
## and this class reads it through `_sim`. See docs/household-wage-model-plan.md.
##
## The "reference wage" plays three roles, kept in separate functions so each
## can change alone. Business pay uses it as a floor; the other two roles use
## the derived value directly:
##   A. wage_paid_per_worker(b)         what `b` actually pays each worker
##   B. capacity_benchmark_wage(s)      what a business's return per worker is
##                                      judged against when capacity is tuned
##   C. liquidity_scale(s)              the wage scale settlement-wide reserves
##                                      are sized on (trader spread, warehouse)

const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")
const HEMarket = preload("res://scripts/sim/household_economy/records/he_market.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

## The share of a business's net return per worker (sales
## less inputs and taxes, over the staffing window) paid out as the wage.
const LABOUR_SHARE := 0.6

var labour_share: float = LABOUR_SHARE
## Fraction paid above the subsistence-derived wage (0 = exactly subsistence).
## An experiment lever for measure_household_slack / measure_wage_margin; the
## capacity loop and every wage-linked floor read it through the reference wage.
var reference_wage_margin: float = 0.0

## The simulation owns this object, so it is held weakly: a strong reference
## back would be a RefCounted cycle that is never freed. Hot functions copy it
## to a local once (`var s = _sim`).
var _sim_ref: WeakRef
var _sim:
	get:
		return _sim_ref.get_ref()
var _wage_paid_cache: Dictionary = {} # business id -> {"day": int, "wage": float}

func _init(sim) -> void:
	_sim_ref = weakref(sim)

# --- The three roles ------------------------------------------------------------

## A. What `b` pays each of its workers today (the wage actually paid, and the
## wage bill its own cash runway, fodder budget and input credit are sized on).
func wage_paid_per_worker(b: HEBusiness) -> float:
	var s = _sim
	var reservation := reference_wage_per_worker(b.settlement_id)
	# A treasury-paid crew has no revenue of its own to share.
	if b.kind == HEBusiness.Kind.GOVERNMENT or b.kind == HEBusiness.Kind.WAREHOUSE:
		return reservation
	var cached: Dictionary = _wage_paid_cache.get(b.id, {})
	if cached.get("day", -1) == s.day:
		return float(cached["wage"])
	# The household reservation is the floor; what the business can fund is
	# bounded by pay_wages' available cash and by the share itself (< 1).
	var wage := maxf(reservation, labour_share * net_return_per_worker(b))
	_wage_paid_cache[b.id] = {"day": s.day, "wage": wage}
	return wage

## B. The benchmark a business's return per worker is judged against when its
## capacity is tuned (_evaluate_business_capacity, _staffing_decision).
func capacity_benchmark_wage(settlement_id: int) -> float:
	return reference_wage_per_worker(settlement_id)

## C. The wage scale settlement-wide reserves are sized on (the Trader's spread
## floor, the Warehouse's wage reserve) -- not any one business's own bill.
func liquidity_scale(settlement_id: int) -> float:
	return reference_wage_per_worker(settlement_id)

## `b`'s net return per employed worker over its staffing window: sales less
## inputs and taxes, the same quantity _staffing_decision judges. 0 until the
## ledger holds enough rows to trust it.
func net_return_per_worker(b: HEBusiness) -> float:
	var s = _sim
	var window := b.rolling_window_days()
	var needed_rows: int = mini(window, s.STAFFING_RETURN_WINDOW_DAYS) if b.uses_field_model() else (window if b.has_long_cycle() else mini(window, 14))
	if b.ledger_history(window).size() < needed_rows:
		return 0.0
	var money_window: int = mini(window, s.STAFFING_RETURN_WINDOW_DAYS) if b.uses_field_model() else window
	var sales := 0.0
	for key in ["sales_household", "sales_business", "sales_export", "sales_other", "trade_margin"]:
		sales += b.ledger_average(key, money_window)
	var net := sales - b.ledger_average("input_consumed_value", money_window) - b.ledger_average("taxes", money_window)
	return maxf(0.0, net / maxf(1.0, b.ledger_average("employed", money_window)))

# --- The derived (subsistence) wage ---------------------------------------------

## The going rate a worker's wage needs to clear for that worker's WHOLE
## household to afford subsistence: (population / total workers) people
## depend on each worker's wage, on average, and each of those people needs
## every HENeed's per-person daily amount, bought as the cheapest satisfier
## per need-unit on offer, priced at each commodity's trailing average
## (_average_price_history) in THIS settlement's market rather than today's
## live spot price. A business's rolling_average_wage() is already smoothed
## over HEBusiness.WAGE_ROLLING_WINDOW_DAYS; comparing that against a live
## price would pit a slow-moving average against a fast one that the SAME
## business's own output directly moves (selling more grain pushes
## grain_price down, which lowers both sides of the comparison through the
## same channel) -- a timescale mismatch that reads as a profitability
## signal when it's really same-day noise. Smoothing both sides over the
## same window fixes that without hiding a genuine, sustained price
## trend -- it just takes as long to show up here as it does in the wage
## average it's being judged against.
##
## This is the number _evaluate_business_capacity compares each business's
## actual wage against -- a business paying above it is generating more
## value per worker than that worker's household needs to survive
## (profitable, should grow); below it, it structurally can't sustain the
## households working there (unprofitable, should shrink), regardless of
## what its production recipe's rate happens to be.
func reference_wage_per_worker(settlement_id: int) -> float:
	var s = _sim
	var total_workers := 0
	var total_population := 0
	for household_id in (s.settlements[settlement_id] as HESettlement).household_ids:
		var h: HEHousehold = s.households[household_id]
		total_workers += h.worker_capacity()
		total_population += h.headcount()
	if total_workers <= 0:
		return 0.0
	var dependency_ratio := float(total_population) / float(total_workers)
	var per_person_cost := 0.0
	for need in HENeeds.all():
		if not s._need_served(settlement_id, need):
			continue
		var cheapest_unit_cost := INF
		for c in s._household_cascade(settlement_id, need):
			cheapest_unit_cost = minf(cheapest_unit_cost, s._average_price_history(settlement_id, c) / need.value_of(c))
		per_person_cost += cheapest_unit_cost * need.per_person_daily
	return dependency_ratio * per_person_cost * (1.0 + reference_wage_margin)

# --- Paying -------------------------------------------------------------------

## How far below zero `b` may run while paying wages. A business may owe up to
## WAGE_NEGATIVE_BALANCE_FLOOR_DAYS of its wage bill; a government none. A ranch
## has no income until its herd reaches the cull target, so for a ranch the limit
## is the larger of that and a share of its herd's exit value (_herd_collateral):
## payroll is then financed by the cull it is waiting for rather than by
## slaughtering the breeding stock whose care it is paying for.
func overdraft_limit(b: HEBusiness, total_needed: float) -> float:
	var s = _sim
	if b.kind == HEBusiness.Kind.GOVERNMENT or b.kind == HEBusiness.Kind.WAREHOUSE:
		return 0.0
	var limit: float = s.WAGE_NEGATIVE_BALANCE_FLOOR_DAYS * total_needed
	if b.kind == HEBusiness.Kind.HERD:
		limit = maxf(limit, _herd_collateral(b))
	elif b.processes_livestock:
		limit = maxf(limit, _butchery_collateral(b))
	return limit

## What a Butcher can borrow against the animals it holds: HERD_COLLATERAL_FRACTION
## of their value at the Trader's bid -- the same always-available exit price a
## ranch's herd is valued at -- so a first cull bought on credit does not leave it
## below a wage floor it cannot pay from.
func _butchery_collateral(b: HEBusiness) -> float:
	var s = _sim
	var value := 0.0
	for species in s.BUTCHERY_SPECIES_ORDER:
		value += b.stock(HEBusiness.livestock_commodity(species)) * s.livestock_quote(species, s.LivestockQuote.TRADER_BID)
	return value * s.HERD_COLLATERAL_FRACTION

## What a ranch can borrow against its living herd: HERD_COLLATERAL_FRACTION of
## the herd valued at the Trader's bid, the exit price that is always on offer
## (the Butcher pays more, but only when one is staffed). The herd counted is the
## one at its last review (HEBusiness.collateral_herd), not today's: a head
## slaughtered to make payroll must not also shrink the limit it is being
## slaughtered under, or each day's slaughter raises the next day's need and the
## ranch spirals into failing. The limit follows the herd at each review.
func _herd_collateral(b: HEBusiness) -> float:
	var s = _sim
	var herd: float = maxf(b.herd_size, b.collateral_herd)
	return herd * s.livestock_quote(b.species, s.LivestockQuote.TRADER_BID) * s.HERD_COLLATERAL_FRACTION

## Every business pays each currently-employed household a wage per worker
## (wage_paid_per_worker) drawn from its own cash reserve (see
## WAGE_NEGATIVE_BALANCE_FLOOR_DAYS: balance is allowed to run deeply negative
## before pay actually gets rationed). Paid before today's market runs, so
## households can spend a wage the same day they earn it. Whether a business
## can actually AFFORD paying the going wage long-term is not this function's
## problem -- it always pays as much of the full bill as its (generous) cash
## allowance covers, and the weekly cash-runway guard in
## _evaluate_business_capacity is what actually shrinks a business that can't
## keep this up. A business whose wage bill can't be covered even down to that
## floor has exhausted its credit and is deleted (see _fail_business).
func pay_wages(record: Dictionary) -> void:
	var s = _sim
	var failed_ids: Array[int] = []
	for business_id in s.businesses.keys():
		var b: HEBusiness = s.businesses[business_id]
		b.last_wages_paid = 0.0
		b.last_cash_change = 0.0
		b.last_wage_shortfall = 0.0
		b.todays_flows = {}
		var carried_injection: float = b.ledger_today.get("injection", 0.0)
		b.open_ledger_day()
		if carried_injection != 0.0:
			b.ledger_add("injection", carried_injection)
		b.last_tax_collected = 0.0
		# Single reset point for the day, since not every business's
		# last_revenue gets overwritten later the same tick the way a
		# SUBSISTENCE_COMMODITIES seller's does in _clear_market_for --
		# a business selling a commodity nothing local consumes (the
		# Bloomery's iron) is only ever touched by _run_input_purchasing/
		# _run_trade below, both of which now ADD to this baseline rather
		# than assign, so today's contributions from each never clobber
		# each other.
		b.last_revenue = 0.0
		var employed: int = s._business_employed_worker_count(business_id)
		b.ledger_today["employed"] = float(employed)
		if employed <= 0:
			b.last_wage_per_worker = 0.0
			record["wages_paid"][business_id] = 0.0
			continue
		var wage := wage_paid_per_worker(b)
		var total_needed: float = wage * employed
		# A government pays only out of what its treasury actually holds -- no
		# overdraft allowance, unlike a business that expects to earn it back.
		# A warehouse has no cash of its own: its crew is paid by the treasury.
		var payer: HEBusiness = b
		if b.kind == HEBusiness.Kind.WAREHOUSE:
			payer = s._settlement_government(b.settlement_id)
			if payer == null:
				payer = b
		var floor: float = -overdraft_limit(b, total_needed)
		if b.kind == HEBusiness.Kind.HERD:
			# Not clamped at the floor: debt already BELOW the floor counts
			# toward what must be raised, so a crew that's hired is always
			# actually paid (a hire into existing debt otherwise worked for 0).
			s._hardship_butcher_if_needed(b, maxf(0.0, total_needed - (b.balance - floor)), record)
			# The meat that slaughter just put on the shelf only becomes cash
			# when households buy it later this tick, so it counts as
			# collateral against the wage floor -- otherwise the very wage it
			# was slaughtered to cover would fail the ranch first.
			floor -= b.stock(Commodity.Type.MEAT) * (s.markets[b.settlement_id] as HEMarket).price[Commodity.Type.MEAT]
		var available: float = max(0.0, payer.balance - floor)
		var paid: float = clampf(total_needed, 0.0, available)
		var shortfall: float = total_needed - paid
		var wage_per_worker: float = paid / employed
		b.last_wage_per_worker = wage_per_worker
		b.record_wage_day(wage_per_worker)
		b.last_wage_shortfall = shortfall
		var total_paid := 0.0
		for household_id in s._employment_index().get(business_id, []):
			var h: HEHousehold = s.households[household_id]
			var pay: float = wage_per_worker * h.worker_capacity()
			h.balance += pay
			total_paid += pay
		payer.balance -= total_paid
		b.last_wages_paid = total_paid
		b.ledger_add("wages", total_paid)
		payer.last_cash_change -= total_paid
		record["wages_paid"][business_id] = total_paid
		if shortfall > 0.0001 and b.kind != HEBusiness.Kind.GOVERNMENT and b.kind != HEBusiness.Kind.WAREHOUSE:
			failed_ids.append(business_id)
	for business_id in failed_ids:
		s._fail_business(business_id, record)
