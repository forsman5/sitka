class_name Simulation
extends RefCounted

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Household = preload("res://scripts/sim/records/household.gd")
const Settlement = preload("res://scripts/sim/records/settlement.gd")
const Workplace = preload("res://scripts/sim/records/workplace.gd")
const TransportEdge = preload("res://scripts/sim/records/transport_edge.gd")
const ValleySeed = preload("res://scripts/sim/data/valley_seed.gd")

## Deterministic, tick-based economic simulation over plain-data records.
## Advanced only through advance_ticks(); nothing here reads or writes the
## scene tree. See docs/river-valley-vertical-slice.md sections 3-4 and
## Milestones 0.75/0.76.
##
## API boundary (Milestone 0.75): callers use these query methods only, never
## the settlements/households/workplaces Dictionaries directly. Returned
## dictionaries/arrays are snapshots and cannot mutate simulation state:
##   get_settlement_ids(), get_clock_summary(), get_settlement_summary(id),
##   get_settlement_history(id, days), get_workplace_reports(id),
##   get_game_over_info()

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
const EMIGRATION_EVAL_INTERVAL_DAYS := 7
const STARVATION_EVAL_INTERVAL_DAYS := 30
const COLLAPSE_HOUSEHOLD_THRESHOLD := 5
const COLLAPSE_SUSTAINED_DAYS := 30

var settlements: Dictionary[int, Settlement] = {}
var households: Dictionary[int, Household] = {}
var workplaces: Dictionary[int, Workplace] = {}
var transport_edges: Dictionary[int, TransportEdge] = {}

var rng: RandomNumberGenerator
var day: int = 0
var year: int = 0

var _history: Dictionary[int, Array] = {} # settlement_id -> Array[Dictionary], oldest first, capped at HISTORY_MAX_DAYS

var _emigration_desire_count: Dictionary = {} # settlement_id -> int, recomputed weekly
var _starvation_deaths_recent: Dictionary = {} # settlement_id -> int, recomputed monthly
var _starvation_deaths_total: Dictionary = {} # settlement_id -> int, lifetime
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
		"emigration_desire_count": _emigration_desire_count.get(settlement_id, 0),
		"starvation_deaths_recent": _starvation_deaths_recent.get(settlement_id, 0),
		"starvation_deaths_total": _starvation_deaths_total.get(settlement_id, 0),
		"status": _settlement_status(settlement_id),
		"inventory": inventory,
		"produced_today": record.get("produced", {}),
		"household_consumption_today": record.get("household_consumption", {}),
		"industrial_consumption_today": record.get("industrial_consumption", {}),
		"unmet_household_demand_today": record.get("unmet_household_demand", {}),
		"unmet_industrial_demand_today": record.get("unmet_industrial_demand", {}),
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
			"recipe_id": w.recipe.id,
			"target_labor": w.target_labor,
			"actual_labor": w.actual_labor,
			"planned_units": w.last_planned_units,
			"actual_units": w.last_actual_units,
			"utilization_ratio": w.last_utilization_ratio,
			"limiting_input": w.last_limiting_input,
			"input_consumed": w.last_input_consumed.duplicate(),
			"output_produced": w.last_output_produced.duplicate(),
		})
	return out

## Empty until the player's holding (Settlement.is_player_holding) has had
## fewer than COLLAPSE_HOUSEHOLD_THRESHOLD households for
## COLLAPSE_SUSTAINED_DAYS in a row. Once set, advance_ticks() stops
## simulating -- the run is over.
func get_game_over_info() -> Dictionary:
	return _game_over_info.duplicate(true)

# ---------------------------------------------------------------------------
# Daily tick, in the order documented in Milestone 0.75:
#   1. reset daily flow records
#   2. allocate available settlement labor to workplaces
#   3. run workplace production, record industrial flows
#   4. run household consumption, record fulfillment
#   5. finalize closing balances, append history
#   6. weekly/monthly household evaluations, collapse check, calendar
# ---------------------------------------------------------------------------

func _daily_tick() -> void:
	var records := {}
	for settlement_id in settlements.keys():
		records[settlement_id] = _new_daily_record(settlement_id)

	_allocate_labor()
	_run_production(records)
	_run_consumption(records)

	# Seasonal herd effects land on the day that crosses into a new season,
	# folded into that same day's record rather than an orphaned gap between
	# ticks (a season boundary is when (day + 1) is a multiple of
	# DAYS_PER_SEASON, i.e. the day we're about to finish completes it).
	if (day + 1) % DAYS_PER_SEASON == 0:
		_run_seasonal_herds(records)

	_finalize_daily_records(records)

	if (day + 1) % EMIGRATION_EVAL_INTERVAL_DAYS == 0:
		_evaluate_emigration_desire()
	if (day + 1) % STARVATION_EVAL_INTERVAL_DAYS == 0:
		_evaluate_starvation()
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

		for household_id in settlement.household_ids:
			(households[household_id] as Household).apply_daily_fulfillment(fulfillment)

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

func _finalize_daily_records(records: Dictionary) -> void:
	for settlement_id in settlements.keys():
		var record: Dictionary = records[settlement_id]
		record["closing_stock"] = _snapshot_stock(settlement_id)
		var history: Array = _history[settlement_id]
		history.append(record)
		if history.size() > HISTORY_MAX_DAYS:
			history.pop_front()

func _evaluate_emigration_desire() -> void:
	for settlement_id in settlements.keys():
		var settlement: Settlement = settlements[settlement_id]
		var ids := settlement.household_ids.duplicate()
		ids.sort()
		var count := 0
		for household_id in ids:
			var h: Household = households[household_id]
			h.update_emigration_desire()
			if h.wants_to_emigrate:
				count += 1
		_emigration_desire_count[settlement_id] = count

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
		"summary": "%s collapsed on day %d (year %d): grain fulfillment averaged %.0f%% over the final 30 days; %d households wanted to leave (no viable route) and %d people died of starvation." % [
			settlement.name, day, year, avg_fulfillment,
			_emigration_desire_count.get(settlement_id, 0),
			_starvation_deaths_total.get(settlement_id, 0),
		],
	}

# ---------------------------------------------------------------------------
# Derived-state helpers (population/workforce are always computed from the
# authoritative household records, never cached, so a starvation death or
# emigration is immediately reflected everywhere).
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
