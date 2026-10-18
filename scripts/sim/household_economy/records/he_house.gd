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

## Share of its heating a stone house saves (see HEHousehold.need_scale): the
## walls hold the heat, so its household needs this much less fuel. Flat, like
## the morale bonus, and applied whoever lives there.
const STONE_HEAT_SAVING := 0.25

## Built of stone: same lot and capacity as a plain house, but its household
## is happier. Set by upgrade_to_stone(); tenements are never stone.
var is_stone: bool = false

## How many households one house shelters.
var capacity_households: int = 1

## Yearly upkeep in goods, paid by the households living here: they buy the
## timber (and stone) on the market and hand it over when government staff come
## to repair (HESimulation._run_house_maintenance). A plain house takes timber;
## a tenement and a stone house take timber and stone (a stone house keeps its
## timber roof and fittings, and needs masonry repairs on top). A house shared by
## several households (a tenement) splits its bill between them.
## About 56 g a year for a stone house at 4 g a unit, against a median household
## surplus of 650-1,050 g (see docs/household-housing-choice-plan.md).
const UPKEEP_TIMBER := 1.0
const DENSE_UPKEEP_TIMBER := 4.0
const DENSE_UPKEEP_STONE := 4.0
const STONE_UPKEEP_TIMBER := 4.0
const STONE_UPKEEP_STONE := 10.0
## A repair visit pays this slice of a year's upkeep, so a household needs a
## quarter of a year's goods in hand when staff arrive.
const UPKEEP_SLICE_YEARS := 0.25

## Years of upkeep not yet delivered. Grows 1/365 a day and is paid down in
## slices of a year, round robin, so the whole town's backlog falls together.
## Starts below zero: the sim staggers the first visits on the first day.
var neglect_years: float = -1.0

func upkeep_timber() -> float:
	if is_dense():
		return DENSE_UPKEEP_TIMBER
	return STONE_UPKEEP_TIMBER if is_stone else UPKEEP_TIMBER

func upkeep_stone() -> float:
	if is_dense():
		return DENSE_UPKEEP_STONE
	return STONE_UPKEEP_STONE if is_stone else 0.0

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

## Multiplier on its household's heating need: 1.0, or less in stone.
func heat_factor() -> float:
	return 1.0 - STONE_HEAT_SAVING if is_stone else 1.0

## Turns this house into a stone house without moving it.
func upgrade_to_stone() -> void:
	is_stone = true
	name = "Stone House %d" % id

## Turns this house into a tenement without moving it.
func upgrade_to_dense() -> void:
	type_key = DENSE_TYPE_KEY
	capacity_households = DENSE_CAPACITY
	name = "Tenement %d" % id
