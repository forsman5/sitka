class_name HEMarket
extends RefCounted

## Posted quote per commodity, plus the latest clearing's offers/requests/
## transactions for reporting. Owns no goods or money -- HESimulation moves
## inventory and balance directly between households; this record only
## observes and remembers the price. See docs/household-economy-next-cut.md
## "State and ownership".

const Commodity = preload("res://scripts/sim/records/commodity.gd")

var price: Dictionary[Commodity.Type, float] = {}

## Latest daily clearing result per commodity, for reporting/tests. Each
## entry: {total_offered, total_requested_funded, total_unfunded_request,
## quantity_traded, price}. Overwritten every day; not a lifetime ledger.
var last_clearing: Dictionary[Commodity.Type, Dictionary] = {}

func _init(starting_price: Dictionary) -> void:
	price.assign(starting_price)
