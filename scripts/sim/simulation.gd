class_name Simulation
extends RefCounted

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Household = preload("res://scripts/sim/records/household.gd")
const Settlement = preload("res://scripts/sim/records/settlement.gd")
const Workplace = preload("res://scripts/sim/records/workplace.gd")
const TransportEdge = preload("res://scripts/sim/records/transport_edge.gd")
const Shipment = preload("res://scripts/sim/records/shipment.gd")
const ValleySeed = preload("res://scripts/sim/data/valley_seed.gd")

## Deterministic, tick-based economic simulation over plain-data records.
## Advanced only through advance_ticks(); nothing here reads or writes the
## scene tree. See docs/river-valley-vertical-slice.md sections 3-4 and
## Milestones 0.75/0.76.
##
## API boundary (Milestone 0.75, extended in Milestone 1): callers use these
## query methods only, never the settlements/households/workplaces/
## transport_edges/shipments Dictionaries directly. Returned dictionaries/
## arrays are snapshots and cannot mutate simulation state:
##   get_settlement_ids(), get_clock_summary(), get_settlement_summary(id),
##   get_settlement_history(id, days), get_workplace_reports(id),
##   get_game_over_info(), get_settlement_prices(id), get_transport_edge_ids(),
##   get_transport_edge_summary(id), get_active_shipments()

const DAYS_PER_SEASON := 90
const SEASONS_PER_YEAR := 4
const DAYS_PER_YEAR := DAYS_PER_SEASON * SEASONS_PER_YEAR

enum Season { SPRING, SUMMER, AUTUMN, WINTER }
const SEASON_NAMES := ["Spring", "Summer", "Autumn", "Winter"]

const GRAIN_PER_PERSON_PER_DAY := 0.4
const WOOL_PER_PERSON_PER_DAY := 0.01
const TOOLS_PER_PERSON_PER_DAY := 0.005

const FODDER_PER_HEAD_PER_SEASON := 3.0
const WINTER_LOSS_RATE_STARVED := 0.15
const WINTER_LOSS_RATE_FED := 0.02
const HERD_GROWTH_RATE := 0.05
const HERD_HARD_CEILING := 3000.0

const HISTORY_MAX_DAYS := 360
const MIGRATION_PRESSURE_EVAL_INTERVAL_DAYS := 7
const STARVATION_EVAL_INTERVAL_DAYS := 30
const COLLAPSE_HOUSEHOLD_THRESHOLD := 5
const COLLAPSE_SUSTAINED_DAYS := 30

## Milestone 1 (goods and routes), retuned: a settlement's price for a
## commodity is base_price * clamp(target_stock / stock, MIN, MAX) -- scarce
## is pricier, abundant is cheaper, both bounded so nothing goes to zero or
## infinity. target_stock is that settlement's OWN expected days-of-supply
## need (see _target_stock), not a single valley-wide number, so the same
## 500-grain stockpile reads as ample in a small settlement and thin in a
## large one. Deliberately simple/explainable over a real clearing market.
const BASE_PRICE: Dictionary[Commodity.Type, float] = {
	Commodity.Type.GRAIN: 1.0,
	Commodity.Type.CATTLE: 5.0,
	Commodity.Type.SHEEP: 3.0,
	Commodity.Type.WOOL: 2.0,
	Commodity.Type.TIMBER: 1.0,
	Commodity.Type.CHARCOAL: 1.5,
	Commodity.Type.IRON: 4.0,
	Commodity.Type.TOOLS: 6.0,
}
## Fallback target stock for commodities _target_stock() can't derive from
## demand -- cattle and sheep are herd capital (bred and held), not consumed
## at a daily rate by anything this model tracks. Also still used as-is by
## _run_trade's export reserve, which stays a flat per-commodity floor.
const REFERENCE_STOCK: Dictionary[Commodity.Type, float] = {
	Commodity.Type.GRAIN: 2000.0,
	Commodity.Type.CATTLE: 200.0,
	Commodity.Type.SHEEP: 400.0,
	Commodity.Type.WOOL: 500.0,
	Commodity.Type.TIMBER: 500.0,
	Commodity.Type.CHARCOAL: 300.0,
	Commodity.Type.IRON: 150.0,
	Commodity.Type.TOOLS: 100.0,
}
const PRICE_MULTIPLIER_MIN := 0.5
const PRICE_MULTIPLIER_MAX := 4.0
## Days of expected demand a settlement's price target holds as buffer --
## the knob that turns a daily flow rate into a target stock.
const PRICE_BUFFER_DAYS := 30.0

## A settlement won't export a commodity below this fraction of its own
## reference stock (keeps some at home rather than trading itself bare),
## and won't send more than this fraction of what's left above that in one
## shipment.
const TRADE_EVAL_INTERVAL_DAYS := 7
const TRADE_RESERVE_FRACTION_OF_REFERENCE := 0.5
const TRADE_MAX_SHIPMENT_FRACTION_OF_SURPLUS := 0.5
const TRADE_MIN_PROFITABLE_PRICE_GAP := 0.5

