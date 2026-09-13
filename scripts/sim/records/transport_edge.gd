class_name TransportEdge
extends RefCounted

enum Mode { FOOT, CART, CATTLE_DRIVE, RIVER_BARGE }

var id: int
var from_settlement_id: int
var to_settlement_id: int
var mode: Mode
var capacity: float
var travel_time_days: float
var seasonal_modifier: float = 1.0
var toll: float = 0.0
var risk: float = 0.0

func _init(p_id: int, p_from: int, p_to: int, p_mode: Mode, p_capacity: float, p_travel_time_days: float, p_toll: float = 0.0, p_risk: float = 0.0) -> void:
	id = p_id
	from_settlement_id = p_from
	to_settlement_id = p_to
	mode = p_mode
	capacity = p_capacity
	travel_time_days = p_travel_time_days
	toll = p_toll
	risk = p_risk
