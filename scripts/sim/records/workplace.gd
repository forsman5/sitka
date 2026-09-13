class_name Workplace
extends RefCounted

const Recipe = preload("res://scripts/sim/records/recipe.gd")

var id: int
var settlement_id: int
var recipe: Recipe
var labor_assigned: float

func _init(p_id: int, p_settlement_id: int, p_recipe: Recipe, p_labor_assigned: float) -> void:
	id = p_id
	settlement_id = p_settlement_id
	recipe = p_recipe
	labor_assigned = p_labor_assigned