var settlements: Dictionary[int, Settlement] = {}
var households: Dictionary[int, Household] = {}
var workplaces: Dictionary[int, Workplace] = {}
var transport_edges: Dictionary[int, TransportEdge] = {}
var shipments: Dictionary[int, Shipment] = {}

var rng: RandomNumberGenerator
var day: int = 0
var year: int = 0
var _next_shipment_id := 1

var _history: Dictionary[int, Array] = {} # settlement_id -> Array[Dictionary], oldest first, capped at HISTORY_MAX_DAYS

var _migration_pressure_count: Dictionary = {} # settlement_id -> int, recomputed weekly
var _starvation_deaths_recent: Dictionary = {} # settlement_id -> int, recomputed monthly
var _starvation_deaths_total: Dictionary = {} # settlement_id -> int, lifetime
var _shipments_delivered_total: Dictionary = {} # settlement_id (destination) -> int, lifetime
var _low_population_days: Dictionary = {} # settlement_id -> consecutive days below COLLAPSE_HOUSEHOLD_THRESHOLD
var _game_over_info: Dictionary = {} # empty until the player's holding collapses

func _init(seed: int, valley_builder: Callable = Callable()) -> void:
	rng = RandomNumberGenerator.new()
	rng.seed = seed
	var builder := valley_builder if valley_builder.is_valid() else Callable(ValleySeed, "build_default_valley")
	var valley: Dictionary = builder.call(rng)
	settlements = valley["settlements"]
	households = valley["households"]
	workplaces = valley["workplaces"]
	transport_edges = valley.get("transport_edges", {})
	for settlement_id in settlements.keys():
		_history[settlement_id] = []

func season() -> Season:
	return ((day / DAYS_PER_SEASON) % SEASONS_PER_YEAR) as Season

func advance_ticks(days: int) -> void:
	for i in days:
		if not _game_over_info.is_empty():
			return
		_daily_tick()
		day += 1

# ---------------------------------------------------------------------------
# Public query contract
# ---------------------------------------------------------------------------

func get_settlement_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(settlements.keys())
	return ids

func get_clock_summary() -> Dictionary:
	var s := season()
	return {
		"day": day,
		"year": year,
		"season": s,
		"season_name": SEASON_NAMES[s],
	}

func get_settlement_summary(settlement_id: int) -> Dictionary:
	var settlement: Settlement = settlements[settlement_id]
	var record := _latest_record(settlement_id)
	var grain_name := Commodity.name_of(Commodity.Type.GRAIN)

	var inventory := {}
	for c in Commodity.ALL:
		inventory[Commodity.name_of(c)] = settlement.stock(c)

	var population := _live_population(settlement_id)
	var year_ago_population := population
	var history: Array = _history.get(settlement_id, [])
	if history.size() >= DAYS_PER_YEAR:
		year_ago_population = history[history.size() - DAYS_PER_YEAR]["population"]

	return {
		"id": settlement.id,
		"name": settlement.name,
		"is_player_holding": settlement.is_player_holding,
		"household_count": settlement.household_ids.size(),
		"population": population,
		"population_year_ago": year_ago_population,
		"available_workers": _live_available_workers(settlement_id),
		"assigned_workers": record.get("assigned_workers", 0.0),
		"avg_food_stress": _avg_food_stress(settlement_id),
		"migration_pressure_count": _migration_pressure_count.get(settlement_id, 0),
		"starvation_deaths_recent": _starvation_deaths_recent.get(settlement_id, 0),
		"starvation_deaths_total": _starvation_deaths_total.get(settlement_id, 0),
		"shipments_received_total": _shipments_delivered_total.get(settlement_id, 0),
		"status": _settlement_status(settlement_id),
		"inventory": inventory,
		# .duplicate() -- record.get(...) below, once history is non-empty, IS
		# the live object stored in _history (see _latest_record). Without
		# copying, a caller mutating these would corrupt simulation state.
		"produced_today": (record.get("produced", {}) as Dictionary).duplicate(),
		"household_consumption_today": (record.get("household_consumption", {}) as Dictionary).duplicate(),
		"industrial_consumption_today": (record.get("industrial_consumption", {}) as Dictionary).duplicate(),
		"unmet_household_demand_today": (record.get("unmet_household_demand", {}) as Dictionary).duplicate(),
		"unmet_industrial_demand_today": (record.get("unmet_industrial_demand", {}) as Dictionary).duplicate(),
		"grain_fulfillment_today": _fulfillment_ratio(record, grain_name),
		"grain_fulfillment_rolling_30d": _rolling_fulfillment_ratio(settlement_id, grain_name, 30),
	}

