class_name Settlement
extends RefCounted

const Commodity = preload("res://scripts/sim/records/commodity.gd")

var id: int
var name: String
var household_ids: Array[int] = []
var workplace_ids: Array[int] = []
var inventory: Dictionary[Commodity.Type, float] = {}

## True for the clan's own holding (Aldford). Game-over is only evaluated
## for this settlement; other settlements can collapse without ending the
## run. See docs/river-valley-vertical-slice.md Milestone 0.76.
var is_player_holding: bool = false

func _init(p_id: int, p_name: String) -> void:
	id = p_id
	name = p_name

func stock(commodity: Commodity.Type) -> float:
	return inventory.get(commodity, 0.0)

func add_stock(commodity: Commodity.Type, amount: float) -> void:
	inventory[commodity] = stock(commodity) + amount

## Removes up to `amount` of `commodity` from stock and returns how much was
## actually removed (may be less than requested; never drives stock negative).
## Pure stock primitive -- demand/shortfall accounting lives in Simulation's
## daily records, not here.
func consume(commodity: Commodity.Type, amount: float) -> float:
	var available := stock(commodity)
	var taken: float = min(available, amount)
	inventory[commodity] = available - taken
	return taken
