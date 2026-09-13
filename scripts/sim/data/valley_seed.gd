class_name ValleySeed
extends RefCounted

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Household = preload("res://scripts/sim/records/household.gd")
const Settlement = preload("res://scripts/sim/records/settlement.gd")
const Recipe = preload("res://scripts/sim/records/recipe.gd")
const Workplace = preload("res://scripts/sim/records/workplace.gd")
const TransportEdge = preload("res://scripts/sim/records/transport_edge.gd")

## Authored starting state for the five-settlement river valley described in
## docs/river-valley-vertical-slice.md. All quantities here are first-pass
## placeholders for Milestone 0 (proving the tick loop is deterministic and
## bounded) -- expect to retune alongside playtesting, not treat as final.

const ALDFORD := 1
const HIGH_FELL := 2
const OAKMERE := 3
const IRONBANK := 4
const STAITHE := 5

## Households per settlement. Aldford is 70-100 per the spec; the rest are
## placeholder proportions reflecting each settlement's described size and
## role (Staithe largest as the established port/market center, Ironbank
## smallest as "fuel-hungry and labor-poor"). Sums to ~500 valley-wide.
const HOUSEHOLDS_PER_SETTLEMENT := {
	ALDFORD: 85,
	HIGH_FELL: 95,
	OAKMERE: 90,
	IRONBANK: 60,
	STAITHE: 170,
}

static func build_default_valley(rng: RandomNumberGenerator) -> Dictionary:
	var settlements: Dictionary[int, Settlement] = {}
	settlements[ALDFORD] = Settlement.new(ALDFORD, "Aldford")
	settlements[ALDFORD].is_player_holding = true
	settlements[HIGH_FELL] = Settlement.new(HIGH_FELL, "High Fell")
	settlements[OAKMERE] = Settlement.new(OAKMERE, "Oakmere")
	settlements[IRONBANK] = Settlement.new(IRONBANK, "Ironbank")
	settlements[STAITHE] = Settlement.new(STAITHE, "Staithe")

	_seed_starting_stock(settlements)

	var households := _build_households(settlements, rng)
	var workplaces := _build_workplaces(settlements)
	var transport_edges := _build_transport_edges()

	return {
		"settlements": settlements,
		"households": households,
		"workplaces": workplaces,
		"transport_edges": transport_edges,
	}

static func _seed_starting_stock(settlements: Dictionary[int, Settlement]) -> void:
	# High Fell: no local grain production -- a carried-over stockpile lets it
	# survive at least one winter of fodder demand before herd losses begin.
	settlements[HIGH_FELL].add_stock(Commodity.Type.GRAIN, 1500.0)
	settlements[HIGH_FELL].add_stock(Commodity.Type.CATTLE, 200.0)
	settlements[HIGH_FELL].add_stock(Commodity.Type.SHEEP, 400.0)

	# Ironbank: a modest starting charcoal stockpile (no local charcoal
	# production) so the bloomery can run for part of the year before idling
	# once it depletes -- illustrates "an ironworks idled by missing charcoal".
	settlements[IRONBANK].add_stock(Commodity.Type.CHARCOAL, 300.0)

	# Staithe: existing imported grain buffer (its stated role is imported
	# grain, not self-sufficiency) and an iron stockpile from the existing
	# downstream trade route that bypasses Aldford.
	settlements[STAITHE].add_stock(Commodity.Type.GRAIN, 3000.0)
	settlements[STAITHE].add_stock(Commodity.Type.IRON, 200.0)

static func _build_households(settlements: Dictionary[int, Settlement], rng: RandomNumberGenerator) -> Dictionary[int, Household]:
	var households: Dictionary[int, Household] = {}
	var next_id := 1
	for settlement_id in HOUSEHOLDS_PER_SETTLEMENT.keys():
		var settlement: Settlement = settlements[settlement_id]
		for i in HOUSEHOLDS_PER_SETTLEMENT[settlement_id]:
			var worker_capacity := rng.randi_range(1, 3)
			var dependents := rng.randi_range(0, 4)
			var household := Household.new(next_id, settlement_id, worker_capacity, dependents)
			households[next_id] = household
			settlement.household_ids.append(next_id)
			next_id += 1
	return households

