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
const SUPPLY_DEMAND_HISTORY_WINDOW_DAYS := 730
var _supplied_history: Dictionary[Commodity.Type, Array] = {}
var _demanded_history: Dictionary[Commodity.Type, Array] = {}

## Today's Trader export appetite per commodity: how much the Trader could
## and would take (its remaining handling capacity when this good's turn in
## the export priority came), as opposed to what it actually shipped. Cleared
## daily with last_clearing. Kept apart from last_clearing so price drift and
## the "executed" numbers are untouched.
var _export_appetite: Dictionary[Commodity.Type, float] = {}
## The part of today's executed export already counted in last_clearing's
## requested total (only goods with no household clearing of their own), so
## the appetite series can swap it out rather than double count.
var _export_in_clearing: Dictionary[Commodity.Type, float] = {}
var _demanded_with_export_history: Dictionary[Commodity.Type, Array] = {}

func clear_daily_export() -> void:
	_export_appetite.clear()
	_export_in_clearing.clear()

func record_export(commodity: Commodity.Type, appetite: float, executed_in_clearing: float) -> void:
	_export_appetite[commodity] = _export_appetite.get(commodity, 0.0) + appetite
	_export_in_clearing[commodity] = _export_in_clearing.get(commodity, 0.0) + executed_in_clearing

func record_supply_demand_history() -> void:
	for commodity in price.keys():
		var clearing: Dictionary = last_clearing.get(commodity, {})
		var requested: float = clearing.get("total_requested_funded", 0.0)
		_push_history(_supplied_history, commodity, clearing.get("total_offered", 0.0))
		_push_history(_demanded_history, commodity, requested)
		_push_history(_demanded_with_export_history, commodity,
			maxf(0.0, requested - _export_in_clearing.get(commodity, 0.0)) + _export_appetite.get(commodity, 0.0))

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

## Same as demanded_history, but Trader exports count at the Trader's
## appetite (remaining capacity) instead of the quantity actually shipped.
func demanded_with_export_history(commodity: Commodity.Type) -> Array:
	return (_demanded_with_export_history.get(commodity, []) as Array).duplicate()
