extends RefCounted

const Commodity = preload("res://scripts/sim/records/commodity.gd")

## One recurring household requirement -- food, heat, clothing -- that any of
## several goods can satisfy. HESimulation never asks "how much grain does a
## household eat"; it asks how much FOOD a household needs and which of the
## need's satisfiers to spend. A new source of an existing need (meat for
## food, charcoal for heat, leather or cloth for clothing) is one more entry
## in `unit_values` -- no new consumption, purchasing, reserve or reference-
## wage code.
##
## A need is measured in its own units ("heat units"). Each satisfier has a
## unit value: how many of those units ONE unit of the good provides, so a
## good that packs more into each unit (charcoal's 4 heat vs timber's 1) is
## compared by price per need-unit, not price per good.

enum Id { FOOD, HEAT, CLOTHING }

var id: Id
var label: String
## Need units each person requires per day.
var per_person_daily: float
## satisfier commodity -> need units one unit of it provides. Insertion order
## is the BURN order: list the densest satisfier first so a holder of several
## uses it up before touching the rest.
var unit_values: Dictionary[Commodity.Type, float]
## The satisfier that is always assumed purchasable. Others need a seller (or
## Trader stock) in the settlement before they compete on price, so a
## settlement without, say, a charcoal burner behaves exactly as if the need
## had only its baseline. Also the commodity a shortfall is reported against.
var baseline: Commodity.Type
## Whether the fraction of this need met feeds the household lifecycle engine
## (stress, migration pressure, starvation, births). Only food does.
var drives_lifecycle: bool

func _init(p_id: Id, p_label: String, p_per_person_daily: float, p_unit_values: Dictionary[Commodity.Type, float],
		p_baseline: Commodity.Type, p_drives_lifecycle: bool = false) -> void:
	assert(p_unit_values.has(p_baseline), "a need's baseline must be one of its satisfiers")
	id = p_id
	label = p_label
	per_person_daily = p_per_person_daily
	unit_values = p_unit_values
	baseline = p_baseline
	drives_lifecycle = p_drives_lifecycle

func satisfiers() -> Array[Commodity.Type]:
	var result: Array[Commodity.Type] = []
	for commodity in unit_values.keys():
		result.append(commodity)
	return result

func is_satisfied_by(commodity: Commodity.Type) -> bool:
	return unit_values.has(commodity)

func value_of(commodity: Commodity.Type) -> float:
	return unit_values[commodity]

## What one person needs per day if they used only `commodity`.
func units_per_person_daily(commodity: Commodity.Type) -> float:
	return per_person_daily / unit_values[commodity]

## Need units `owner` (household or business) holds across every satisfier.
func held(owner) -> float:
	var total := 0.0
	for commodity in unit_values.keys():
		total += owner.stock(commodity) * unit_values[commodity]
	return total

## Spends up to `amount` need units from `owner`, densest satisfier first.
## Returns {"provided": need units actually supplied, "burned": {commodity: units}}.
func burn(owner, amount: float) -> Dictionary:
	var provided := 0.0
	var burned := {}
	for commodity in unit_values.keys():
		var remaining := amount - provided
		if remaining <= 0.0:
			break
		var units: float = owner.consume(commodity, remaining / unit_values[commodity])
		if units > 0.0:
			burned[commodity] = units
			provided += units * unit_values[commodity]
	return {"provided": provided, "burned": burned}
