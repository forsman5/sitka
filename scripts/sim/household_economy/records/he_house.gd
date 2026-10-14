class_name HEHouse
extends "res://scripts/sim/household_economy/records/he_building.gd"

## A dwelling: not a business -- no workers, recipe, stock or balance. It only
## provides housing. Housing is a settlement-wide pool for now: houses are
## counted against households, and no household is tied to a particular house
## (TODO(housing-assignment): record who lives where so the town view can show
## it). See HESimulation.get_housing_report.

const TYPE_KEY := "house"

## How many households one house shelters.
var capacity_households: int = 1

func _init(p_id: int, p_settlement_id: int, p_name: String = "House") -> void:
	id = p_id
	settlement_id = p_settlement_id
	name = p_name
	type_key = TYPE_KEY