static func _build_workplaces(settlements: Dictionary[int, Settlement]) -> Dictionary[int, Workplace]:
	var workplaces: Dictionary[int, Workplace] = {}

	# Subsistence farming: labor and land only, no manufactured inputs.
	# Seasonal swing: light spring planting, steady summer, harvest bump,
	# near-dormant winter.
	var farm_recipe := Recipe.new(
		"farm",
		{},
		{Commodity.Type.GRAIN: 1.0},
		[0.8, 1.0, 1.6, 0.1],
	)
	_add_workplace(workplaces, settlements, 1, ALDFORD, farm_recipe, 120.0)
	_add_workplace(workplaces, settlements, 7, STAITHE, farm_recipe, 100.0)

	# Pasture: shearing labor only (cattle/sheep head count itself is handled
	# by Simulation's seasonal herd tick, not this recipe). Heavy spring/summer
	# shearing season, minimal in winter.
	var pasture_recipe := Recipe.new(
		"pasture",
		{},
		{Commodity.Type.WOOL: 0.15},
		[1.5, 1.5, 0.5, 0.2],
	)
	_add_workplace(workplaces, settlements, 2, HIGH_FELL, pasture_recipe, 130.0)

	# Woodland camp: labor -> timber, mild winter dip.
	var woodland_recipe := Recipe.new(
		"woodland_camp",
		{},
		{Commodity.Type.TIMBER: 0.3},
		[1.0, 1.0, 1.0, 0.6],
	)
	_add_workplace(workplaces, settlements, 3, OAKMERE, woodland_recipe, 90.0)

	# Charcoal burner: consumes Oakmere's own timber stock.
	var charcoal_recipe := Recipe.new(
		"charcoal_burner",
		{Commodity.Type.TIMBER: 0.5},
		{Commodity.Type.CHARCOAL: 0.3},
	)
	_add_workplace(workplaces, settlements, 4, OAKMERE, charcoal_recipe, 40.0)

	# Bloomery: consumes charcoal (none produced locally -- draws down the
	# starting stockpile, then idles once it runs out).
	var bloomery_recipe := Recipe.new(
		"bloomery",
		{Commodity.Type.CHARCOAL: 0.4},
		{Commodity.Type.IRON: 0.2},
	)
	_add_workplace(workplaces, settlements, 5, IRONBANK, bloomery_recipe, 60.0)

	# Smithy: consumes iron (none produced locally -- draws down the starting
	# stockpile, then idles once it runs out).
	var smithy_recipe := Recipe.new(
		"smithy",
		{Commodity.Type.IRON: 0.3},
		{Commodity.Type.TOOLS: 0.2},
	)
	_add_workplace(workplaces, settlements, 6, STAITHE, smithy_recipe, 50.0)

	return workplaces

static func _add_workplace(workplaces: Dictionary[int, Workplace], settlements: Dictionary[int, Settlement], id: int, settlement_id: int, recipe: Recipe, target_labor: float) -> void:
	var workplace := Workplace.new(id, settlement_id, recipe, target_labor)
	workplaces[id] = workplace
	settlements[settlement_id].workplace_ids.append(id)

static func _build_transport_edges() -> Dictionary[int, TransportEdge]:
	var edges: Dictionary[int, TransportEdge] = {}
	# Geography per the spec: an overland route from High Fell and Oakmere
	# meets the main river at Aldford; Oakmere has no direct navigable-river
	# access of its own; an existing downstream route already lets Ironbank
	# and Staithe trade without passing through Aldford. Unused by the tick
	# loop in Milestone 0/0.5 -- static data only, for Milestone 2's shipments.
	#
	# Each edge is one shared physical connection (settlement_a <-> b); roads
	# and tracks are symmetric, river barge edges are faster downstream
	# (a -> b, with the current) than upstream (b -> a).
	edges[1] = TransportEdge.new(1, HIGH_FELL, ALDFORD, TransportEdge.Mode.CART, 20.0, 1.5, 1.5, 0.0, 0.1)
	edges[2] = TransportEdge.new(2, OAKMERE, ALDFORD, TransportEdge.Mode.CART, 15.0, 1.0, 1.0, 0.0, 0.1)
	edges[3] = TransportEdge.new(3, OAKMERE, IRONBANK, TransportEdge.Mode.CART, 15.0, 0.5, 0.5, 0.0, 0.05)
	edges[4] = TransportEdge.new(4, IRONBANK, ALDFORD, TransportEdge.Mode.RIVER_BARGE, 25.0, 0.4, 0.7, 0.0, 0.05)
	edges[5] = TransportEdge.new(5, ALDFORD, STAITHE, TransportEdge.Mode.RIVER_BARGE, 10.0, 0.8, 1.4, 0.05, 0.1)
	edges[6] = TransportEdge.new(6, IRONBANK, STAITHE, TransportEdge.Mode.RIVER_BARGE, 30.0, 0.8, 1.4, 0.05, 0.05)
	return edges
