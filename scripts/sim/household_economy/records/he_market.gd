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

## Folds one trade pass into today's last_clearing for `commodity`. A good can
## clear several times a day (household purchases, each producer that buys it
## as an input, then a Trader export), so passes accumulate instead of the
## last one overwriting the rest. requested/traded add up; offered takes the
## largest pool any pass saw (later passes see the same seller's stock after
## earlier ones consumed it, so summing would double count).
func merge_clearing(commodity: Commodity.Type, offered: float, requested_funded: float, traded: float, clearing_price: float) -> void:
	var entry: Dictionary = last_clearing.get(commodity, {})
	last_clearing[commodity] = {
		"total_offered": maxf(entry.get("total_offered", 0.0), offered),
		"total_requested_funded": entry.get("total_requested_funded", 0.0) + requested_funded,
		"quantity_traded": entry.get("quantity_traded", 0.0) + traded,
		"price": clearing_price,
	}

## Rolling per-commodity history of each day's clearing, oldest first, capped
## at SUPPLY_DEMAND_HISTORY_WINDOW_DAYS. "supplied" is total_offered and
## "demanded" is total_requested_funded (the affordable request) from
## last_clearing; a day with no clearing records 0 for both so the chart's
## x-axis stays one point per day.
const SUPPLY_DEMAND_HISTORY_WINDOW_DAYS := 90
var _supplied_history: Dictionary[Commodity.Type, Array] = {}
var _demanded_history: Dictionary[Commodity.Type, Array] = {}

func record_supply_demand_history() -> void:
	for commodity in price.keys():
		var clearing: Dictionary = last_clearing.get(commodity, {})
		_push_history(_supplied_history, commodity, clearing.get("total_offered", 0.0))
		_push_history(_demanded_history, commodity, clearing.get("total_requested_funded", 0.0))

func _push_history(store: Dictionary, commodity: Commodity.Type, value: float) -> void:
	var series: Array = store.get(commodity, [])
	series.append(value)
	if series.size() > SUPPLY_DEMAND_HISTORY_WINDOW_DAYS:
		series.pop_front()
	store[commodity] = series

func supplied_history(commodity: Commodity.Type) -> Array:
	return (_supplied_history.get(commodity, []) as Array).duplicate()

func demanded_history(commodity: Commodity.Type) -> Array:
	return (_demanded_history.get(commodity, []) as Array).duplicate()
