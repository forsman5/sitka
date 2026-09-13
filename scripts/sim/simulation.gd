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
## scene tree. See docs/river-valley-vertical-slice.md section 4.

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

var settlements: Dictionary[int, Settlement] = {}
var households: Dictionary[int, Household] = {}
var workplaces: Dictionary[int, Workplace] = {}
var transport_edges: Dictionary[int, TransportEdge] = {}

var rng: RandomNumberGenerator
var day: int = 0
var year: int = 0

func _init(seed: int) -> void:
	rng = RandomNumberGenerator.new()
	rng.seed = seed
	var valley := ValleySeed.build_default_valley(rng)
	settlements = valley["settlements"]
	households = valley["households"]
	workplaces = valley["workplaces"]
	transport_edges = valley["transport_edges"]

func season() -> Season:
	return ((day / DAYS_PER_SEASON) % SEASONS_PER_YEAR) as Season

func advance_ticks(days: int) -> void:
	for i in days:
		_daily_tick()
		day += 1
		if day % DAYS_PER_SEASON == 0:
			_seasonal_tick()
		if day % DAYS_PER_YEAR == 0:
			_yearly_tick()

func get_settlement_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(settlements.keys())
	return ids

func get_workplace_ids(settlement_id: int) -> Array[int]:
	var ids: Array[int] = []
	ids.assign((settlements[settlement_id] as Settlement).workplace_ids)
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
	var s: Settlement = settlements[settlement_id]
	var inventory := {}
	var unmet_total := {}
	var unmet_today := {}
	var unmet_rolling := {}
	for c in Commodity.ALL:
		var name := Commodity.name_of(c)
		inventory[name] = s.stock(c)
		unmet_total[name] = s.unmet_demand.get(c, 0.0)
		unmet_today[name] = s.unmet_today.get(c, 0.0)
		unmet_rolling[name] = s.unmet_rolling(c)
	return {
		"id": s.id,
		"name": s.name,
		"population": s.population(),
		"inventory": inventory,
		"unmet_demand_total": unmet_total,
		"unmet_today": unmet_today,
		"unmet_rolling_30d": unmet_rolling,
	}

## Diagnoses the workplace's most recent daily production: how much it was
## staffed to produce, how much it actually produced, and (if less) which
## input commodity ran out first. This is where a stalled bloomery shows up
## -- settlement-level unmet_demand only tracks population/herd consumption,
## not a workplace quietly throttling itself for lack of an input.
func get_workplace_status(workplace_id: int) -> Dictionary:
	var w: Workplace = workplaces[workplace_id]
	return {
		"id": w.id,
		"settlement_id": w.settlement_id,
		"recipe_id": w.recipe.id,
		"planned_units": w.last_planned_units,
		"actual_units": w.last_actual_units,
		"limiting_input": w.last_limiting_input,
		"input_consumed": w.last_input_consumed.duplicate(),
		"output_produced": w.last_output_produced.duplicate(),
	}

func _daily_tick() -> void:
	for settlement_id in settlements.keys():
		(settlements[settlement_id] as Settlement).start_new_day()
	_run_production()
	_run_consumption()

func _run_production() -> void:
	var s := season()
	for workplace_id in workplaces.keys():
		var workplace: Workplace = workplaces[workplace_id]
		var settlement: Settlement = settlements[workplace.settlement_id]
		var recipe := workplace.recipe

		var planned_units: float = workplace.labor_assigned * recipe.seasonal_modifiers[s]
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

		var input_consumed := {}
		for commodity in recipe.inputs.keys():
			var amount: float = recipe.inputs[commodity] * actual_units
			settlement.consume(commodity, amount)
			input_consumed[commodity] = amount

		var output_produced := {}
		for commodity in recipe.outputs.keys():
			var amount: float = recipe.outputs[commodity] * actual_units
			settlement.add_stock(commodity, amount)
			output_produced[commodity] = amount

		workplace.last_planned_units = planned_units
		workplace.last_actual_units = actual_units
		workplace.last_limiting_input = limiting_input
		workplace.last_input_consumed = input_consumed
		workplace.last_output_produced = output_produced

func _run_consumption() -> void:
	for settlement_id in settlements.keys():
		var settlement: Settlement = settlements[settlement_id]
		var pop: float = settlement.population()
		settlement.consume(Commodity.Type.GRAIN, pop * GRAIN_PER_PERSON_PER_DAY)
		settlement.consume(Commodity.Type.WOOL, pop * WOOL_PER_PERSON_PER_DAY)
		settlement.consume(Commodity.Type.TOOLS, pop * TOOLS_PER_PERSON_PER_DAY)

func _seasonal_tick() -> void:
	var s := season()
	for settlement_id in settlements.keys():
		var settlement: Settlement = settlements[settlement_id]
		for herd_commodity in [Commodity.Type.CATTLE, Commodity.Type.SHEEP]:
			var head := settlement.stock(herd_commodity)
			if head <= 0.0:
				continue
			if s == Season.WINTER:
				var fodder_needed := head * FODDER_PER_HEAD_PER_SEASON
				var fodder_available := settlement.stock(Commodity.Type.GRAIN)
				var fed := fodder_available >= fodder_needed
				settlement.consume(Commodity.Type.GRAIN, min(fodder_available, fodder_needed))
				var loss_rate := WINTER_LOSS_RATE_FED if fed else WINTER_LOSS_RATE_STARVED
				settlement.inventory[herd_commodity] = head * (1.0 - loss_rate)
			else:
				settlement.inventory[herd_commodity] = min(head * (1.0 + HERD_GROWTH_RATE), HERD_HARD_CEILING)

func _yearly_tick() -> void:
	year += 1