## Up to the last `days` daily balance records for this settlement, oldest
## first. Each is an immutable snapshot (deep-copied) -- mutating the
## returned data cannot affect the simulation.
func get_settlement_history(settlement_id: int, days: int) -> Array:
	var history: Array = _history.get(settlement_id, [])
	var start: int = max(0, history.size() - days)
	var out: Array = []
	for i in range(start, history.size()):
		out.append((history[i] as Dictionary).duplicate(true))
	return out

## One report per workplace in this settlement: target/actual labor, planned/
## actual units, utilization, requested/consumed inputs, produced outputs,
## and the limiting input (if any). This is where a stalled bloomery shows
## up -- settlement-level unmet demand only tracks household/herd
## consumption, not a workplace quietly throttling itself for lack of input.
func get_workplace_reports(settlement_id: int) -> Array:
	var out: Array = []
	for workplace_id in (settlements[settlement_id] as Settlement).workplace_ids:
		var w: Workplace = workplaces[workplace_id]
		out.append({
			"workplace_id": w.id,
			"settlement_id": w.settlement_id,
			"kind": w.kind_name(),
			"recipe_id": w.recipe.id,
			"target_labor": w.target_labor,
			"actual_labor": w.actual_labor,
			"planned_units": w.last_planned_units,
			"actual_units": w.last_actual_units,
			"utilization_ratio": w.last_utilization_ratio,
			"limiting_input": w.last_limiting_input,
			"input_requested": w.last_input_requested.duplicate(),
			"input_consumed": w.last_input_consumed.duplicate(),
			"output_produced": w.last_output_produced.duplicate(),
		})
	return out

## Per-commodity price for this settlement, derived from local scarcity
## (see BASE_PRICE/REFERENCE_STOCK). Not a full market clearing -- a simple,
## explainable stand-in for Milestone 1.
func get_settlement_prices(settlement_id: int) -> Dictionary:
	var settlement: Settlement = settlements[settlement_id]
	var prices := {}
	for c in Commodity.ALL:
		prices[Commodity.name_of(c)] = _price_for(settlement, c)
	return prices

func get_transport_edge_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(transport_edges.keys())
	return ids

func get_transport_edge_summary(edge_id: int) -> Dictionary:
	var edge: TransportEdge = transport_edges[edge_id]
	return {
		"id": edge.id,
		"settlement_a_id": edge.settlement_a_id,
		"settlement_a_name": (settlements[edge.settlement_a_id] as Settlement).name,
		"settlement_b_id": edge.settlement_b_id,
		"settlement_b_name": (settlements[edge.settlement_b_id] as Settlement).name,
		"mode": edge.mode,
		"capacity": edge.capacity,
		"toll": edge.toll,
		"risk": edge.risk,
		"travel_time_days_a_to_b": edge.travel_time_days_a_to_b,
		"travel_time_days_b_to_a": edge.travel_time_days_b_to_a,
	}

## All shipments not yet arrived, oldest first. progress_fraction is 0.0 at
## departure, 1.0 on arrival -- what a graphical route display would
## interpolate a moving marker along.
func get_active_shipments() -> Array:
	var out: Array = []
	var ids := shipments.keys()
	ids.sort()
	for shipment_id in ids:
		var s: Shipment = shipments[shipment_id]
		out.append({
			"id": s.id,
			"commodity": s.commodity,
			"quantity": s.quantity,
			"origin_settlement_id": s.origin_settlement_id,
			"origin_name": (settlements[s.origin_settlement_id] as Settlement).name,
			"destination_settlement_id": s.destination_settlement_id,
			"destination_name": (settlements[s.destination_settlement_id] as Settlement).name,
			"origin_trade_center_workplace_id": s.origin_trade_center_workplace_id,
			"edge_id": s.edge_id,
			"departure_day": s.departure_day,
			"arrival_day": s.arrival_day,
			"days_remaining": max(0, s.arrival_day - day),
			"progress_fraction": s.progress_fraction(day),
		})
	return out

## Empty until the player's holding (Settlement.is_player_holding) has had
## fewer than COLLAPSE_HOUSEHOLD_THRESHOLD households for
## COLLAPSE_SUSTAINED_DAYS in a row. Once set, advance_ticks() stops
## simulating -- the run is over.
func get_game_over_info() -> Dictionary:
	return _game_over_info.duplicate(true)

# ---------------------------------------------------------------------------
# Daily tick, in the order documented in Milestone 0.75 (extended in
# Milestone 1 with trade):
#   1. reset daily flow records
#   2. resolve shipments arriving today (goods show up before the day's
#      business, so they're available to meet today's demand)
#   3. allocate available settlement labor to workplaces
#   4. run workplace production, record industrial flows
#   5. run household consumption, record fulfillment
#   6. (weekly) decide and depart new shipments, based on today's stock
#   7. weekly/monthly household evaluations (migration pressure, starvation --
#      before finalizing, so a starvation death this same day is reflected
#      in the record about to be appended, not the day after)
#   8. finalize closing balances (re-synced population included), append
#      history, then check collapse/game-over, then advance the calendar
# ---------------------------------------------------------------------------

