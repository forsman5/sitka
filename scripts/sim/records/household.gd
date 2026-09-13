class_name Household
extends RefCounted

var id: int
var settlement_id: int
var worker_capacity: int
var dependents: int
var wealth: float

func _init(p_id: int, p_settlement_id: int, p_worker_capacity: int, p_dependents: int, p_wealth: float = 0.0) -> void:
	id = p_id
	settlement_id = p_settlement_id
	worker_capacity = p_worker_capacity
	dependents = p_dependents
	wealth = p_wealth

func headcount() -> int:
	return worker_capacity + dependents
