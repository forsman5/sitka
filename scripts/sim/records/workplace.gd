class_name Workplace
extends RefCounted

const Recipe = preload("res://scripts/sim/records/recipe.gd")

var id: int
var settlement_id: int
var recipe: Recipe

## Useful capacity this workplace is staffed/built for -- includes the
## implicit land/facility limit (a farm can't grow more than its fields
## allow no matter how many workers show up). This is authored, fixed data.
var target_labor: float

## How much labor it actually got this tick: min(target_labor, this
## workplace's share of the settlement's available workforce). Equal to
## target_labor until Milestone 0.76's labor allocation can cap it below
## that when a settlement is short on workers.
var actual_labor: float = 0.0

## Latest daily production result, written by Simulation._run_production().
## Lets a caller diagnose *why* a workplace produced less than its labor
## alone would allow -- e.g. a bloomery reporting actual_units 0.0 with
## limiting_input Commodity.CHARCOAL, versus that same shortfall silently
## vanishing into settlement.consume()'s clamp.
var last_planned_units: float = 0.0
var last_actual_units: float = 0.0
var last_limiting_input = null # Commodity.Type, or null if not input-constrained
var last_input_requested: Dictionary = {} # what planned_units would need, before affordability capped it
var last_input_consumed: Dictionary = {}
var last_output_produced: Dictionary = {}
var last_utilization_ratio: float = 1.0 # actual_units / fully-staffed-and-unconstrained potential

func _init(p_id: int, p_settlement_id: int, p_recipe: Recipe, p_target_labor: float) -> void:
	id = p_id
	settlement_id = p_settlement_id
	recipe = p_recipe
	target_labor = p_target_labor