func _daily_tick() -> void:
	var records := {}
	for settlement_id in settlements.keys():
		records[settlement_id] = _new_daily_record(settlement_id)

	_resolve_shipment_arrivals(records)
	_allocate_labor()
	_run_production(records)
	_run_consumption(records)

	if (day + 1) % TRADE_EVAL_INTERVAL_DAYS == 0:
		_run_trade(records)

	# Seasonal herd effects land on the day that crosses into a new season,
	# folded into that same day's record rather than an orphaned gap between
	# ticks (a season boundary is when (day + 1) is a multiple of
	# DAYS_PER_SEASON, i.e. the day we're about to finish completes it).
	if (day + 1) % DAYS_PER_SEASON == 0:
		_run_seasonal_herds(records)

	if (day + 1) % MIGRATION_PRESSURE_EVAL_INTERVAL_DAYS == 0:
		_evaluate_migration_pressure()
	if (day + 1) % STARVATION_EVAL_INTERVAL_DAYS == 0:
		_evaluate_starvation()

	_finalize_daily_records(records)
	_evaluate_collapse_and_game_over()

	if (day + 1) % DAYS_PER_YEAR == 0:
		year += 1

func _new_daily_record(settlement_id: int) -> Dictionary:
	return {
		"day": day,
		"opening_stock": _snapshot_stock(settlement_id),
		"produced": {},
		"household_consumption": {},
		"industrial_consumption": {},
		"household_demand": {},
		"unmet_household_demand": {},
		"industrial_demand": {},
		"unmet_industrial_demand": {},
		"trade_in": {},
		"trade_out": {},
		"assigned_workers": 0.0,
		"population": 0,
	}

func _snapshot_stock(settlement_id: int) -> Dictionary:
	var settlement: Settlement = settlements[settlement_id]
	var snap := {}
	for c in Commodity.ALL:
		snap[Commodity.name_of(c)] = settlement.stock(c)
	return snap

## Step 2: each workplace's target_labor is authored capacity (including the
## implicit land/facility limit); actual_labor is capped by the settlement's
## real workforce, split proportionally across workplaces when the
## settlement doesn't have enough workers to staff everyone at target.
func _allocate_labor() -> void:
	for settlement_id in settlements.keys():
		var settlement: Settlement = settlements[settlement_id]
		var available_workers: float = _live_available_workers(settlement_id)
		var workplace_ids := settlement.workplace_ids.duplicate()
		workplace_ids.sort()

		var total_target := 0.0
		for workplace_id in workplace_ids:
			total_target += (workplaces[workplace_id] as Workplace).target_labor

		var scale: float = 1.0 if total_target <= available_workers or total_target <= 0.0 else available_workers / total_target
		for workplace_id in workplace_ids:
			(workplaces[workplace_id] as Workplace).actual_labor = (workplaces[workplace_id] as Workplace).target_labor * scale

func _run_production(records: Dictionary) -> void:
	var s := season()
	for workplace_id in workplaces.keys():
		var workplace: Workplace = workplaces[workplace_id]
		if workplace.kind == Workplace.Kind.TRADE_CENTER:
			workplace.last_planned_units = 0.0
			workplace.last_actual_units = 0.0
			workplace.last_limiting_input = null
			workplace.last_input_requested = {}
			workplace.last_input_consumed = {}
			workplace.last_output_produced = {}
			workplace.last_utilization_ratio = 1.0
			records[workplace.settlement_id]["assigned_workers"] += workplace.actual_labor
			continue
		var settlement: Settlement = settlements[workplace.settlement_id]
		var recipe := workplace.recipe
		var record: Dictionary = records[workplace.settlement_id]

		var planned_units: float = workplace.actual_labor * recipe.seasonal_modifiers[s]
		var actual_units := planned_units
		var limiting_input = null
		for commodity in recipe.inputs.keys():
			var rate: float = recipe.inputs[commodity]
			if rate <= 0.0:
				continue
			var affordable: float = settlement.stock(commodity) / rate
			if affordable < actual_units:
				actual_units = affordable
				limiting_input = commodity
		actual_units = max(actual_units, 0.0)

		var input_requested := {}
		var input_consumed := {}
		for commodity in recipe.inputs.keys():
			var name := Commodity.name_of(commodity)
			var requested: float = recipe.inputs[commodity] * planned_units
			var consumed: float = recipe.inputs[commodity] * actual_units
			settlement.consume(commodity, consumed)
			input_requested[commodity] = requested
			input_consumed[commodity] = consumed
			record["industrial_demand"][name] = record["industrial_demand"].get(name, 0.0) + requested
			record["industrial_consumption"][name] = record["industrial_consumption"].get(name, 0.0) + consumed
			record["unmet_industrial_demand"][name] = record["unmet_industrial_demand"].get(name, 0.0) + (requested - consumed)

		var output_produced := {}
		for commodity in recipe.outputs.keys():
			var name := Commodity.name_of(commodity)
			var amount: float = recipe.outputs[commodity] * actual_units
			settlement.add_stock(commodity, amount)
			output_produced[commodity] = amount
			record["produced"][name] = record["produced"].get(name, 0.0) + amount

		workplace.last_planned_units = planned_units
		workplace.last_actual_units = actual_units
		workplace.last_limiting_input = limiting_input
		workplace.last_input_requested = input_requested
		workplace.last_input_consumed = input_consumed
		workplace.last_output_produced = output_produced
		workplace.last_utilization_ratio = (actual_units / planned_units) if planned_units > 0.0 else 1.0

		record["assigned_workers"] += workplace.actual_labor

