class_name Settlement
extends RefCounted

const Commodity = preload("res://scripts/sim/records/commodity.gd")

var id: int
var name: String
var household_ids: Array[int] = []
var workplace_ids: Array[int] = []
var inventory: Dictionary[Commodity.Type, float] = {}
var _population: int = 0

## Total commodity consumed but unavailable this run, per commodity. Not part
## of inventory (never goes negative) -- kept for after-the-fact diagnosis of
## shortages, e.g. "why is Ironbank's iron production idle".
var unmet_demand: Dictionary[Commodity.Type, float] = {}

func _init(p_id: int, p_name: String) -> void:
	id = p_id
	name = p_name

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
		unmet_demand[commodity] = unmet_demand.get(commodity, 0.0) + (amount - taken)
	return taken

func population() -> int:
	return _population

func set_population(p: int) -> void:
	_population = p
