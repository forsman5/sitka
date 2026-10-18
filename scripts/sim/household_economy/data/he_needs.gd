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
static var _water: HENeed = null

## Morale a household gains from eating only meat (scaled by the meat share of
## its food). Morale above 100% raises output, so a better table pays back.
const FOOD_MEAT_MORALE := 0.08

static func all() -> Array[HENeed]:
	if _all.is_empty():
		_all = [
			# Grain per person matches Simulation.GRAIN_PER_PERSON_PER_DAY.
			# Food is the one need whose shortfall drives starvation.
			# Meat packs twice grain's food into each unit, so it burns first.
			HENeed.new(HENeed.Id.FOOD, "Food", 0.4, {Commodity.Type.MEAT: 2.0, Commodity.Type.GRAIN: 1.0}, Commodity.Type.GRAIN, true, 0.6,
				"Hunger wears down health and morale; sustained shortfall drives migration pressure, emigration and stops births.",
				false, 0.0, {Commodity.Type.MEAT: FOOD_MEAT_MORALE}),
			# Authored placeholder, not yet tuned. One timber is 1 heat; charcoal
			# packs 4 into a unit, so it can cost more per unit and still be the
			# cheaper way to heat a house. Densest first: charcoal burns first.
			HENeed.new(HENeed.Id.HEAT, "Heat", 0.1, {Commodity.Type.CHARCOAL: 4.0, Commodity.Type.TIMBER: 1.0}, Commodity.Type.TIMBER, false, 0.25,
				"Cold wears down health and morale. Reporting only: does not (yet) cause emigration."),
			# Matches Simulation.WOOL_PER_PERSON_PER_DAY.
			# Leather and wool are interchangeable one-for-one; households buy
			# whichever posts the lower price (see _satisfier_cascade).
			HENeed.new(HENeed.Id.CLOTHING, "Clothing", 0.01, {Commodity.Type.LEATHER: 1.0, Commodity.Type.WOOL: 1.0}, Commodity.Type.WOOL, false, 0.15,
				"Threadbare clothes slowly wear down health and morale. Reporting only: does not (yet) cause emigration."),
			# Matches Simulation.TOOLS_PER_PERSON_PER_DAY. Like clothing it does
			# not feed the lifecycle engine; only a Toolsmith supplies it, so a
			# town without one simply has no tools need (needs_seller). Health
			# weights already sum to 1.0 across the other needs, so going without
			# tools costs no health -- a household that has them gets a morale
			# lift instead (morale_bonus).
			HENeed.new(HENeed.Id.TOOLS, "Tools", 0.005, {Commodity.Type.TOOLS: 1.0}, Commodity.Type.TOOLS, false, 0.0,
				"Good tools lift morale; going without costs no health. Morale above 100% raises output at the workplace.", true, 0.1),
		]
	return _all

## Water: a service need, met by a town's wells and river intakes rather than
## by a good, so it is not in all() (the goods-based needs the market,
## consumption and cost-of-living code walk). One drink per person per day.
## Thirst bites hard and fast: full stress costs 20 points of health and 40 of
## morale, builds in about two days, and clears in ten once water is back.
## It only applies in a town that has a water source (see
## HESimulation._run_water_need), so towns without one are unchanged.
static func water() -> HENeed:
	if _water == null:
		_water = HENeed.new(HENeed.Id.WATER, "Water", 1.0, {}, Commodity.Type.GRAIN, false, 0.2,
			"Thirst wears down health and sharply lowers morale. Met by the town's wells and river intakes (Government build menu); each needs timber and stone every year.")
		_water.morale_penalty = 0.4
		_water.shortfall_label = "Thirsty"
		_water.stress_gain = 0.5
		_water.stress_recovery = 0.1
	return _water

## Every need a household feels: the goods-based ones, then water.
static func felt() -> Array[HENeed]:
	var out: Array[HENeed] = all().duplicate()
	out.append(water())
	return out

## Top-to-bottom order of the dashboard's Needs tab. Only a preference: every
## need in the catalog appears, so adding one here can't leave it off the tab.
const DISPLAY_PREFERRED_ORDER := [HENeed.Id.HEAT, HENeed.Id.FOOD, HENeed.Id.CLOTHING]

static func display_order() -> Array:
	var order: Array = DISPLAY_PREFERRED_ORDER.duplicate()
	for need in felt():
		if not order.has(need.id):
			order.append(need.id)
	return order

static func get_need(id: HENeed.Id) -> HENeed:
	for need in felt():
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
