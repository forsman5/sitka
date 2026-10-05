extends RefCounted

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const HENeed = preload("res://scripts/sim/household_economy/records/he_need.gd")

## The household needs HESimulation models, in the order they are consumed
## each day. Authored here, next to the other tuning data, rather than in
## HESimulation so adding a satisfier is a data edit.
##
## Every need has two satisfiers: FOOD takes meat (twice grain's food value) or
## grain, HEAT takes charcoal (four times timber's heat) or timber, and
## CLOTHING takes leather (a one-for-one alternative to wool) or wool. Planned
## addition is a one-line entry: cloth for CLOTHING (wool stays as the
## raw-fibre stand-in until a tailor exists).
static var _all: Array[HENeed] = []

static func all() -> Array[HENeed]:
	if _all.is_empty():
		_all = [
			# Grain per person matches Simulation.GRAIN_PER_PERSON_PER_DAY.
			# Food is the one need whose shortfall drives starvation.
			# Meat packs twice grain's food into each unit, so it burns first.
			HENeed.new(HENeed.Id.FOOD, "Food", 0.4, {Commodity.Type.MEAT: 2.0, Commodity.Type.GRAIN: 1.0}, Commodity.Type.GRAIN, true),
			# Authored placeholder, not yet tuned. One timber is 1 heat; charcoal
			# packs 4 into a unit, so it can cost more per unit and still be the
			# cheaper way to heat a house. Densest first: charcoal burns first.
			HENeed.new(HENeed.Id.HEAT, "Heat", 0.1, {Commodity.Type.CHARCOAL: 4.0, Commodity.Type.TIMBER: 1.0}, Commodity.Type.TIMBER),
			# Matches Simulation.WOOL_PER_PERSON_PER_DAY.
			# Leather and wool are interchangeable one-for-one; households buy
			# whichever posts the lower price (see _household_favourite).
			HENeed.new(HENeed.Id.CLOTHING, "Clothing", 0.01, {Commodity.Type.LEATHER: 1.0, Commodity.Type.WOOL: 1.0}, Commodity.Type.WOOL),
		]
	return _all

static func get_need(id: HENeed.Id) -> HENeed:
	for need in all():
		if need.id == id:
			return need
	return null

## The need `commodity` helps satisfy, or null for goods households never use
## (iron, ore, livestock).
static func for_commodity(commodity: Commodity.Type) -> HENeed:
	for need in all():
		if need.is_satisfied_by(commodity):
			return need
	return null

## Every good that satisfies some need, in need order.
static func satisfier_commodities() -> Array[Commodity.Type]:
	var result: Array[Commodity.Type] = []
	for need in all():
		for commodity in need.satisfiers():
			if not result.has(commodity):
				result.append(commodity)
	return result

## One person's daily use of `commodity` if it were their only source of its
## need; 0 for goods that satisfy no need.
static func units_per_person_daily(commodity: Commodity.Type) -> float:
	var need := for_commodity(commodity)
	return need.units_per_person_daily(commodity) if need != null else 0.0
