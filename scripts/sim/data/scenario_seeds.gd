class_name ScenarioSeeds
extends RefCounted

## Milestone 0.76 authored single-settlement scenarios: isolated test worlds
## (no transport, no other settlements) that exercise the food-security
## causal chain in different regimes. Each returns the same valley Dictionary
## shape as ValleySeed.build_default_valley() so Simulation.new(seed,
## Callable(ScenarioSeeds, "...")) can run them directly.
##
## Household composition is fixed (not seed-randomized) so outcomes are easy
## to reason about and tune -- these are controlled experiments, not a
## slice of the authored valley.

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Household = preload("res://scripts/sim/records/household.gd")
const Settlement = preload("res://scripts/sim/records/settlement.gd")
const Recipe = preload("res://scripts/sim/records/recipe.gd")
const Workplace = preload("res://scripts/sim/records/workplace.gd")
const TransportEdge = preload("res://scripts/sim/records/transport_edge.gd")

const SETTLEMENT_ID := 1
const WORKERS_PER_HOUSEHOLD := 2
const DEPENDENTS_PER_HOUSEHOLD := 1

## Tuned so target_labor's average seasonal output (55 * 0.875 ~= 48.1/day)
## just about matches a 120-population settlement's grain demand
## (120 * 0.4 = 48/day) -- the fixed farm recipe/seasonal curve from
## ValleySeed is reused so this stays one shared carrying-capacity model.
const VIABLE_FARM_TARGET_LABOR := 55.0
const VIABLE_FARM_HOUSEHOLDS := 40 # -> population 120, workers 80

static func _farm_recipe() -> Recipe:
	return Recipe.new(
		"farm",
		{},
		{Commodity.Type.GRAIN: 1.0},
		[0.8, 1.0, 1.6, 0.1],
	)

static func _build_uniform_valley(household_count: int, starting_grain: float, target_labor: float) -> Dictionary:
	var settlement := Settlement.new(SETTLEMENT_ID, "Testfarm")
	settlement.is_player_holding = true
	settlement.add_stock(Commodity.Type.GRAIN, starting_grain)

	var settlements: Dictionary[int, Settlement] = {SETTLEMENT_ID: settlement}

	var households: Dictionary[int, Household] = {}
	for i in household_count:
		var id := i + 1
		var household := Household.new(id, SETTLEMENT_ID, WORKERS_PER_HOUSEHOLD, DEPENDENTS_PER_HOUSEHOLD)
		households[id] = household
		settlement.household_ids.append(id)

	var workplaces: Dictionary[int, Workplace] = {}
	if target_labor > 0.0:
		var workplace := Workplace.new(1, SETTLEMENT_ID, _farm_recipe(), target_labor)
		workplaces[1] = workplace
		settlement.workplace_ids.append(1)

	var transport_edges: Dictionary[int, TransportEdge] = {}

	return {
		"settlements": settlements,
		"households": households,
		"workplaces": workplaces,
		"transport_edges": transport_edges,
	}

## A farm with land/labor comfortably matched to its population: should reach
## a repeatable seasonal equilibrium (stock oscillates with the seasons but
## never runs dry, population never changes) rather than growing or
## collapsing.
static func build_viable_farm(_rng: RandomNumberGenerator) -> Dictionary:
	return _build_uniform_valley(VIABLE_FARM_HOUSEHOLDS, 3000.0, VIABLE_FARM_TARGET_LABOR)

## Same land/labor capacity as the viable farm, but starts well above the
## carrying capacity it supports. Should contract via starvation (migration
## pressure is tracked/reported but not yet realized -- relocation isn't
## implemented) until population falls back toward roughly the same ~120
## equilibrium, then stabilize.
static func build_overpopulated_farm(_rng: RandomNumberGenerator) -> Dictionary:
	return _build_uniform_valley(VIABLE_FARM_HOUSEHOLDS * 3, 3000.0, VIABLE_FARM_TARGET_LABOR)

## No farm at all -- a finite starting stock delays the reckoning, but with
## zero production the settlement must eventually exhaust it, then decline
## through migration pressure and starvation to collapse.
static func build_no_food_settlement(_rng: RandomNumberGenerator) -> Dictionary:
	return _build_uniform_valley(VIABLE_FARM_HOUSEHOLDS, 2000.0, 0.0)

