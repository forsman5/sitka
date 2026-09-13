class_name Settlement
extends RefCounted

const Commodity = preload("res://scripts/sim/records/commodity.gd")

var id: int
var name: String
var household_ids: Array[int] = []
var workplace_ids: Array[int] = []
var inventory: Dictionary[Commodity.Type, float] = {}
var _population: int = 0

const ROLLING_WINDOW_DAYS := 30

## Total commodity demanded (by households/herds) but unavailable, per
## commodity, since the simulation started. Not part of inventory (never
## goes negative) -- this is a running total, so on its own it only ever
## rises and describes history, not present conditions. Use unmet_today() /
## unmet_rolling() for that. Note this only reflects demand-side shortfalls
## (population/herd consumption); a workplace that self-limits production
## because an input is scarce does NOT show up here -- see
## Simulation.get_workplace_status() for diagnosing stalled production.
var unmet_demand: Dictionary[Commodity.Type, float] = {}

## This simulated day's unmet demand so far, per commodity. Reset by
## start_new_day().
var unmet_today: Dictionary[Commodity.Type, float] = {}

var _unmet_history: Dictionary[Commodity.Type, Array] = {}

func _init(p_id: int, p_name: String) -> void:
	id = p_id
	name = p_name
	for c in Commodity.ALL:
		_unmet_history[c] = []

func stock(commodity: Commodity.Type) -> float:
	return inventory.get(commodity, 0.0)

func add_stock(commodity: Commodity.Type, amount: float) -> void:
	inventory[commodity] = stock(commodity) + amount

## Removes up to `amount` of `commodity` from stock and returns how much was
## actually removed (may be less than requested; never drives stock negative).
func consume(commodity: Commodity.Type, amount: float) -> float:
	var available := stock(commodity)
	var taken: float = min(available, amount)
	inventory[commodity] = available - taken
	if taken < amount:
		var shortfall := amount - taken
		unmet_demand[commodity] = unmet_demand.get(commodity, 0.0) + shortfall
		unmet_today[commodity] = unmet_today.get(commodity, 0.0) + shortfall
	return taken

## Call once per simulated day, before that day's consumption happens: rolls
## the day just finished into the rolling history window and resets
## unmet_today for the new day.
func start_new_day() -> void:
	for c in Commodity.ALL:
		var history: Array = _unmet_history[c]
		history.append(unmet_today.get(c, 0.0))
		if history.size() > ROLLING_WINDOW_DAYS:
			history.pop_front()
	unmet_today.clear()

## Sum of unmet demand for `commodity` over the last ROLLING_WINDOW_DAYS days.
func unmet_rolling(commodity: Commodity.Type) -> float:
	var total := 0.0
	for v in _unmet_history.get(commodity, []):
		total += v
	return total

func population() -> int:
	return _population

func set_population(p: int) -> void:
	_population = p