## Step 4: grain demand/consumption is aggregated once at the settlement
## level, then the resulting fulfillment ratio is applied uniformly to every
## resident household -- no per-household rationing/inventory in this
## milestone. Wool/tools consumption is still tracked for the daily record
## but doesn't feed household food stress (that's specifically food security).
func _run_consumption(records: Dictionary) -> void:
	var grain_name := Commodity.name_of(Commodity.Type.GRAIN)
	for settlement_id in settlements.keys():
		var settlement: Settlement = settlements[settlement_id]
		var record: Dictionary = records[settlement_id]
		var population: float = _live_population(settlement_id)
		record["population"] = int(population)

		var grain_demand := population * GRAIN_PER_PERSON_PER_DAY
		var grain_taken := settlement.consume(Commodity.Type.GRAIN, grain_demand)
		var fulfillment := (grain_taken / grain_demand) if grain_demand > 0.0 else 1.0
		_record_household_flow(record, grain_name, grain_demand, grain_taken)

		var wool_demand := population * WOOL_PER_PERSON_PER_DAY
		_record_household_flow(record, Commodity.name_of(Commodity.Type.WOOL), wool_demand, settlement.consume(Commodity.Type.WOOL, wool_demand))

		var tools_demand := population * TOOLS_PER_PERSON_PER_DAY
		_record_household_flow(record, Commodity.name_of(Commodity.Type.TOOLS), tools_demand, settlement.consume(Commodity.Type.TOOLS, tools_demand))

		# Rolling (not today's raw) ratio drives eligibility -- see
		# Household.apply_daily_fulfillment for why. This trails by one day
		# (today's record isn't finalized/appended to history yet), which is
		# fine for a 30-day smoothing window.
		var rolling_ratio := _rolling_fulfillment_ratio(settlement_id, grain_name, 30)
		var rolling_is_low := rolling_ratio < Household.MIGRATION_PRESSURE_FULFILLMENT_THRESHOLD
		var rolling_is_severe := rolling_ratio < Household.STARVATION_FULFILLMENT_THRESHOLD
		for household_id in settlement.household_ids:
			(households[household_id] as Household).apply_daily_fulfillment(fulfillment, rolling_is_low, rolling_is_severe)

func _record_household_flow(record: Dictionary, commodity_name: String, demand: float, taken: float) -> void:
	record["household_demand"][commodity_name] = demand
	record["household_consumption"][commodity_name] = taken
	record["unmet_household_demand"][commodity_name] = demand - taken

func _run_seasonal_herds(records: Dictionary) -> void:
	var grain_name := Commodity.name_of(Commodity.Type.GRAIN)
	for settlement_id in settlements.keys():
		var settlement: Settlement = settlements[settlement_id]
		var record: Dictionary = records[settlement_id]
		for herd_commodity in [Commodity.Type.CATTLE, Commodity.Type.SHEEP]:
			var head := settlement.stock(herd_commodity)
			if head <= 0.0:
				continue
			var new_head: float
			if season() == Season.WINTER:
				var fodder_needed := head * FODDER_PER_HEAD_PER_SEASON
				var fodder_available := settlement.stock(Commodity.Type.GRAIN)
				var fed := fodder_available >= fodder_needed
				var fodder_consumed: float = min(fodder_available, fodder_needed)
				settlement.consume(Commodity.Type.GRAIN, fodder_consumed)
				record["industrial_demand"][grain_name] = record["industrial_demand"].get(grain_name, 0.0) + fodder_needed
				record["industrial_consumption"][grain_name] = record["industrial_consumption"].get(grain_name, 0.0) + fodder_consumed
				record["unmet_industrial_demand"][grain_name] = record["unmet_industrial_demand"].get(grain_name, 0.0) + (fodder_needed - fodder_consumed)
				var loss_rate := WINTER_LOSS_RATE_FED if fed else WINTER_LOSS_RATE_STARVED
				new_head = head * (1.0 - loss_rate)
			else:
				new_head = min(head * (1.0 + HERD_GROWTH_RATE), HERD_HARD_CEILING)
			var delta := new_head - head
			settlement.add_stock(herd_commodity, delta)
			var name := Commodity.name_of(herd_commodity)
			record["produced"][name] = record["produced"].get(name, 0.0) + delta

