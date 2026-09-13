class_name Workplace
extends RefCounted

const Recipe = preload("res://scripts/sim/records/recipe.gd")

var id: int
var settlement_id: int
var recipe: Recipe
var labor_assigned: float

## Latest daily production result, written by Simulation._run_production().
## Lets a caller diagnose *why* a workplace produced less than its labor
## alone would allow -- e.g. a bloomery reporting actual_units 0.0 with
## limiting_input Commodity.CHARCOAL, versus that same shortfall silently
## vanishing into settlement.consume()'s clamp.
var last_planned_units: float = 0.0
var last_actual_units: float = 0.0
var last_limiting_input = null # Commodity.Type, or null if not input-constrained
var last_input_consumed: Dictionary = {}
var last_output_produced: Dictionary = {}

func _init(p_id: int, p_settlement_id: int, p_recipe: Recipe, p_labor_assigned: float) -> void:
	id = p_id
	settlement_id = p_settlement_id
	recipe = p_recipe
	labor_assigned = p_labor_assigned
