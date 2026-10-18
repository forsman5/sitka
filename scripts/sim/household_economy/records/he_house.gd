class_name HEHouse
extends "res://scripts/sim/household_economy/records/he_building.gd"

## A dwelling: not a business -- no workers, recipe, stock or balance. It only
## provides housing. Housing is a settlement-wide pool for now: houses are
## counted against households, and no household is tied to a particular house
## (TODO(housing-assignment): record who lives where so the town view can show
## it). See HESimulation.get_housing_report.

const TYPE_KEY := "house"

## A dense house: same lot, more households. Plain houses are upgraded to it in
## place (HESimulation.build_government_building), so growth can densify the
## town instead of pushing it outward.
const DENSE_TYPE_KEY := "tenement"
const DENSE_CAPACITY := 4

## Morale a household gains for living in a stone house (see
## HEHousehold.home_morale_bonus). Flat: a house is either stone or it is not.
const STONE_MORALE_BONUS := 0.08

## Built of stone: same lot and capacity as a plain house, but its household
## is happier. Set by upgrade_to_stone(); tenements are never stone.
var is_stone: bool = false

## How many households one house shelters.
var capacity_households: int = 1

func _init(p_id: int, p_settlement_id: int, p_name: String = "House") -> void:
	id = p_id
	settlement_id = p_settlement_id
	name = p_name
	type_key = TYPE_KEY

func is_dense() -> bool:
	return type_key == DENSE_TYPE_KEY

## A plain house: neither densified nor upgraded to stone. Only these can be
## upgraded (to either).
func is_plain() -> bool:
	return not is_dense() and not is_stone

## Morale its household gains from living here.
func morale_bonus() -> float:
	return STONE_MORALE_BONUS if is_stone else 0.0

## Turns this house into a stone house without moving it.
func upgrade_to_stone() -> void:
	is_stone = true
	name = "Stone House %d" % id

## Turns this house into a tenement without moving it.
func upgrade_to_dense() -> void:
	type_key = DENSE_TYPE_KEY
	capacity_households = DENSE_CAPACITY
	name = "Tenement %d" % id