## Step 2: deliver any shipment whose arrival_day is today, before the day's
## production/consumption runs.
func _resolve_shipment_arrivals(records: Dictionary) -> void:
	var arrived: Array[int] = []
	for shipment_id in shipments.keys():
		var s: Shipment = shipments[shipment_id]
		if s.arrival_day > day:
			continue
		var destination: Settlement = settlements[s.destination_settlement_id]
		destination.add_stock(s.commodity, s.quantity)
		var name := Commodity.name_of(s.commodity)
		var record: Dictionary = records[s.destination_settlement_id]
		record["trade_in"][name] = record["trade_in"].get(name, 0.0) + s.quantity
		_shipments_delivered_total[s.destination_settlement_id] = _shipments_delivered_total.get(s.destination_settlement_id, 0) + 1
		arrived.append(shipment_id)
	for shipment_id in arrived:
		shipments.erase(shipment_id)

## Step 6 (weekly): every staffed trade center proposes exports from its home
## settlement to directly connected neighbors. Capacity arbitration remains
## a property of the edge itself (the road/river, not the trader), so it is
## shared across commodities and both directions for the period. This is not
## a monetary market: prices, toll, and risk remain routing signals.
## (Future: commodities could consume capacity at different rates -- a
## cattle drive isn't a sack of grain. Not implemented yet.)
func _run_trade(records: Dictionary) -> void:
	var offers_by_edge: Dictionary = {}
	var workplace_ids := workplaces.keys()
	workplace_ids.sort()
	var edge_ids := transport_edges.keys()
	edge_ids.sort()

	# Centers know only their immediate neighbors. A center can dispatch only
	# when its own settlement is the cheaper/source side of the opportunity.
	for workplace_id in workplace_ids:
		var trade_center: Workplace = workplaces[workplace_id]
		if trade_center.kind != Workplace.Kind.TRADE_CENTER or trade_center.actual_labor <= 0.01:
			continue
		var source: Settlement = settlements[trade_center.settlement_id]
		var staffing_ratio: float = clamp(trade_center.actual_labor / trade_center.target_labor, 0.0, 1.0) if trade_center.target_labor > 0.0 else 0.0
		for edge_id in edge_ids:
			var edge: TransportEdge = transport_edges[edge_id]
			if not edge.connects(source.id):
				continue
			var dest_id := edge.other_end(source.id)
			var destination: Settlement = settlements[dest_id]
			var edge_offers: Array = offers_by_edge.get(edge_id, [])
			for c in Commodity.ALL:
				var source_price := _price_for(source, c)
				var destination_price := _price_for(destination, c)
				if source_price >= destination_price:
					continue
				var net_gap: float = destination_price - source_price - (edge.toll + edge.risk * 2.0)
				if net_gap < TRADE_MIN_PROFITABLE_PRICE_GAP:
					continue
				var reserve: float = REFERENCE_STOCK[c] * TRADE_RESERVE_FRACTION_OF_REFERENCE
				var exportable: float = max(0.0, source.stock(c) - reserve) * TRADE_MAX_SHIPMENT_FRACTION_OF_SURPLUS * staffing_ratio
				if exportable <= 0.01:
					continue
				edge_offers.append({
					"commodity": c,
					"source_id": source.id,
					"dest_id": dest_id,
					"trade_center_id": trade_center.id,
					"staffing_ratio": staffing_ratio,
					"net_gap": net_gap,
				})
			offers_by_edge[edge_id] = edge_offers

	# The allocator is physical route contention, not a global merchant. It
	# ranks independently-created center offers and never creates an offer.
	for edge_id in edge_ids:
		var edge: TransportEdge = transport_edges[edge_id]
		var opportunities: Array = offers_by_edge.get(edge_id, [])
		opportunities.sort_custom(func(a, b):
			if not is_equal_approx(a["net_gap"], b["net_gap"]):
				return a["net_gap"] > b["net_gap"]
			if a["commodity"] != b["commodity"]:
				return a["commodity"] < b["commodity"]
			return a["trade_center_id"] < b["trade_center_id"]
		)

		var remaining_capacity: float = edge.capacity
		for opportunity in opportunities:
			if remaining_capacity <= 0.01:
				break
			var c: Commodity.Type = opportunity["commodity"]
			var source_id: int = opportunity["source_id"]
			var source: Settlement = settlements[source_id]
			# Recompute against live stock because one center may export over
			# several edges during the same weekly planning pass.
			var reserve: float = REFERENCE_STOCK[c] * TRADE_RESERVE_FRACTION_OF_REFERENCE
			var exportable: float = max(0.0, source.stock(c) - reserve) * TRADE_MAX_SHIPMENT_FRACTION_OF_SURPLUS * opportunity["staffing_ratio"]
			var quantity: float = min(exportable, remaining_capacity)
			if quantity <= 0.01:
				continue

			source.consume(c, quantity)
			var name := Commodity.name_of(c)
			var record: Dictionary = records[source_id]
			record["trade_out"][name] = record["trade_out"].get(name, 0.0) + quantity

			var dest_id: int = opportunity["dest_id"]
			var travel_days: float = edge.travel_time_days(source_id)
			var shipment := Shipment.new(_next_shipment_id, c, quantity, source_id, dest_id, opportunity["trade_center_id"], edge.id, day, day + ceili(travel_days))
			shipments[shipment.id] = shipment
			_next_shipment_id += 1
			remaining_capacity -= quantity

