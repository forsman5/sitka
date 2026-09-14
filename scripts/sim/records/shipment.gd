class_name Shipment
extends RefCounted

const Commodity = preload("res://scripts/sim/records/commodity.gd")

var id: int
var commodity: Commodity.Type
var quantity: float
var origin_settlement_id: int
var destination_settlement_id: int
var origin_trade_center_workplace_id: int
var edge_id: int
var departure_day: int
var arrival_day: int

func _init(p_id: int, p_commodity: Commodity.Type, p_quantity: float, p_origin: int, p_destination: int, p_trade_center_workplace_id: int, p_edge_id: int, p_departure_day: int, p_arrival_day: int) -> void:
	id = p_id
	commodity = p_commodity
	quantity = p_quantity
	origin_settlement_id = p_origin
	destination_settlement_id = p_destination
	origin_trade_center_workplace_id = p_trade_center_workplace_id
	edge_id = p_edge_id
	departure_day = p_departure_day
	arrival_day = p_arrival_day

## 0.0 at departure, 1.0 on arrival. Clamped, so it's still meaningful to
## call after the arrival day (e.g. while a delivered shipment briefly
## lingers in a "recently arrived" view).
func progress_fraction(current_day: int) -> float:
	if arrival_day <= departure_day:
		return 1.0
	return clamp(float(current_day - departure_day) / float(arrival_day - departure_day), 0.0, 1.0)
