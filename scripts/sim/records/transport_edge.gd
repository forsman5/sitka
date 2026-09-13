class_name TransportEdge
extends RefCounted

## One shared physical connection between two settlements (a road, track,
## ford/bridge crossing, or river reach) -- not a directed lane. Capacity,
## toll, and risk describe the facility itself and apply either way travel
## happens. Travel time may still be asymmetric: a river barge moves faster
## downstream (settlement_a -> settlement_b) than upstream (b -> a); a road
## or track is symmetric unless authored otherwise.

enum Mode { FOOT, CART, CATTLE_DRIVE, RIVER_BARGE }

var id: int
var settlement_a_id: int
var settlement_b_id: int
var mode: Mode
var capacity: float
var travel_time_days_a_to_b: float
var travel_time_days_b_to_a: float
var toll: float = 0.0
var risk: float = 0.0

func _init(p_id: int, p_a: int, p_b: int, p_mode: Mode, p_capacity: float, p_travel_time_a_to_b: float, p_travel_time_b_to_a: float = -1.0, p_toll: float = 0.0, p_risk: float = 0.0) -> void:
	id = p_id
	settlement_a_id = p_a
	settlement_b_id = p_b
	mode = p_mode
	capacity = p_capacity
	travel_time_days_a_to_b = p_travel_time_a_to_b
	travel_time_days_b_to_a = p_travel_time_b_to_a if p_travel_time_b_to_a >= 0.0 else p_travel_time_a_to_b
	toll = p_toll
	risk = p_risk

## Travel time for a trip that departs `from_settlement_id` along this edge.
func travel_time_days(from_settlement_id: int) -> float:
	return travel_time_days_a_to_b if from_settlement_id == settlement_a_id else travel_time_days_b_to_a

## The settlement at the other end of this edge from `settlement_id`.
func other_end(settlement_id: int) -> int:
	return settlement_b_id if settlement_id == settlement_a_id else settlement_a_id

func connects(settlement_id: int) -> bool:
	return settlement_id == settlement_a_id or settlement_id == settlement_b_id