func _finalize_daily_records(records: Dictionary) -> void:
	for settlement_id in settlements.keys():
		var record: Dictionary = records[settlement_id]
		# Re-sync now, after this same day's starvation evaluation may have
		# removed/shrunk households -- record["population"] was set earlier
		# in _run_consumption, before that happened.
		record["population"] = _live_population(settlement_id)
		record["closing_stock"] = _snapshot_stock(settlement_id)
		var history: Array = _history[settlement_id]
		history.append(record)
		if history.size() > HISTORY_MAX_DAYS:
			history.pop_front()

func _evaluate_migration_pressure() -> void:
	for settlement_id in settlements.keys():
		var settlement: Settlement = settlements[settlement_id]
		var ids := settlement.household_ids.duplicate()
		ids.sort()
		var count := 0
		for household_id in ids:
			var h: Household = households[household_id]
			h.update_migration_pressure()
			if h.has_migration_pressure:
				count += 1
		_migration_pressure_count[settlement_id] = count

func _evaluate_starvation() -> void:
	for settlement_id in settlements.keys():
		var settlement: Settlement = settlements[settlement_id]
		var ids := settlement.household_ids.duplicate()
		ids.sort()
		var deaths := 0
		var to_remove: Array[int] = []
		for household_id in ids:
			var h: Household = households[household_id]
			if h.is_starvation_candidate():
				h.remove_member()
				deaths += 1
				if h.is_empty():
					to_remove.append(household_id)
		for household_id in to_remove:
			settlement.household_ids.erase(household_id)
			households.erase(household_id)
		_starvation_deaths_recent[settlement_id] = deaths
		_starvation_deaths_total[settlement_id] = _starvation_deaths_total.get(settlement_id, 0) + deaths

func _evaluate_collapse_and_game_over() -> void:
	for settlement_id in settlements.keys():
		var settlement: Settlement = settlements[settlement_id]
		if not settlement.is_player_holding:
			continue
		if settlement.household_ids.size() < COLLAPSE_HOUSEHOLD_THRESHOLD:
			_low_population_days[settlement_id] = _low_population_days.get(settlement_id, 0) + 1
		else:
			_low_population_days[settlement_id] = 0
		if _game_over_info.is_empty() and _low_population_days.get(settlement_id, 0) >= COLLAPSE_SUSTAINED_DAYS:
			_trigger_game_over(settlement_id)

func _trigger_game_over(settlement_id: int) -> void:
	var settlement: Settlement = settlements[settlement_id]
	var grain_name := Commodity.name_of(Commodity.Type.GRAIN)
	var avg_fulfillment := _rolling_fulfillment_ratio(settlement_id, grain_name, 30) * 100.0
	_game_over_info = {
		"day": day,
		"year": year,
		"settlement_id": settlement_id,
		"settlement_name": settlement.name,
		"summary": "%s collapsed on day %d (year %d): grain fulfillment averaged %.0f%% over the final 30 days; %d households were under sustained migration pressure (relocation not yet possible) and %d people died of starvation." % [
			settlement.name, day, year, avg_fulfillment,
			_migration_pressure_count.get(settlement_id, 0),
			_starvation_deaths_total.get(settlement_id, 0),
		],
	}

# ---------------------------------------------------------------------------
# Derived-state helpers (population/workforce are always computed from the
# authoritative household records, never cached, so a starvation death is
# immediately reflected everywhere).
# ---------------------------------------------------------------------------

func _live_population(settlement_id: int) -> int:
	var total := 0
	for household_id in (settlements[settlement_id] as Settlement).household_ids:
		total += (households[household_id] as Household).headcount()
	return total

func _live_available_workers(settlement_id: int) -> int:
	var total := 0
	for household_id in (settlements[settlement_id] as Settlement).household_ids:
		total += (households[household_id] as Household).worker_capacity
	return total

func _avg_food_stress(settlement_id: int) -> float:
	var ids := (settlements[settlement_id] as Settlement).household_ids
	if ids.is_empty():
		return 0.0
	var total := 0.0
	for household_id in ids:
		total += (households[household_id] as Household).food_stress
	return total / ids.size()

