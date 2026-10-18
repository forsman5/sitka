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

enum Id { FOOD, HEAT, CLOTHING, TOOLS, WATER }

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
## Share of a person's health this need's sustained shortfall can take away
## (weights across all needs sum to 1.0). Health and morale are reporting
## signals derived from per-need stress -- see HEHousehold.health().
var health_weight: float
## One line shown in the UI: what going without this need does.
var effect_text: String
## True for a need nothing but a dedicated business can meet (tools): a
## settlement with no seller of the baseline has no market for it, so the need
## is left out of demand, shortfall reporting and the cost of living there
## instead of showing as permanent unmet scarcity. Food, heat and clothing
## leave this false -- grain, timber and wool are the staples every
## settlement is assumed able to get.
var needs_seller: bool
## Morale a household gains while this need is fully met today (0 = none).
## Unmet needs already cost morale through health_weight; this is the other
## side, for wants whose absence isn't harmful but whose presence is welcome
## (tools). It offsets penalties -- morale still tops out at 100%.
var morale_bonus: float
## Negative values are survival foods instead: morale lost when that satisfier
## supplies ALL of the need (grain, flour).
## Satisfiers a household takes as a step up rather than just a cheaper way to
## meet the need: satisfier -> morale gained when that satisfier supplies ALL of
## the need (scaled by the share it actually supplies). Affluent households
## weigh them above their price (HESimulation._household_favourite); everyone
## else buys the cheapest satisfier as before.
var comfort: Dictionary[Commodity.Type, float]
## Extra units per person per day an affluent household eats on top of
## per_person_daily, from `comfort` satisfiers only (0 = none). Scaled by the
## household's affluence (HESimulation._household_affluence) and never counted
## as a shortfall: going without it costs nothing, it is only demand a better
## table adds.
var luxury_per_person_daily: float = 0.0

## Morale a household loses at full stress from this need. A need with a value
## here is left out of the pooled "Unmet needs" morale penalty and shown under
## its own `shortfall_label` instead (0 = pooled).
var morale_penalty: float = 0.0
var shortfall_label: String = ""
## Daily stress gained per unit of shortfall, and lost on a day it is met
## (<= 0 = the shared Household.STRESS_GAIN_PER_SHORTAGE / STRESS_RECOVERY_PER_DAY).
var stress_gain: float = -1.0
var stress_recovery: float = -1.0

func _init(p_id: Id, p_label: String, p_per_person_daily: float, p_unit_values: Dictionary[Commodity.Type, float],
		p_baseline: Commodity.Type, p_drives_lifecycle: bool = false, p_health_weight: float = 0.0, p_effect_text: String = "",
		p_needs_seller: bool = false, p_morale_bonus: float = 0.0, p_comfort: Dictionary[Commodity.Type, float] = {}) -> void:
	assert(p_unit_values.is_empty() or p_unit_values.has(p_baseline), "a need's baseline must be one of its satisfiers")
	id = p_id
	label = p_label
	per_person_daily = p_per_person_daily
	unit_values = p_unit_values
	baseline = p_baseline
	drives_lifecycle = p_drives_lifecycle
	health_weight = p_health_weight
	effect_text = p_effect_text
	needs_seller = p_needs_seller
	morale_bonus = p_morale_bonus
	comfort = p_comfort

## A need no good satisfies (water: met by a town's water sources). It has no
## satisfiers, market or price, and `baseline` is unused.
func is_service() -> bool:
	return unit_values.is_empty()

func satisfiers() -> Array[Commodity.Type]:
	var result: Array[Commodity.Type] = []
	for commodity in unit_values.keys():
		result.append(commodity)
	return result

## Morale a full supply of `commodity` adds to this need (0 if it is no comfort).
func comfort_of(commodity: Commodity.Type) -> float:
	return comfort.get(commodity, 0.0)

## Burns up to `amount` need units from the comfort satisfiers alone.
func burn_comfort(owner, amount: float) -> Dictionary:
	var provided := 0.0
	var burned := {}
	for commodity in unit_values.keys():
		var remaining := amount - provided
		if remaining <= 0.0:
			break
		if comfort_of(commodity) <= 0.0:
			continue
		var units: float = owner.consume(commodity, remaining / unit_values[commodity])
		if units > 0.0:
			burned[commodity] = units
			provided += units * unit_values[commodity]
	return {"provided": provided, "burned": burned}

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
