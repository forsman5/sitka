class_name Recipe
extends RefCounted

const Commodity = preload("res://scripts/sim/records/commodity.gd")

var id: String
var inputs: Dictionary[Commodity.Type, float] = {}
var outputs: Dictionary[Commodity.Type, float] = {}

## Seasonal output multiplier, indexed [spring, summer, autumn, winter].
var seasonal_modifiers: Array[float] = [1.0, 1.0, 1.0, 1.0]

func _init(p_id: String, p_inputs: Dictionary, p_outputs: Dictionary, p_seasonal_modifiers: Array[float] = [1.0, 1.0, 1.0, 1.0]) -> void:
	id = p_id
	inputs.assign(p_inputs)
	outputs.assign(p_outputs)
	seasonal_modifiers = p_seasonal_modifiers