func _price_for(settlement: Settlement, commodity: Commodity.Type) -> float:
	var target: float = _target_stock(settlement, commodity)
	var stock: float = max(settlement.stock(commodity), 0.01)
	var multiplier: float = clamp(target / stock, PRICE_MULTIPLIER_MIN, PRICE_MULTIPLIER_MAX)
	return BASE_PRICE[commodity] * multiplier

## This settlement's target stock for `commodity`: expected household demand
## plus expected industrial (workplace input) demand, each held for
## PRICE_BUFFER_DAYS, plus any lump seasonal commitment (winter fodder).
## Falls back to REFERENCE_STOCK when nothing here actually consumes the
## commodity as a flow (cattle/sheep are herd capital, not a rate).
func _target_stock(settlement: Settlement, commodity: Commodity.Type) -> float:
	var daily_demand: float = _expected_household_demand_per_day(settlement, commodity) \
		+ _expected_industrial_demand_per_day(settlement, commodity)
	var target: float = daily_demand * PRICE_BUFFER_DAYS + _seasonal_commitment(settlement, commodity)
	return target if target > 0.0 else REFERENCE_STOCK[commodity]

## Grain/wool/tools are the only commodities households draw on directly
## (see _run_consumption) -- mirrors those per-person rates so the price
## target tracks the same demand the tick loop actually enforces.
func _expected_household_demand_per_day(settlement: Settlement, commodity: Commodity.Type) -> float:
	var population: float = _live_population(settlement.id)
	match commodity:
		Commodity.Type.GRAIN:
			return population * GRAIN_PER_PERSON_PER_DAY
		Commodity.Type.WOOL:
			return population * WOOL_PER_PERSON_PER_DAY
		Commodity.Type.TOOLS:
			return population * TOOLS_PER_PERSON_PER_DAY
	return 0.0

## Sum of this settlement's own workplaces' authored demand for `commodity`
## as a recipe input, at the current season's output modifier. Uses
## target_labor rather than the labor-constrained actual_labor so the price
## target reflects designed capacity, not this tick's staffing shortfall.
func _expected_industrial_demand_per_day(settlement: Settlement, commodity: Commodity.Type) -> float:
	var s := season()
	var total := 0.0
	for workplace_id in settlement.workplace_ids:
		var workplace: Workplace = workplaces[workplace_id]
		if workplace.kind != Workplace.Kind.PRODUCTION:
			continue
		var rate: float = workplace.recipe.inputs.get(commodity, 0.0)
		if rate <= 0.0:
			continue
		total += rate * workplace.target_labor * workplace.recipe.seasonal_modifiers[s]
	return total

## Lump addition to grain's target stock for this settlement's current
## herd's full winter fodder need. Held year-round (not scaled by season) so
## the price signal builds ahead of winter instead of only reacting once
## herds are already being fed down.
func _seasonal_commitment(settlement: Settlement, commodity: Commodity.Type) -> float:
	if commodity != Commodity.Type.GRAIN:
		return 0.0
	var herd_head: float = settlement.stock(Commodity.Type.CATTLE) + settlement.stock(Commodity.Type.SHEEP)
	return herd_head * FODDER_PER_HEAD_PER_SEASON

func _latest_record(settlement_id: int) -> Dictionary:
	var history: Array = _history.get(settlement_id, [])
	return history[-1] if not history.is_empty() else _new_daily_record(settlement_id)

func _fulfillment_ratio(record: Dictionary, commodity_name: String) -> float:
	var demand: float = record.get("household_demand", {}).get(commodity_name, 0.0)
	var taken: float = record.get("household_consumption", {}).get(commodity_name, 0.0)
	return (taken / demand) if demand > 0.0 else 1.0

func _rolling_fulfillment_ratio(settlement_id: int, commodity_name: String, num_days: int) -> float:
	var history: Array = _history.get(settlement_id, [])
	var start: int = max(0, history.size() - num_days)
	var demand_total := 0.0
	var taken_total := 0.0
	for i in range(start, history.size()):
		var record: Dictionary = history[i]
		demand_total += (record["household_demand"] as Dictionary).get(commodity_name, 0.0)
		taken_total += (record["household_consumption"] as Dictionary).get(commodity_name, 0.0)
	return (taken_total / demand_total) if demand_total > 0.0 else 1.0

func _settlement_status(settlement_id: int) -> String:
	var settlement: Settlement = settlements[settlement_id]
	if settlement.household_ids.is_empty():
		return "collapsed"
	var history: Array = _history.get(settlement_id, [])
	if history.size() >= 30:
		var population_now := _live_population(settlement_id)
		var population_30_ago: int = history[history.size() - 30]["population"]
		if population_now < population_30_ago:
			return "contracting"
	var grain_name := Commodity.name_of(Commodity.Type.GRAIN)
	if _rolling_fulfillment_ratio(settlement_id, grain_name, 30) < 0.95:
		return "food_insecure"
	return "stable"