## Same viable farm, but with a much thinner starting buffer: a real (not
## just cosmetic) shortage in the first spring, before summer's higher
## output arrives, that should raise stress without crossing the
## migration-pressure/starvation consecutive-day thresholds -- and then recover.
static func build_recovery_boundary(_rng: RandomNumberGenerator) -> Dictionary:
	return _build_uniform_valley(VIABLE_FARM_HOUSEHOLDS, 200.0, VIABLE_FARM_TARGET_LABOR)

# ---------------------------------------------------------------------------
# Milestone 1: a two-settlement trade pair -- one settlement with a genuine
# grain surplus, one with none, connected by a single edge. Run with the
# edge at authored capacity vs. capacity forced to ~0 to prove the spec's
# Milestone 1 acceptance bar directly: "blocking one edge or reducing its
# capacity produces a visible, explainable shortage elsewhere."
# ---------------------------------------------------------------------------

const FARMLAND_ID := 1
const BARELAND_ID := 2
const TRADE_EDGE_ID := 1

## Farm sized well above its own population's demand (unlike the viable-farm
## scenario's tuned-to-equilibrium 55) so it reliably has surplus to export.
## 100 workers comfortably clears target_labor=100 (land, not labor, is the
## binding constraint): avg output 100 * 0.875 ~= 87.5/day vs. Farmland's own
## demand of 150 * 0.4 = 60/day, leaving real surplus after feeding itself.
const FARMLAND_TARGET_LABOR := 100.0
const FARMLAND_HOUSEHOLDS := 50 # -> population 150, workers 100
const BARELAND_HOUSEHOLDS := 15 # -> population 45, workers 30 (needs 45*0.4*7 = 126 grain/week)

static func _build_trade_pair(edge_capacity: float) -> Dictionary:
	var farmland := Settlement.new(FARMLAND_ID, "Farmland")
	farmland.add_stock(Commodity.Type.GRAIN, 1000.0)
	var bareland := Settlement.new(BARELAND_ID, "Bareland")
	bareland.is_player_holding = true
	bareland.add_stock(Commodity.Type.GRAIN, 300.0)

	var settlements: Dictionary[int, Settlement] = {FARMLAND_ID: farmland, BARELAND_ID: bareland}

	var households: Dictionary[int, Household] = {}
	var next_id := 1
	for i in FARMLAND_HOUSEHOLDS:
		var household := Household.new(next_id, FARMLAND_ID, WORKERS_PER_HOUSEHOLD, DEPENDENTS_PER_HOUSEHOLD)
		households[next_id] = household
		farmland.household_ids.append(next_id)
		next_id += 1
	for i in BARELAND_HOUSEHOLDS:
		var household := Household.new(next_id, BARELAND_ID, WORKERS_PER_HOUSEHOLD, DEPENDENTS_PER_HOUSEHOLD)
		households[next_id] = household
		bareland.household_ids.append(next_id)
		next_id += 1

	var workplaces: Dictionary[int, Workplace] = {1: Workplace.new(1, FARMLAND_ID, _farm_recipe(), FARMLAND_TARGET_LABOR)}
	farmland.workplace_ids.append(1)

	var edges: Dictionary[int, TransportEdge] = {
		TRADE_EDGE_ID: TransportEdge.new(TRADE_EDGE_ID, FARMLAND_ID, BARELAND_ID, TransportEdge.Mode.CART, edge_capacity, 1.0, 1.0, 0.0, 0.05),
	}

	return {
		"settlements": settlements,
		"households": households,
		"workplaces": workplaces,
		"transport_edges": edges,
	}

## Edge capacity (150/week) comfortably covers Bareland's ~126/week grain
## need -- connected should demonstrate real viability (high fulfillment,
## stable population), not just "technically not collapsed".
static func build_trade_pair_connected(_rng: RandomNumberGenerator) -> Dictionary:
	return _build_trade_pair(150.0)

## Same two settlements, but the edge is effectively closed. Bareland should
## suffer the same kind of decline as the isolated no-food-settlement
## scenario, since nothing can reach it.
static func build_trade_pair_blocked(_rng: RandomNumberGenerator) -> Dictionary:
	return _build_trade_pair(0.0)
